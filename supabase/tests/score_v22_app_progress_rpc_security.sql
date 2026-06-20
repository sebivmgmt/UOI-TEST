-- ============================================================================
-- Score v2.2 app-facing progress RPC security regression
--
-- Existing DEV fixture:
--   score agreement db90834c-948f-473a-831a-453132b05f1c
--   borrower        55e9da3f-3b96-405c-9afa-7b45c74c98dc
--   lender          dad0f041-6540-4f2e-9a2e-586d4901eea4
-- ============================================================================

begin;

do $tests$
declare
  c_agreement constant uuid :=
    'db90834c-948f-473a-831a-453132b05f1c';
  c_borrower constant uuid :=
    '55e9da3f-3b96-405c-9afa-7b45c74c98dc';
  c_lender constant uuid :=
    'dad0f041-6540-4f2e-9a2e-586d4901eea4';

  v_result jsonb;
  v_denied boolean;
  v_count integer;
begin
  -- 1. Anonymous callers are denied.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'anon')::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_score_v22_progress(c_agreement);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'App RPC regression: anonymous caller was not denied';
  end if;

  -- 2. The lender cannot read the borrower-owned score progress.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', c_lender::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_score_v22_progress(c_agreement);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'App RPC regression: non-subject lender was not denied';
  end if;

  -- 3. The score subject may read the curated payload.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', c_borrower::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_result := public.get_my_score_v22_progress(c_agreement);

  if not (
    v_result ?& array[
      'score_agreement_id',
      'model_version',
      'principal_cents',
      'paid_cents',
      'repayment_fraction',
      'completion_progress_points',
      'completion_reward_max',
      'early_bonus_earned',
      'early_bonus_max',
      'pending_positive_points',
      'active_penalties',
      'projected_completed_contribution',
      'current_public_score_effect',
      'agreement_completed',
      'positive_points_unlocked',
      'positive_points_unlock_condition'
    ]
  ) then
    raise exception
      'App RPC regression: required response fields are missing: %',
      v_result;
  end if;

  if v_result ?| array[
    'pair_index',
    'evidence_cutoff',
    'as_of',
    'completion_outcome_at',
    'paid_installment_count'
  ] then
    raise exception
      'App RPC regression: internal-only fields leaked: %',
      v_result;
  end if;

  if (v_result ->> 'score_agreement_id')::uuid <> c_agreement
     or v_result ->> 'model_version' <> 'v2.2-shadow'
     or (v_result ->> 'principal_cents')::bigint <> 50000
     or (v_result ->> 'paid_cents')::bigint <> 25000
     or (v_result ->> 'completion_progress_points')::integer <> 11
     or (v_result ->> 'completion_reward_max')::integer <> 22
     or (v_result ->> 'early_bonus_earned')::integer <> 0
     or (v_result ->> 'early_bonus_max')::integer <> 6
     or (v_result ->> 'pending_positive_points')::integer <> 11
     or (v_result ->> 'active_penalties')::integer <> 2
     or (v_result ->> 'projected_completed_contribution')::integer <> 9
     or (v_result ->> 'current_public_score_effect')::integer <> -2
     or (v_result ->> 'agreement_completed')::boolean
     or (v_result ->> 'positive_points_unlocked')::boolean
  then
    raise exception
      'App RPC regression: fixture payload mismatch: %',
      v_result;
  end if;

  -- 4. Normal app roles still cannot call the internal calculator directly.
  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'score_v22_pending_agreement_progress'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'App RPC regression: internal calculator has % app-role grants',
      v_count;
  end if;
end
$tests$;

select jsonb_build_object(
  'suite', 'Score v2.2 app progress RPC security',
  'passed', true,
  'anonymous_denied', true,
  'non_subject_denied', true,
  'subject_allowed', true,
  'internal_calculator_private', true,
  'curated_payload_only', true,
  'cleanup', 'transaction_rollback'
) as score_v22_app_rpc_security_summary;

rollback;
