begin;

-- ============================================================================
-- Score v2.2 correction audit/read layer
--
-- Goals:
--   1. Give trusted support/backend systems a complete correction audit trail.
--   2. Give the borrower a curated correction history for their own IOU.
--   3. Keep correction powers, internal event IDs, idempotency keys, internal
--      reasons, and raw metadata unavailable to normal app users.
-- ============================================================================

create or replace function public.score_v22_correction_audit_internal(
  p_score_agreement_id uuid,
  p_as_of timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_source_type text;
  v_corrections jsonb;
  v_effective_payment_outcomes jsonb;
begin
  select sa.source_type
  into v_source_type
  from public.score_agreements as sa
  where sa.id = p_score_agreement_id;

  if not found or v_source_type <> 'personal_iou' then
    raise exception 'Score v2.2 correction audit not found'
      using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'original_outcome_event_id', original.id,
        'correction_outcome_event_id', replacement.id,
        'payment_id',
          public.score_v22_event_payment_id(to_jsonb(replacement)),
        'payment_outcome_at', replacement.outcome_at,
        'corrected_at', replacement.created_at,
        'amount_cents', replacement.amount_cents,
        'previous_outcome_type', original.outcome_type,
        'corrected_outcome_type', replacement.outcome_type,
        'previous_days_early', coalesce(original.days_early, 0),
        'previous_days_late', coalesce(original.days_late, 0),
        'corrected_days_early', coalesce(replacement.days_early, 0),
        'corrected_days_late', coalesce(replacement.days_late, 0),
        'correction_reason', replacement.correction_reason,
        'correction_key', replacement.correction_key,
        'request_metadata',
          coalesce(
            replacement.metadata
              -> 'correction'
              -> 'request_metadata',
            '{}'::jsonb
          ),
        'previous_signed_points',
          coalesce(
            (
              select sum(
                case
                  when c.impact_direction = 'penalty'
                  then -c.points_awarded
                  else c.points_awarded
                end
              )::integer
              from public.score_v2_contributions as c
              where c.outcome_event_id = original.id
                and c.model_key = 'iou_score'
                and c.model_version = 'v2.2-shadow'
            ),
            0
          ),
        'corrected_signed_points',
          coalesce(
            (
              select sum(
                case
                  when c.impact_direction = 'penalty'
                  then -c.points_awarded
                  else c.points_awarded
                end
              )::integer
              from public.score_v2_contributions as c
              where c.outcome_event_id = replacement.id
                and c.model_key = 'iou_score'
                and c.model_version = 'v2.2-shadow'
            ),
            0
          ),
        'net_score_effect_change',
          coalesce(
            (
              select sum(
                case
                  when c.impact_direction = 'penalty'
                  then -c.points_awarded
                  else c.points_awarded
                end
              )::integer
              from public.score_v2_contributions as c
              where c.outcome_event_id = replacement.id
                and c.model_key = 'iou_score'
                and c.model_version = 'v2.2-shadow'
            ),
            0
          )
          -
          coalesce(
            (
              select sum(
                case
                  when c.impact_direction = 'penalty'
                  then -c.points_awarded
                  else c.points_awarded
                end
              )::integer
              from public.score_v2_contributions as c
              where c.outcome_event_id = original.id
                and c.model_key = 'iou_score'
                and c.model_version = 'v2.2-shadow'
            ),
            0
          )
      )
      order by replacement.created_at, replacement.id
    ),
    '[]'::jsonb
  )
  into v_corrections
  from public.trust_outcome_events as replacement
  join public.trust_outcome_events as original
    on original.id = replacement.supersedes_outcome_event_id
  where replacement.score_agreement_id = p_score_agreement_id
    and replacement.supersedes_outcome_event_id is not null
    and replacement.created_at <= p_as_of;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'outcome_event_id', e.id,
        'payment_id', public.score_v22_event_payment_id(to_jsonb(e)),
        'outcome_type', e.outcome_type,
        'outcome_at', e.outcome_at,
        'amount_cents', e.amount_cents,
        'days_early', coalesce(e.days_early, 0),
        'days_late', coalesce(e.days_late, 0),
        'is_correction', e.supersedes_outcome_event_id is not null,
        'supersedes_outcome_event_id', e.supersedes_outcome_event_id
      )
      order by e.outcome_at, e.id
    ),
    '[]'::jsonb
  )
  into v_effective_payment_outcomes
  from public.score_v22_effective_outcome_events(
    p_score_agreement_id,
    p_as_of
  ) as e
  where public.score_v22_event_type(to_jsonb(e)) in (
    'payment_paid_early',
    'payment_early',
    'payment_paid_on_time',
    'payment_on_time',
    'payment_paid_late',
    'payment_late'
  );

  return jsonb_build_object(
    'score_agreement_id', p_score_agreement_id,
    'model_version', 'v2.2-shadow',
    'as_of', p_as_of,
    'correction_count', jsonb_array_length(v_corrections),
    'has_corrections', jsonb_array_length(v_corrections) > 0,
    'corrections', v_corrections,
    'effective_payment_outcomes', v_effective_payment_outcomes
  );
