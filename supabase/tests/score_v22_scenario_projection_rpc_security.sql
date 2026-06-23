-- ============================================================================
-- Score v2.2 IOU scenario projection RPC regression + security
--
-- Existing DEV fixture:
--   IOU             01c7b323-70cd-4c39-adc6-a59ebdf5182e
--   score agreement db90834c-948f-473a-831a-453132b05f1c
--   borrower        55e9da3f-3b96-405c-9afa-7b45c74c98dc
--   lender          dad0f041-6540-4f2e-9a2e-586d4901eea4
--
-- Fixture state:
--   $500 principal, $250 paid one day late, $250 due 2026-07-09.
--   Current v2.2 score 733, exposure 9, Visible Trust 724.
-- ============================================================================

begin;

do $tests$
declare
  c_iou constant uuid :=
    '01c7b323-70cd-4c39-adc6-a59ebdf5182e';
  c_borrower constant uuid :=
    '55e9da3f-3b96-405c-9afa-7b45c74c98dc';
  c_lender constant uuid :=
    'dad0f041-6540-4f2e-9a2e-586d4901eea4';
  c_as_of constant timestamptz :=
    '2026-06-22 12:00:00+00'::timestamptz;

  v_result jsonb;
  v_payoff jsonb;
  v_schedule jsonb;
  v_denied boolean;
  v_count integer;

  v_payment_count_before bigint;
  v_outcome_count_before bigint;
  v_contribution_count_before bigint;
  v_snapshot_count_before bigint;
