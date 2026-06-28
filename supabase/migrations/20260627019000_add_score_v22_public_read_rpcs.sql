begin;

-- ============================================================================
-- Score v2.2 Public Read RPCs
-- DEV project only: colkilearqxuyldzjutw
-- NEVER apply to LIVE project: clxfsghyasjmfoxmhpxv
--
-- Adds two authenticated public-score bridge RPCs for frontend screens that
-- display another user's score. Both delegate exclusively to the canonical
-- internal function — no independent score arithmetic, no snapshot reads,
-- no profiles.iou_score access.
--
--   A. get_public_iou_score_v22(p_user_id uuid)
--      Single-user lookup. Returns zero rows for non-existent profiles.
--
--   B. get_public_iou_scores_v22(p_user_ids uuid[])
--      Batch lookup. At most 100 IDs; deduplicates; skips non-existent profiles.
--
-- Both expose only: user_id, model_version, public_score, visible_trust,
-- trust_tier, active_exposure_points.
-- No email, proof, confidence, risk, strike, private-note, or evidence fields.
--
-- Depends on: 20260627018000_score_v22_official_read_cutover.sql
--             (score_v22_current_state_internal must exist)
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- A. get_public_iou_score_v22(p_user_id uuid)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.get_public_iou_score_v22(p_user_id uuid)
returns table (
  user_id                uuid,
  model_version          text,
  public_score           integer,
  visible_trust          integer,
  trust_tier             text,
  active_exposure_points integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller_id   uuid;
  v_caller_role text;
begin
  v_caller_id   := auth.uid();
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  if v_caller_id is null then
    if v_caller_role in ('anon', 'authenticated') then
      raise exception 'Authentication required' using errcode = '42501';
    elsif v_caller_role = 'service_role' then
      null;
    elsif session_user = 'postgres' then
      null;
    else
      raise exception 'Authentication required' using errcode = '42501';
    end if;
  end if;

  -- Profile existence check via the JOIN — returns zero rows for unknown IDs
  -- without calling score_v22_current_state_internal (which raises on missing profile).
  return query
  select
    p.id,
    cs.model_version,
    cs.shadow_score,
    cs.visible_trust,
    cs.trust_tier,
    cs.active_exposure_points
  from public.profiles p
  cross join lateral (
    select * from public.score_v22_current_state_internal(p.id)
  ) cs
  where p.id = p_user_id;
end;
$$;

revoke all on function public.get_public_iou_score_v22(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.get_public_iou_score_v22(uuid)
  to authenticated, service_role;

comment on function public.get_public_iou_score_v22(uuid) is
  'Public score bridge for authenticated callers viewing another user''s score. '
  'Delegates to score_v22_current_state_internal; exposes no private fields. '
  'Returns zero rows when the profile does not exist.';


-- ─────────────────────────────────────────────────────────────────────────────
-- B. get_public_iou_scores_v22(p_user_ids uuid[])
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.get_public_iou_scores_v22(p_user_ids uuid[])
returns table (
  user_id                uuid,
  model_version          text,
  public_score           integer,
  visible_trust          integer,
  trust_tier             text,
  active_exposure_points integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller_id   uuid;
  v_caller_role text;
begin
  v_caller_id   := auth.uid();
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  if v_caller_id is null then
    if v_caller_role in ('anon', 'authenticated') then
      raise exception 'Authentication required' using errcode = '42501';
    elsif v_caller_role = 'service_role' then
      null;
    elsif session_user = 'postgres' then
      null;
    else
      raise exception 'Authentication required' using errcode = '42501';
    end if;
  end if;

  -- array_length(null, 1) returns null, so this check is skipped for null/empty arrays.
  if array_length(p_user_ids, 1) > 100 then
    raise exception 'get_public_iou_scores_v22: p_user_ids may contain at most 100 elements'
      using errcode = '22023';
  end if;

  -- unnest(null) and unnest('{}') both produce zero rows — null/empty arrays return nothing.
  -- DISTINCT deduplicates. NULL elements are excluded by the JOIN predicate.
  -- Only existing profiles are returned (inner join).
  return query
  select
    p.id,
    cs.model_version,
    cs.shadow_score,
    cs.visible_trust,
    cs.trust_tier,
    cs.active_exposure_points
  from (
    select distinct u.uid
    from unnest(p_user_ids) as u(uid)
    where u.uid is not null
  ) deduped
  join public.profiles p on p.id = deduped.uid
  cross join lateral (
    select * from public.score_v22_current_state_internal(p.id)
  ) cs;
end;
$$;

revoke all on function public.get_public_iou_scores_v22(uuid[])
  from public, anon, authenticated, service_role;

grant execute on function public.get_public_iou_scores_v22(uuid[])
  to authenticated, service_role;

comment on function public.get_public_iou_scores_v22(uuid[]) is
  'Batch public score bridge for authenticated callers. At most 100 IDs; '
  'deduplicates input; returns only existing profiles; delegates each result '
  'to score_v22_current_state_internal; exposes no private fields.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Fail-closed deployment invariants
-- ─────────────────────────────────────────────────────────────────────────────

do $invariants$
declare
  v_count            integer;
  v_security_definer boolean;
begin
  -- A: get_public_iou_score_v22 is SECURITY DEFINER
  select p.prosecdef into v_security_definer
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_public_iou_score_v22'
    and pg_get_function_identity_arguments(p.oid) = 'p_user_id uuid';

  if v_security_definer is distinct from true then
    raise exception 'get_public_iou_score_v22 must be SECURITY DEFINER';
  end if;

  -- A: authenticated has EXECUTE
  select count(*) into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name   = 'get_public_iou_score_v22'
    and grantee        = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_count <> 1 then
    raise exception 'authenticated must have exactly one EXECUTE grant on get_public_iou_score_v22; found %', v_count;
  end if;

  -- A: anon/PUBLIC do not have EXECUTE
  select count(*) into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name   = 'get_public_iou_score_v22'
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception 'PUBLIC/anon must not execute get_public_iou_score_v22';
  end if;

  -- B: get_public_iou_scores_v22 is SECURITY DEFINER
  select p.prosecdef into v_security_definer
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_public_iou_scores_v22'
    and pg_get_function_identity_arguments(p.oid) = 'p_user_ids uuid[]';

  if v_security_definer is distinct from true then
    raise exception 'get_public_iou_scores_v22 must be SECURITY DEFINER';
  end if;

  -- B: authenticated has EXECUTE
  select count(*) into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name   = 'get_public_iou_scores_v22'
    and grantee        = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_count <> 1 then
    raise exception 'authenticated must have exactly one EXECUTE grant on get_public_iou_scores_v22; found %', v_count;
  end if;

  -- B: anon/PUBLIC do not have EXECUTE
  select count(*) into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name   = 'get_public_iou_scores_v22'
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception 'PUBLIC/anon must not execute get_public_iou_scores_v22';
  end if;

  -- Canonical internal function remains restricted from authenticated
  select count(*) into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name   = 'score_v22_current_state_internal'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception 'score_v22_current_state_internal must not be directly callable by PUBLIC/anon/authenticated';
  end if;

  raise notice 'Invariants OK: both public read RPCs correctly secured';
end
$invariants$;

commit;