end
$function$;

revoke all
  on function public.score_v22_correction_audit_internal(
    uuid,
    timestamptz
  )
  from public, anon, authenticated, service_role;

grant execute
  on function public.score_v22_correction_audit_internal(
    uuid,
    timestamptz
  )
  to service_role, postgres;

comment on function public.score_v22_correction_audit_internal(
  uuid,
  timestamptz
)
is
  'Internal Score v2.2 correction audit calculator. Returns full immutable correction edges, internal event IDs, correction reasons/keys, request metadata, and point-effect changes. Restricted to service_role and postgres.';


create or replace function public.get_score_v22_iou_correction_audit(
  p_iou_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_caller_role text;
  v_score_agreement_id uuid;
begin
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (
      nullif(
        current_setting('request.jwt.claims', true),
        ''
      )::jsonb ->> 'role'
    ),
    ''
  );

  if v_caller_role in ('anon', 'authenticated') then
    raise exception 'Service-role or postgres required'
      using errcode = '42501';
  elsif v_caller_role <> 'service_role'
        and session_user <> 'postgres' then
    raise exception 'Service-role or postgres required'
      using errcode = '42501';
  end if;

  begin
    select sa.id
    into strict v_score_agreement_id
    from public.score_agreements as sa
    where sa.source_type = 'personal_iou'
      and sa.source_id = p_iou_id;
  exception
    when no_data_found or too_many_rows then
      raise exception 'IOU correction audit not found'
        using errcode = '22023';
  end;

  return public.score_v22_correction_audit_internal(
    v_score_agreement_id,
    now()
  );
end
$function$;

revoke all
  on function public.get_score_v22_iou_correction_audit(uuid)
  from public, anon, authenticated, service_role;

grant execute
  on function public.get_score_v22_iou_correction_audit(uuid)
  to service_role, postgres;

comment on function public.get_score_v22_iou_correction_audit(uuid)
is
  'Trusted support/backend Score v2.2 correction audit RPC. Accepts ious.id and returns the full internal correction audit. Restricted to service_role and postgres.';


