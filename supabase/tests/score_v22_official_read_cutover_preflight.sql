-- ============================================================================
-- Score v2.2 official-read cutover preflight
-- READ ONLY. DEV ONLY.
--
-- Purpose:
--   Discover the exact database contracts that currently expose or mutate the
--   official IOU score before authoring cutover and rollback migrations.
--
-- Run only with:
--   node scripts/run-score-v22-sql.mjs --read-only <this-file>
-- ============================================================================

with
candidate_functions as (
  select
    p.oid,
    n.nspname as schema_name,
    p.proname as function_name,
    pg_get_function_identity_arguments(p.oid) as identity_arguments,
    pg_get_function_result(p.oid) as result_type,
    pg_get_userbyid(p.proowner) as owner_name,
    p.prosecdef as security_definer,
    p.provolatile as volatility,
    p.proacl,
    exists (
      select 1
      from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where a.grantee = 0
        and a.privilege_type = 'EXECUTE'
    ) as public_execute,
    has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
    has_function_privilege('service_role', p.oid, 'EXECUTE') as service_role_execute,
    pg_get_functiondef(p.oid) as definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind in ('f', 'p')
    and (
      p.proname ~* '(score|trust|profile|exposure)'
      or pg_get_functiondef(p.oid) ~* '(iou_score|trust_score_snapshots|v2_shadow_score|visible_trust|active_exposure_points)'
    )
),
app_score_functions as (
  select jsonb_agg(
    jsonb_build_object(
      'schema', schema_name,
      'function', function_name,
      'identity_arguments', identity_arguments,
      'result_type', result_type,
      'owner', owner_name,
      'security_definer', security_definer,
      'volatility', volatility,
      'public_execute', public_execute,
      'anon_execute', anon_execute,
      'authenticated_execute', authenticated_execute,
      'service_role_execute', service_role_execute,
      'acl', proacl,
      'definition', definition
    )
    order by function_name, identity_arguments
  ) as value
  from candidate_functions
  where function_name ~* '^(get_|create_trust_score_snapshot|recalculate_profile_exposure|recompute_iou_exposure)'
     or public_execute
     or anon_execute
     or authenticated_execute
),
legacy_score_writers as (
  select jsonb_agg(
    jsonb_build_object(
      'schema', schema_name,
      'function', function_name,
      'identity_arguments', identity_arguments,
      'security_definer', security_definer,
      'definition', definition
    )
    order by function_name, identity_arguments
  ) as value
  from candidate_functions
  where definition ~* '(update[[:space:]]+(public\.)?profiles|insert[[:space:]]+into[[:space:]]+(public\.)?profiles)'
    and definition ~* 'iou_score'
),
score_related_views as (
  select jsonb_agg(
    jsonb_build_object(
      'schema', schemaname,
      'view', viewname,
      'definition', definition
    )
    order by viewname
  ) as value
  from pg_views
  where schemaname = 'public'
    and definition ~* '(iou_score|trust_score_snapshots|v2_shadow_score|visible_trust|score_v2_contributions|active_exposure_points)'
),
score_related_triggers as (
  select jsonb_agg(
    jsonb_build_object(
      'table', format('%I.%I', ns.nspname, tbl.relname),
      'trigger', t.tgname,
      'enabled', t.tgenabled,
      'function', p.proname,
      'definition', pg_get_triggerdef(t.oid, true)
    )
    order by tbl.relname, t.tgname
  ) as value
  from pg_trigger t
  join pg_class tbl on tbl.oid = t.tgrelid
  join pg_namespace ns on ns.oid = tbl.relnamespace
  join pg_proc p on p.oid = t.tgfoid
  where ns.nspname = 'public'
    and not t.tgisinternal
    and (
      tbl.relname in (
        'profiles',
        'payments',
        'ious',
        'score_v2_contributions',
        'trust_outcome_events',
        'trust_score_snapshots'
      )
      or p.proname ~* '(score|trust|exposure)'
    )
),
score_table_columns as (
  select jsonb_object_agg(table_name, columns order by table_name) as value
  from (
    select
      c.table_name,
      jsonb_agg(
        jsonb_build_object(
          'column_name', c.column_name,
          'data_type', c.data_type,
          'udt_name', c.udt_name,
          'is_nullable', c.is_nullable,
          'column_default', c.column_default
        )
        order by c.ordinal_position
      ) as columns
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name in (
        'profiles',
        'trust_score_snapshots',
        'trust_model_versions'
      )
    group by c.table_name
  ) x
),
score_table_grants as (
  select jsonb_agg(
    jsonb_build_object(
      'table', table_name,
      'grantee', grantee,
      'privilege_type', privilege_type
    )
    order by table_name, grantee, privilege_type
  ) as value
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in ('profiles', 'trust_score_snapshots', 'trust_model_versions')
    and grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role')
),
score_policies as (
  select jsonb_agg(
    jsonb_build_object(
      'schema', schemaname,
      'table', tablename,
      'policy', policyname,
      'permissive', permissive,
      'roles', roles,
      'command', cmd,
      'using', qual,
      'with_check', with_check
    )
    order by tablename, policyname
  ) as value
  from pg_policies
  where schemaname = 'public'
    and tablename in ('profiles', 'trust_score_snapshots', 'trust_model_versions')
),
model_registry as (
  select jsonb_agg(to_jsonb(m) order by m.created_at, m.version) as value
  from public.trust_model_versions m
  where m.model_key = 'iou_score'
),
profile_score_state as (
  select jsonb_agg(
    jsonb_build_object(
      'user_id', p.id,
      'email', p.email,
      'iou_score', p.iou_score,
      'active_exposure_points', p.active_exposure_points,
      'score_last_updated_at', p.score_last_updated_at
    )
    order by p.email nulls last, p.id
  ) as value
  from public.profiles p
),
latest_snapshots as (
  select jsonb_agg(to_jsonb(s) order by s.user_id) as value
  from (
    select distinct on (t.user_id) t.*
    from public.trust_score_snapshots t
    order by t.user_id, t.created_at desc, t.id desc
  ) s
)
select jsonb_build_object(
  'audit', 'Score v2.2 official-read cutover preflight',
  'project_ref', 'colkilearqxuyldzjutw',
  'generated_at', now(),
  'read_only_required', true,
  'app_score_functions', coalesce((select value from app_score_functions), '[]'::jsonb),
  'legacy_score_writers', coalesce((select value from legacy_score_writers), '[]'::jsonb),
  'score_related_views', coalesce((select value from score_related_views), '[]'::jsonb),
  'score_related_triggers', coalesce((select value from score_related_triggers), '[]'::jsonb),
  'score_table_columns', coalesce((select value from score_table_columns), '{}'::jsonb),
  'score_table_grants', coalesce((select value from score_table_grants), '[]'::jsonb),
  'score_policies', coalesce((select value from score_policies), '[]'::jsonb),
  'model_registry', coalesce((select value from model_registry), '[]'::jsonb),
  'profile_score_state', coalesce((select value from profile_score_state), '[]'::jsonb),
  'latest_snapshots', coalesce((select value from latest_snapshots), '[]'::jsonb),
  'next_required_step', 'Use this contract map plus frontend score-reference grep to author paired cutover and rollback migrations.'
) as score_v22_official_read_cutover_preflight;