begin
  -- 1. ACL contract.
  if not has_function_privilege(
    'authenticated',
    'public.get_my_iou_score_v22_scenario(uuid,text)',
    'EXECUTE'
  ) then
    raise exception
      'Scenario RPC regression: authenticated lacks EXECUTE on app wrapper';
  end if;

  if has_function_privilege(
    'anon',
    'public.get_my_iou_score_v22_scenario(uuid,text)',
    'EXECUTE'
  ) then
    raise exception
      'Scenario RPC regression: anon can execute app wrapper';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_scenario'
    and grantee = 'PUBLIC'
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'Scenario RPC regression: PUBLIC can execute app wrapper';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.score_v22_iou_scenario_projection_internal(uuid,uuid,text,timestamptz)',
    'EXECUTE'
  ) or has_function_privilege(
    'anon',
    'public.score_v22_iou_scenario_projection_internal(uuid,uuid,text,timestamptz)',
    'EXECUTE'
  ) then
    raise exception
      'Scenario RPC regression: internal projector exposed to an app role';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'score_v22_iou_scenario_projection_internal'
    and grantee = 'PUBLIC'
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'Scenario RPC regression: PUBLIC can execute internal projector';
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
      'Scenario RPC regression: score_agreements exposed to an app role';
  end if;

  -- 2. Anonymous caller denied.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'anon')::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_scenario(
      c_iou,
      'payoff_today'
    );
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'Scenario RPC regression: anonymous caller was not denied';
  end if;

  -- 3. Lender cannot read the borrower's projection.
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
    perform public.get_my_iou_score_v22_scenario(
      c_iou,
      'payoff_today'
    );
  exception
    when insufficient_privilege then
      if sqlerrm = 'IOU score scenario not found or not accessible' then
        v_denied := true;
      else
        raise;
      end if;
  end;

  if not v_denied then
    raise exception
      'Scenario RPC regression: non-subject lender was not denied';
  end if;

  -- 4. Unknown IOU uses the same generic denial.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', c_borrower::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_scenario(
      gen_random_uuid(),
      'payoff_today'
    );
  exception
    when insufficient_privilege then
      if sqlerrm = 'IOU score scenario not found or not accessible' then
        v_denied := true;
      else
        raise;
      end if;
  end;

  if not v_denied then
    raise exception
      'Scenario RPC regression: unknown IOU was not generically denied';
  end if;

  -- 5. Unsupported scenario fails closed after authorization.
  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_scenario(
      c_iou,
      'invented_scenario'
    );
  exception
    when sqlstate '22023' then
      if sqlerrm = 'Unsupported score scenario' then
        v_denied := true;
      else
        raise;
      end if;
  end;

  if not v_denied then
    raise exception
      'Scenario RPC regression: unsupported scenario did not fail closed';
  end if;

  -- 6. Record immutable table counts before projection calls.
  select count(*) into v_payment_count_before
  from public.payments;

  select count(*) into v_outcome_count_before
  from public.trust_outcome_events;

  select count(*) into v_contribution_count_before
  from public.score_v2_contributions;

  select count(*) into v_snapshot_count_before
  from public.trust_score_snapshots;

  -- 7. Borrower-facing wrapper returns the curated contract.
  v_result := public.get_my_iou_score_v22_scenario(
    c_iou,
    'pay_next_today'
  );

  if not (
    v_result ?& array[
      'scenario',
      'eligible',
      'paymentAmountCents',
      'currentScore',
      'projectedScore',
      'scoreDelta',
      'currentVisibleTrust',
      'projectedVisibleTrust',
      'visibleTrustDelta',
      'currentIouEffect',
      'projectedIouEffect',
      'currentExposure',
      'projectedExposure',
      'exposureReleased',
      'completionCreditUnlocked',
      'earlyBonusUnlocked',
      'retainedPenalty',
      'completesIou',
      'explanation'
    ]
  ) then
    raise exception
      'Scenario RPC regression: required response fields missing: %',
      v_result;
  end if;

  if v_result ?| array[
    'score_agreement_id',
    'scoreAgreementId',
    'payment_id',
    'paymentId',
    'user_id',
    'userId',
    'iou_id',
    'iouId',
    'metadata',
    'calculation_details'
  ] then
    raise exception
      'Scenario RPC regression: internal identifiers/details leaked: %',
      v_result;
  end if;

  if jsonb_typeof(v_result -> 'explanation') <> 'array'
     or jsonb_array_length(v_result -> 'explanation') = 0
  then
    raise exception
      'Scenario RPC regression: explanation must be a nonempty array: %',
      v_result;
  end if;

  -- 8. Deterministic fixture projection: pay next today.
  v_result := public.score_v22_iou_scenario_projection_internal(
    c_iou,
    c_borrower,
    'pay_next_today',
    c_as_of
  );

  if (v_result ->> 'scenario') <> 'pay_next_today'
     or not (v_result ->> 'eligible')::boolean
     or (v_result ->> 'paymentAmountCents')::bigint <> 25000
     or (v_result ->> 'currentScore')::integer <> 733
     or (v_result ->> 'projectedScore')::integer <> 761
     or (v_result ->> 'scoreDelta')::integer <> 28
     or (v_result ->> 'currentVisibleTrust')::integer <> 724
     or (v_result ->> 'projectedVisibleTrust')::integer <> 761
     or (v_result ->> 'visibleTrustDelta')::integer <> 37
     or (v_result ->> 'currentIouEffect')::integer <> -2
     or (v_result ->> 'projectedIouEffect')::integer <> 26
     or (v_result ->> 'currentExposure')::integer <> 9
     or (v_result ->> 'projectedExposure')::integer <> 0
     or (v_result ->> 'exposureReleased')::integer <> 9
     or (v_result ->> 'completionCreditUnlocked')::integer <> 22
     or (v_result ->> 'earlyBonusUnlocked')::integer <> 6
     or (v_result ->> 'retainedPenalty')::integer <> 2
     or not (v_result ->> 'completesIou')::boolean
  then
    raise exception
      'Scenario RPC regression: pay_next_today fixture mismatch: %',
      v_result;
  end if;

  -- 9. Deterministic fixture projection: payoff today.
  v_payoff := public.score_v22_iou_scenario_projection_internal(
    c_iou,
    c_borrower,
    'payoff_today',
    c_as_of
  );

  if (v_payoff ->> 'scenario') <> 'payoff_today'
     or not (v_payoff ->> 'eligible')::boolean
     or (v_payoff ->> 'paymentAmountCents')::bigint <> 25000
     or (v_payoff ->> 'currentScore')::integer <> 733
     or (v_payoff ->> 'projectedScore')::integer <> 761
     or (v_payoff ->> 'scoreDelta')::integer <> 28
     or (v_payoff ->> 'currentVisibleTrust')::integer <> 724
     or (v_payoff ->> 'projectedVisibleTrust')::integer <> 761
     or (v_payoff ->> 'visibleTrustDelta')::integer <> 37
     or (v_payoff ->> 'projectedIouEffect')::integer <> 26
     or (v_payoff ->> 'exposureReleased')::integer <> 9
     or (v_payoff ->> 'completionCreditUnlocked')::integer <> 22
     or (v_payoff ->> 'earlyBonusUnlocked')::integer <> 6
     or (v_payoff ->> 'retainedPenalty')::integer <> 2
     or not (v_payoff ->> 'completesIou')::boolean
  then
    raise exception
      'Scenario RPC regression: payoff_today fixture mismatch: %',
      v_payoff;
  end if;

  -- 10. Deterministic fixture projection: complete on schedule.
  v_schedule := public.score_v22_iou_scenario_projection_internal(
    c_iou,
    c_borrower,
    'complete_on_schedule',
    c_as_of
  );

  if (v_schedule ->> 'scenario') <> 'complete_on_schedule'
     or not (v_schedule ->> 'eligible')::boolean
     or (v_schedule ->> 'paymentAmountCents')::bigint <> 25000
     or (v_schedule ->> 'currentScore')::integer <> 733
     or (v_schedule ->> 'projectedScore')::integer <> 755
     or (v_schedule ->> 'scoreDelta')::integer <> 22
     or (v_schedule ->> 'currentVisibleTrust')::integer <> 724
     or (v_schedule ->> 'projectedVisibleTrust')::integer <> 755
     or (v_schedule ->> 'visibleTrustDelta')::integer <> 31
     or (v_schedule ->> 'currentIouEffect')::integer <> -2
     or (v_schedule ->> 'projectedIouEffect')::integer <> 20
     or (v_schedule ->> 'currentExposure')::integer <> 9
     or (v_schedule ->> 'projectedExposure')::integer <> 0
     or (v_schedule ->> 'exposureReleased')::integer <> 9
     or (v_schedule ->> 'completionCreditUnlocked')::integer <> 22
     or (v_schedule ->> 'earlyBonusUnlocked')::integer <> 0
     or (v_schedule ->> 'retainedPenalty')::integer <> 2
     or not (v_schedule ->> 'completesIou')::boolean
  then
    raise exception
      'Scenario RPC regression: complete_on_schedule fixture mismatch: %',
      v_schedule;
  end if;

  -- 11. Projection must remain read-only.
  if (select count(*) from public.payments) <> v_payment_count_before
     or (select count(*) from public.trust_outcome_events) <> v_outcome_count_before
     or (select count(*) from public.score_v2_contributions) <> v_contribution_count_before
     or (select count(*) from public.trust_score_snapshots) <> v_snapshot_count_before
  then
    raise exception
      'Scenario RPC regression: projection mutated financial or score evidence';
  end if;
end
$tests$;

select jsonb_build_object(
  'suite', 'Score v2.2 IOU scenario projection RPC',
  'passed', true,
  'app_wrapper_authenticated_only', true,
  'internal_projector_private', true,
  'borrower_only', true,
  'generic_denial', true,
  'unsupported_scenario_denied', true,
  'projection_read_only', true,
  'pay_next_fixture', jsonb_build_object(
    'current_score', 733,
    'projected_score', 761,
    'current_visible_trust', 724,
    'projected_visible_trust', 761,
    'visible_trust_delta', 37
  ),
  'payoff_fixture', jsonb_build_object(
    'current_score', 733,
    'projected_score', 761,
    'visible_trust_delta', 37
  ),
  'on_schedule_fixture', jsonb_build_object(
    'current_score', 733,
    'projected_score', 755,
    'visible_trust_delta', 31
  ),
  'cleanup', 'transaction_rollback'
) as score_v22_scenario_projection_rpc_summary;

rollback;
