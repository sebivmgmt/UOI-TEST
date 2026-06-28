-- ============================================================================
-- Score v2.2 late-payment scenario projection RPC regression + security
--
-- Existing DEV fixture:
--   IOU             01c7b323-70cd-4c39-adc6-a59ebdf5182e
--   payment         eae26e60-240f-479d-9528-c8d71432cf5b
--   borrower        55e9da3f-3b96-405c-9afa-7b45c74c98dc
--   lender          dad0f041-6540-4f2e-9a2e-586d4901eea4
--
-- Fixture state:
--   $500 principal, $250 paid one day late, $250 remaining.
--   Current v2.2 score 733, exposure 9, Visible Trust 724.
-- ============================================================================

begin;

create temporary table score_v22_late_scenario_test_result (
  summary jsonb not null
) on commit drop;

do $tests$
declare
  c_iou constant uuid :=
    '01c7b323-70cd-4c39-adc6-a59ebdf5182e';
  c_payment constant uuid :=
    'eae26e60-240f-479d-9528-c8d71432cf5b';
  c_borrower constant uuid :=
    '55e9da3f-3b96-405c-9afa-7b45c74c98dc';
  c_lender constant uuid :=
    'dad0f041-6540-4f2e-9a2e-586d4901eea4';

  v_result jsonb;
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
    'public.get_my_iou_score_v22_late_scenario(uuid,uuid,integer)',
    'EXECUTE'
  ) then
    raise exception
      'Late scenario RPC regression: authenticated lacks EXECUTE on app wrapper';
  end if;

  if has_function_privilege(
    'anon',
    'public.get_my_iou_score_v22_late_scenario(uuid,uuid,integer)',
    'EXECUTE'
  ) then
    raise exception
      'Late scenario RPC regression: anon can execute app wrapper';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.score_v22_iou_late_scenario_projection_internal(uuid,uuid,uuid,integer,timestamptz)',
    'EXECUTE'
  ) then
    raise exception
      'Late scenario RPC regression: internal projector exposed to authenticated';
  end if;

  -- 2. Anonymous caller denied.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'anon')::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_late_scenario(
      c_iou,
      c_payment,
      7
    );
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'Late scenario RPC regression: anonymous caller was not denied';
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
    perform public.get_my_iou_score_v22_late_scenario(
      c_iou,
      c_payment,
      7
    );
  exception
    when insufficient_privilege then
      if sqlerrm = 'IOU late scenario not found or not accessible' then
        v_denied := true;
      else
        raise;
      end if;
  end;

  if not v_denied then
    raise exception
      'Late scenario RPC regression: lender was not denied';
  end if;

  -- 4. Borrower context.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', c_borrower::text,
      'role', 'authenticated'
    )::text,
    true
  );

  -- Unsupported checkpoint fails closed.
  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_late_scenario(
      c_iou,
      c_payment,
      3
    );
  exception
    when sqlstate '22023' then
      if sqlerrm = 'Unsupported late-payment checkpoint' then
        v_denied := true;
      else
        raise;
      end if;
  end;

  if not v_denied then
    raise exception
      'Late scenario RPC regression: unsupported checkpoint did not fail closed';
  end if;

  -- 5. Immutable table counts before calls.
  select count(*) into v_payment_count_before
  from public.payments;

  select count(*) into v_outcome_count_before
  from public.trust_outcome_events;

  select count(*) into v_contribution_count_before
  from public.score_v2_contributions;

  select count(*) into v_snapshot_count_before
  from public.trust_score_snapshots;

  -- 6. Validate all supported checkpoints.
  v_result := public.get_my_iou_score_v22_late_scenario(
    c_iou,
    c_payment,
    1
  );

  if (v_result ->> 'additionalLatePenalty')::integer <> 2
     or (v_result ->> 'totalRetainedPenalty')::integer <> 4
     or (v_result ->> 'projectedScore')::integer <> 753
     or (v_result ->> 'projectedVisibleTrust')::integer <> 753
     or (v_result ->> 'opportunityLossVsPayNow')::integer <> 8
  then
    raise exception
      'Late scenario RPC regression: 1-day fixture mismatch: %',
      v_result;
  end if;

  v_result := public.get_my_iou_score_v22_late_scenario(
    c_iou,
    c_payment,
    7
  );

  if (v_result ->> 'additionalLatePenalty')::integer <> 4
     or (v_result ->> 'totalRetainedPenalty')::integer <> 6
     or (v_result ->> 'projectedScore')::integer <> 751
     or (v_result ->> 'projectedVisibleTrust')::integer <> 751
     or (v_result ->> 'opportunityLossVsPayNow')::integer <> 10
  then
    raise exception
      'Late scenario RPC regression: 7-day fixture mismatch: %',
      v_result;
  end if;

  v_result := public.get_my_iou_score_v22_late_scenario(
    c_iou,
    c_payment,
    14
  );

  if (v_result ->> 'additionalLatePenalty')::integer <> 7
     or (v_result ->> 'totalRetainedPenalty')::integer <> 9
     or (v_result ->> 'projectedScore')::integer <> 748
     or (v_result ->> 'projectedVisibleTrust')::integer <> 748
     or (v_result ->> 'opportunityLossVsPayNow')::integer <> 13
  then
    raise exception
      'Late scenario RPC regression: 14-day fixture mismatch: %',
      v_result;
  end if;

  v_result := public.get_my_iou_score_v22_late_scenario(
    c_iou,
    c_payment,
    30
  );

  if (v_result ->> 'additionalLatePenalty')::integer <> 11
     or (v_result ->> 'totalRetainedPenalty')::integer <> 13
     or (v_result ->> 'projectedScore')::integer <> 744
     or (v_result ->> 'projectedVisibleTrust')::integer <> 744
     or (v_result ->> 'opportunityLossVsPayNow')::integer <> 17
  then
    raise exception
      'Late scenario RPC regression: 30-day fixture mismatch: %',
      v_result;
  end if;

  if not (
    v_result ?& array[
      'eligible',
      'daysLate',
      'paymentAmountCents',
      'dueDate',
      'currentScore',
      'projectedScore',
      'scoreDelta',
      'currentVisibleTrust',
      'projectedVisibleTrust',
      'visibleTrustDelta',
      'currentIouEffect',
      'projectedIouEffect',
      'additionalLatePenalty',
      'totalRetainedPenalty',
      'currentExposure',
      'projectedExposure',
      'completionCreditStillLocked',
      'earlyBonusStillLocked',
      'completesIou',
      'payNowProjectedScore',
      'payNowProjectedVisibleTrust',
      'opportunityLossVsPayNow',
      'explanation'
    ]
  ) then
    raise exception
      'Late scenario RPC regression: required response fields missing: %',
      v_result;
  end if;

  if v_result ?| array[
    'score_agreement_id',
    'scoreAgreementId',
    'user_id',
    'userId',
    'iou_id',
    'iouId',
    'metadata',
    'calculation_details'
  ] then
    raise exception
      'Late scenario RPC regression: internal data leaked: %',
      v_result;
  end if;

  if jsonb_typeof(v_result -> 'explanation') <> 'array'
     or jsonb_array_length(v_result -> 'explanation') < 3
  then
    raise exception
      'Late scenario RPC regression: explanation missing: %',
      v_result;
  end if;

  -- 7. Projection remains read-only.
  if (select count(*) from public.payments) <> v_payment_count_before
     or (select count(*) from public.trust_outcome_events) <> v_outcome_count_before
     or (select count(*) from public.score_v2_contributions) <> v_contribution_count_before
     or (select count(*) from public.trust_score_snapshots) <> v_snapshot_count_before
  then
    raise exception
      'Late scenario RPC regression: projection mutated authoritative records';
  end if;

  -- 8. Summary.
  insert into score_v22_late_scenario_test_result(summary)
  values (jsonb_build_object(
    'suite', 'Score v2.2 IOU late scenario projection RPC',
    'passed', true,
    'cleanup', 'transaction_rollback',
    'borrower_only', true,
    'projection_read_only', true,
    'internal_projector_private', true,
    'supported_checkpoints', jsonb_build_array(1, 7, 14, 30),
    'fixture_expectations', jsonb_build_object(
      'one_day', jsonb_build_object(
        'additional_penalty', 2,
        'projected_score', 753,
        'opportunity_loss_vs_pay_now', 8
      ),
      'seven_days', jsonb_build_object(
        'additional_penalty', 4,
        'projected_score', 751,
        'opportunity_loss_vs_pay_now', 10
      ),
      'fourteen_days', jsonb_build_object(
        'additional_penalty', 7,
        'projected_score', 748,
        'opportunity_loss_vs_pay_now', 13
      ),
      'thirty_days', jsonb_build_object(
        'additional_penalty', 11,
        'projected_score', 744,
        'opportunity_loss_vs_pay_now', 17
      )
    )
  ));
end
$tests$;

select summary as score_v22_late_scenario_projection_rpc_summary
from score_v22_late_scenario_test_result;

rollback;
