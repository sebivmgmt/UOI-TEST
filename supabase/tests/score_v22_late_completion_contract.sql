-- =============================================================================
-- Score v2.2 late-payment-then-completion app contract regression
--
-- Purpose:
--   Prove that a late-installment penalty applies immediately, survives final
--   completion, and is netted against the unlocked completion reward.
--
-- Safety:
--   - DEV only
--   - disposable users / IOU / payments
--   - entire test runs inside one transaction and rolls back
--   - does not touch the real $500 fixture
-- =============================================================================

begin;

do $test$
declare
  v_run_id text :=
    'late_completion_' ||
    substring(replace(gen_random_uuid()::text, '-', ''), 1, 10);

  v_lender_id uuid := gen_random_uuid();
  v_borrower_id uuid := gen_random_uuid();

  v_iou_id uuid := gen_random_uuid();
  v_first_payment_id uuid := gen_random_uuid();
  v_second_payment_id uuid := gen_random_uuid();
  v_score_agreement_id uuid;

  v_before jsonb;
  v_after_first jsonb;
  v_after_second jsonb;
  v_internal jsonb;

  v_penalty_count integer;
  v_completion_count integer;
  v_early_bonus_count integer;
  v_contribution_count_before integer;
  v_contribution_count_after integer;

  v_penalty_points integer;
  v_completion_points integer;
  v_signed_total_before integer;
  v_signed_total_after integer;
