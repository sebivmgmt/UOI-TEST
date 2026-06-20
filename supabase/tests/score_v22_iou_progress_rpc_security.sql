-- ============================================================================
-- Score v2.2 IOU-facing progress RPC security regression
--
-- Existing DEV fixture:
--   IOU             01c7b323-70cd-4c39-adc6-a59ebdf5182e
--   score agreement db90834c-948f-473a-831a-453132b05f1c
--   borrower        55e9da3f-3b96-405c-9afa-7b45c74c98dc
--   lender          dad0f041-6540-4f2e-9a2e-586d4901eea4
-- ============================================================================

begin;

do $tests$
declare
  c_iou constant uuid :=
    '01c7b323-70cd-4c39-adc6-a59ebdf5182e';
  c_score_agreement constant uuid :=
    'db90834c-948f-473a-831a-453132b05f1c';
  c_borrower constant uuid :=
    '55e9da3f-3b96-405c-9afa-7b45c74c98dc';
  c_lender constant uuid :=
    'dad0f041-6540-4f2e-9a2e-586d4901eea4';

  v_result jsonb;
  v_direct_result jsonb;
  v_denied boolean;
  v_count integer;
begin
  -- 1. score_agreements remains unreadable to app roles.
  select count(*)
  into v_count
  from information_schema.table_privileges
  where table_schema = 'public'
    and table_name = 'score_agreements'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'SELECT';

  if v_count <> 0 then
    raise exception
      'IOU progress RPC regression: score_agreements has % app-role SELECT grants',
      v_count;
  end if;

  -- 2. Anonymous callers are denied.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'anon')::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_progress(c_iou);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'IOU progress RPC regression: anonymous caller was not denied';
  end if;

  -- 3. The lender cannot resolve or read the borrower's score progress.
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
    perform public.get_my_iou_score_v22_progress(c_iou);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'IOU progress RPC regression: non-subject lender was not denied';
  end if;

  -- 4. An unknown IOU uses the same generic denial.
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
    perform public.get_my_iou_score_v22_progress(gen_random_uuid());
  exception
    when insufficient_privilege then
      if sqlerrm = 'IOU score progress not found or not accessible' then
        v_denied := true;
      else
        raise;
      end if;
  end;

  if not v_denied then
    raise exception
      'IOU progress RPC regression: unknown IOU was not generically denied';
  end if;

  -- 5. The borrower may call by ious.id and receives the same curated payload
  -- as the already-secured score-agreement RPC.
  v_result := public.get_my_iou_score_v22_progress(c_iou);
  v_direct_result := public.get_my_score_v22_progress(c_score_agreement);

  if v_result is distinct from v_direct_result then
    raise exception
      'IOU progress RPC regression: IOU wrapper payload differs from direct curated RPC. wrapper=%, direct=%',
      v_result,
      v_direct_result;
  end if;

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
      'IOU progress RPC regression: required response fields are missing: %',
      v_result;
  end if;

  if (v_result ->> 'score_agreement_id')::uuid <> c_score_agreement
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
      'IOU progress RPC regression: fixture payload mismatch: %',
      v_result;
  end if;
end
$tests$;

select jsonb_build_object(
  'suite', 'Score v2.2 IOU progress RPC security',
  'passed', true,
  'score_agreements_private', true,
  'anonymous_denied', true,
  'non_subject_denied', true,
  'unknown_iou_generically_denied', true,
  'subject_allowed_by_iou_id', true,
  'matches_curated_progress_rpc', true,
  'cleanup', 'transaction_rollback'
) as score_v22_iou_progress_rpc_security_summary;

rollback;