create or replace function public.get_my_iou_score_v22_correction_history(
  p_iou_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_caller_id uuid;
  v_caller_role text;
  v_score_agreement_id uuid;
  v_audit jsonb;
  v_curated_corrections jsonb;
begin
  v_caller_id := auth.uid();

  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (
      nullif(
        current_setting('request.jwt.claims', true),
        ''
      )::jsonb ->> 'role'
    ),
    ''
  );

  if v_caller_id is null then
    if v_caller_role in ('anon', 'authenticated') then
      raise exception 'Authentication required'
        using errcode = '42501';
    elsif v_caller_role = 'service_role' then
      null;
    elsif session_user = 'postgres' then
      null;
    else
      raise exception 'Authentication required'
        using errcode = '42501';
    end if;
  end if;

  begin
    select sa.id
    into strict v_score_agreement_id
    from public.score_agreements as sa
    where sa.source_type = 'personal_iou'
      and sa.source_id = p_iou_id
      and (
        v_caller_id is null
        or sa.user_id = v_caller_id
      );
  exception
    when no_data_found or too_many_rows then
      raise exception 'IOU correction history not found or not accessible'
        using errcode = '42501';
  end;

  v_audit := public.score_v22_correction_audit_internal(
    v_score_agreement_id,
    now()
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'payment_id', item -> 'payment_id',
        'payment_outcome_at', item -> 'payment_outcome_at',
        'corrected_at', item -> 'corrected_at',
        'previous_outcome',
          case item ->> 'previous_outcome_type'
            when 'payment_paid_early' then 'early'
            when 'payment_early' then 'early'
            when 'payment_paid_on_time' then 'on_time'
            when 'payment_on_time' then 'on_time'
            when 'payment_paid_late' then 'late'
            when 'payment_late' then 'late'
            else 'unknown'
          end,
        'corrected_outcome',
          case item ->> 'corrected_outcome_type'
            when 'payment_paid_early' then 'early'
            when 'payment_early' then 'early'
            when 'payment_paid_on_time' then 'on_time'
            when 'payment_on_time' then 'on_time'
            when 'payment_paid_late' then 'late'
            when 'payment_late' then 'late'
            else 'unknown'
          end,
        'notice', 'Payment outcome corrected after review'
      )
      order by
        (item ->> 'corrected_at')::timestamptz,
        item ->> 'payment_id'
    ),
    '[]'::jsonb
  )
  into v_curated_corrections
  from jsonb_array_elements(
    coalesce(v_audit -> 'corrections', '[]'::jsonb)
  ) as correction(item);

  return jsonb_build_object(
    'iou_id', p_iou_id,
    'model_version', 'v2.2-shadow',
    'correction_count', jsonb_array_length(v_curated_corrections),
    'has_corrections', jsonb_array_length(v_curated_corrections) > 0,
    'corrections', v_curated_corrections
  );
end
$function$;

revoke all
  on function public.get_my_iou_score_v22_correction_history(uuid)
  from public, anon, authenticated, service_role;

grant execute
  on function public.get_my_iou_score_v22_correction_history(uuid)
  to authenticated, service_role, postgres;

comment on function public.get_my_iou_score_v22_correction_history(uuid)
is
  'Authenticated borrower-facing Score v2.2 correction history RPC. Returns only a curated correction notice for the caller''s own personal IOU. It does not expose internal outcome-event IDs, correction reasons, idempotency keys, point calculations, or raw metadata.';


-- --------------------------------------------------------------------------
-- Fail-closed deployment invariants.
-- --------------------------------------------------------------------------
do $invariants$
declare
  v_count integer;
  v_security_definer boolean;
begin
  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'score_v22_correction_audit_internal',
      'get_score_v22_iou_correction_audit'
    )
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'Internal/support correction audit functions are exposed to an app role';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_correction_history'
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_count <> 1 then
    raise exception
      'authenticated must have exactly one EXECUTE grant on borrower correction history; found %',
      v_count;
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_correction_history'
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'PUBLIC/anon must not execute borrower correction history';
  end if;

  select p.prosecdef
  into v_security_definer
  from pg_proc as p
  join pg_namespace as n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_my_iou_score_v22_correction_history'
    and pg_get_function_identity_arguments(p.oid) = 'p_iou_id uuid';

  if v_security_definer is distinct from true then
    raise exception
      'Borrower correction history RPC must remain SECURITY DEFINER';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'record_score_v22_payment_outcome_correction'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'Correction writer became exposed to an app role';
  end if;

  select count(*)
  into v_count
  from information_schema.table_privileges
  where table_schema = 'public'
    and table_name = 'score_agreements'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'SELECT';

  if v_count <> 0 then
    raise exception
      'score_agreements SELECT was exposed to an app role';
  end if;
end
$invariants$;

commit;