begin
  raise notice
    '=== Score v2.2 late completion contract [%] ===',
    v_run_id;

  -- --------------------------------------------------------------------------
  -- Disposable identities. Profile rows are created by the existing auth-user
  -- trigger, matching the established ACH regression setup.
  -- --------------------------------------------------------------------------
  insert into auth.users (
    id,
    email,
    aud,
    role,
    email_confirmed_at,
    created_at,
    updated_at,
    raw_user_meta_data,
    is_anonymous
  )
  values
    (
      v_lender_id,
      v_run_id || '_lender@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Late Completion Test Lender"}'::jsonb,
      false
    ),
    (
      v_borrower_id,
      v_run_id || '_borrower@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Late Completion Test Borrower"}'::jsonb,
      false
    );

  update public.profiles
  set
    ach_status = 'ready',
    iou_score = 700,
    active_exposure_points = 0
  where id in (v_lender_id, v_borrower_id);

  -- --------------------------------------------------------------------------
  -- First-pair $500 IOU:
  --   payment 1: $250, due yesterday -> exactly one calendar day late
  --   payment 2: $250, due today     -> on time, no early bonus
  --
  -- Expected Score v2.2 math:
  --   pair-1 ceiling                       35
  --   base completion reward               28
  --   early pool                            7
  --   late penalty: round(35 * .5 * .15)    3
  --   completed net: 28 - 3                25
  -- --------------------------------------------------------------------------
  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status,
    activated_at
  )
  values (
    v_iou_id,
    v_lender_id,
    v_borrower_id,
    50000,
    0,
    current_date - 30,
    2,
    'monthly',
    'open',
    now()
  );

  insert into public.payments (
    id,
    iou_id,
    due_date,
    amount_cents
  )
  values
    (
      v_first_payment_id,
      v_iou_id,
      current_date - 1,
      25000
    ),
    (
      v_second_payment_id,
      v_iou_id,
      current_date,
      25000
    );

  select sa.id
  into strict v_score_agreement_id
  from public.score_agreements as sa
  where sa.source_type = 'personal_iou'
    and sa.source_id = v_iou_id
    and sa.user_id = v_borrower_id;

  -- --------------------------------------------------------------------------
  -- Pay installment 1 one day late.
  -- --------------------------------------------------------------------------
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  perform public.claim_payment(
    v_first_payment_id,
    v_borrower_id
  );

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_lender_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  perform public.pay_and_receipt(v_first_payment_id);

  -- Borrower-facing contract before completion.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_before :=
    public.get_my_iou_score_v22_progress(v_iou_id);

  if (v_before ->> 'model_version') <> 'v2.2-shadow'
     or (v_before ->> 'principal_cents')::bigint <> 50000
     or (v_before ->> 'paid_cents')::bigint <> 25000
     or (v_before ->> 'repayment_fraction')::numeric <> 0.5
     or (v_before ->> 'completion_progress_points')::integer <> 14
     or (v_before ->> 'completion_reward_max')::integer <> 28
     or (v_before ->> 'early_bonus_earned')::integer <> 0
     or (v_before ->> 'early_bonus_max')::integer <> 7
     or (v_before ->> 'pending_positive_points')::integer <> 14
     or (v_before ->> 'active_penalties')::integer <> 3
     or (v_before ->> 'projected_completed_contribution')::integer <> 11
     or (v_before ->> 'current_public_score_effect')::integer <> -3
     or (v_before ->> 'agreement_completed')::boolean
     or (v_before ->> 'positive_points_unlocked')::boolean
     or (
       v_before ->> 'positive_points_unlock_condition'
     ) <> 'Positive points unlock when the IOU is completed'
  then
    raise exception
      'Pre-completion app contract mismatch: %',
      v_before;
  end if;

  raise notice
    'PASS 1: one-day-late installment applies -3 immediately while +14 remains locked';

  -- --------------------------------------------------------------------------
  -- Pay installment 2 on time. This should complete the IOU, unlock only the
  -- 28-point base reward, and preserve the existing 3-point late penalty.
  -- --------------------------------------------------------------------------
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  perform public.claim_payment(
    v_second_payment_id,
    v_borrower_id
  );

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_lender_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  perform public.pay_and_receipt(v_second_payment_id);

  -- Read once through the borrower-facing RPC.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_after_first :=
    public.get_my_iou_score_v22_progress(v_iou_id);

  if (v_after_first ->> 'principal_cents')::bigint <> 50000
     or (v_after_first ->> 'paid_cents')::bigint <> 50000
     or (v_after_first ->> 'repayment_fraction')::numeric <> 1
     or (v_after_first ->> 'completion_progress_points')::integer <> 28
     or (v_after_first ->> 'completion_reward_max')::integer <> 28
     or (v_after_first ->> 'early_bonus_earned')::integer <> 0
     or (v_after_first ->> 'early_bonus_max')::integer <> 7
     or (v_after_first ->> 'pending_positive_points')::integer <> 28
     or (v_after_first ->> 'active_penalties')::integer <> 3
     or (
       v_after_first
       ->> 'projected_completed_contribution'
     )::integer <> 25
     or (
       v_after_first
       ->> 'current_public_score_effect'
     )::integer <> 25
     or not (v_after_first ->> 'agreement_completed')::boolean
     or not (v_after_first ->> 'positive_points_unlocked')::boolean
     or (
       v_after_first ->> 'positive_points_unlock_condition'
     ) <> 'unlocked'
  then
    raise exception
      'Completed app contract mismatch: %',
      v_after_first;
  end if;

  raise notice
    'PASS 2: completion unlocks +28, retains -3 penalty, and exposes net +25';

  -- --------------------------------------------------------------------------
  -- Ledger integrity and idempotency.
  -- --------------------------------------------------------------------------
  select
    count(*) filter (
      where c.contribution_type = 'payment_late_penalty'
        and c.impact_direction = 'penalty'
    )::integer,
    count(*) filter (
      where c.contribution_type = 'agreement_completion'
        and c.impact_direction = 'reward'
    )::integer,
    count(*) filter (
      where c.contribution_type = 'early_payment_bonus'
    )::integer,
    coalesce(sum(c.points_awarded) filter (
      where c.contribution_type = 'payment_late_penalty'
        and c.impact_direction = 'penalty'
    ), 0)::integer,
    coalesce(sum(c.points_awarded) filter (
      where c.contribution_type = 'agreement_completion'
        and c.impact_direction = 'reward'
    ), 0)::integer,
    count(*)::integer,
    coalesce(sum(
      case
        when c.impact_direction = 'penalty'
          then -c.points_awarded
        else c.points_awarded
      end
    ), 0)::integer
  into
    v_penalty_count,
    v_completion_count,
    v_early_bonus_count,
    v_penalty_points,
    v_completion_points,
    v_contribution_count_before,
    v_signed_total_before
  from public.score_v2_contributions as c
  where c.score_agreement_id = v_score_agreement_id
    and c.model_version = 'v2.2-shadow';

  if v_penalty_count <> 1
     or v_completion_count <> 1
     or v_early_bonus_count <> 0
     or v_penalty_points <> 3
     or v_completion_points <> 28
     or v_contribution_count_before <> 2
     or v_signed_total_before <> 25
  then
    raise exception
      'Completed ledger mismatch: penalty_count=%, completion_count=%, early_count=%, penalty_points=%, completion_points=%, row_count=%, signed_total=%',
      v_penalty_count,
      v_completion_count,
      v_early_bonus_count,
      v_penalty_points,
      v_completion_points,
      v_contribution_count_before,
      v_signed_total_before;
  end if;

  -- Exercise the generic v2 wrapper twice. No row or score may change.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );

  v_internal := public.recalculate_score_v2_agreement(
    v_score_agreement_id,
    'v2.2-shadow'
  );

  v_internal := public.recalculate_score_v2_agreement(
    v_score_agreement_id,
    'v2.2-shadow'
  );

  select
    count(*)::integer,
    coalesce(sum(
      case
        when c.impact_direction = 'penalty'
          then -c.points_awarded
        else c.points_awarded
      end
    ), 0)::integer
  into
    v_contribution_count_after,
    v_signed_total_after
  from public.score_v2_contributions as c
  where c.score_agreement_id = v_score_agreement_id
    and c.model_version = 'v2.2-shadow';

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_after_second :=
    public.get_my_iou_score_v22_progress(v_iou_id);

  if v_contribution_count_after <> v_contribution_count_before
     or v_signed_total_after <> v_signed_total_before
     or v_after_second is distinct from v_after_first
  then
    raise exception
      'Idempotency mismatch: before_rows=%, after_rows=%, before_signed=%, after_signed=%, first_rpc=%, second_rpc=%',
      v_contribution_count_before,
      v_contribution_count_after,
      v_signed_total_before,
      v_signed_total_after,
      v_after_first,
      v_after_second;
  end if;

  raise notice
    'PASS 3: repeated v2.2 recalculation and repeated borrower RPC reads are idempotent';
end
$test$;

select jsonb_build_object(
  'suite', 'Score v2.2 late-payment completion app contract',
  'passed', true,
  'fixture', 'disposable transaction fixture',
  'pre_completion', jsonb_build_object(
    'paid_cents', 25000,
    'pending_positive_points', 14,
    'active_penalty', 3,
    'current_public_score_effect', -3,
    'positive_points_unlocked', false
  ),
  'after_completion', jsonb_build_object(
    'paid_cents', 50000,
    'completion_reward', 28,
    'early_bonus', 0,
    'retained_penalty', 3,
    'net_public_score_effect', 25,
    'positive_points_unlocked', true
  ),
  'idempotent', true,
  'cleanup', 'transaction_rollback'
) as score_v22_late_completion_contract_summary;

rollback;
