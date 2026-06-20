begin;

-- ============================================================================
-- Score v2.2 authenticated app-facing progress RPC
--
-- Internal calculator remains postgres/service_role only:
--   score_v22_pending_agreement_progress(uuid, timestamptz)
--
-- App clients receive only a curated progress payload and may only read the
-- score agreement whose subject user_id equals auth.uid().
-- ============================================================================

create or replace function public.get_my_score_v22_progress(
  p_score_agreement_id uuid
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
  v_subject_user_id uuid;
  v_source_type text;
  v_progress jsonb;
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
    -- App-role claims must always carry an authenticated user id. This check
    -- intentionally wins over the postgres session bypass so Management API
    -- regressions can accurately simulate anon/authenticated callers.
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

  select
    sa.user_id,
    sa.source_type
  into
    v_subject_user_id,
    v_source_type
  from public.score_agreements as sa
  where sa.id = p_score_agreement_id;

  -- Use one generic denial for missing, unsupported, and unauthorized records.
  -- This prevents callers from probing whether another agreement UUID exists.
  if not found
     or v_source_type <> 'personal_iou'
     or (
       v_caller_id is not null
       and v_caller_id <> v_subject_user_id
     ) then
    raise exception 'Score progress not found or not accessible'
      using errcode = '42501';
  end if;

  v_progress := public.score_v22_pending_agreement_progress(
    p_score_agreement_id,
    now()
  );

  return jsonb_build_object(
    'score_agreement_id',
      v_progress -> 'score_agreement_id',
    'model_version',
      v_progress -> 'model_version',
    'principal_cents',
      v_progress -> 'principal_cents',
    'paid_cents',
      v_progress -> 'paid_cents',
    'repayment_fraction',
      v_progress -> 'repayment_fraction',
    'completion_progress_points',
      v_progress -> 'completion_progress_points',
    'completion_reward_max',
      v_progress -> 'completion_reward_max',
    'early_bonus_earned',
      v_progress -> 'early_bonus_earned',
    'early_bonus_max',
      v_progress -> 'early_bonus_max',
    'pending_positive_points',
      v_progress -> 'gross_points_earned',
    'active_penalties',
      v_progress -> 'active_penalties',
    'projected_completed_contribution',
      v_progress -> 'projected_net_contribution',
    'current_public_score_effect',
      v_progress -> 'current_public_score_effect',
    'agreement_completed',
      v_progress -> 'agreement_completed',
    'positive_points_unlocked',
      v_progress -> 'positive_points_unlocked',
    'positive_points_unlock_condition',
      v_progress -> 'positive_points_unlock_condition'
  );
end
$function$;

revoke all
  on function public.get_my_score_v22_progress(uuid)
  from public, anon, authenticated, service_role;

grant execute
  on function public.get_my_score_v22_progress(uuid)
  to authenticated, service_role, postgres;

comment on function public.get_my_score_v22_progress(uuid)
is
  'Authenticated app-facing Score v2.2 progress RPC. A user may read only score agreements where score_agreements.user_id = auth.uid(). Returns a curated payload and does not expose internal evidence timestamps or pair-calculation fields.';

-- Preserve the internal calculator boundary explicitly.
revoke all
  on function public.score_v22_pending_agreement_progress(uuid, timestamptz)
  from public, anon, authenticated;

grant execute
  on function public.score_v22_pending_agreement_progress(uuid, timestamptz)
  to postgres, service_role;

-- --------------------------------------------------------------------------
-- Fail-closed deployment invariants.
-- --------------------------------------------------------------------------
do $invariants$
declare
  v_count integer;
  v_security_definer boolean;
begin
  select p.prosecdef
  into v_security_definer
  from pg_proc as p
  join pg_namespace as n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_my_score_v22_progress'
    and pg_get_function_identity_arguments(p.oid)
        = 'p_score_agreement_id uuid';

  if v_security_definer is distinct from true then
    raise exception
      'get_my_score_v22_progress must remain SECURITY DEFINER';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_score_v22_progress'
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_count <> 1 then
    raise exception
      'authenticated must have exactly one EXECUTE grant on get_my_score_v22_progress; found %',
      v_count;
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_score_v22_progress'
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'PUBLIC/anon must not execute get_my_score_v22_progress';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'score_v22_pending_agreement_progress'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'Internal Score v2.2 progress calculator is exposed to an app role';
  end if;
end
$invariants$;

commit;
