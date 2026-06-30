-- =============================================================================
-- Score v2.2 append-only correction regression
--
-- Scenario:
--   1. Disposable $500 IOU logs a one-day-late $250 installment (-3).
--   2. Trusted correction reclassifies that immutable outcome as on-time.
--   3. Original outcome and penalty contribution remain in audit history.
--   4. Effective progress, snapshot, and final completion ignore the superseded
--      penalty and use the corrected outcome.
--   5. Replaying the same correction is idempotent.
--
-- Entire test rolls back. The real fixture is untouched.
-- =============================================================================

begin;

do $test$
declare
  v_run_id text :=
    'v22_correction_' ||
    substring(replace(gen_random_uuid()::text, '-', ''), 1, 10);

  v_lender_id uuid := gen_random_uuid();
  v_borrower_id uuid := gen_random_uuid();
  v_iou_id uuid := gen_random_uuid();
  v_first_payment_id uuid := gen_random_uuid();
  v_second_payment_id uuid := gen_random_uuid();
  v_score_agreement_id uuid;
  v_late_outcome_id uuid;
  v_correction_outcome_id uuid;
  v_snapshot_id uuid;

  v_before jsonb;
  v_after_correction jsonb;
  v_after_completion jsonb;
  v_after_recalc jsonb;
  v_correction_first jsonb;
  v_correction_replay jsonb;

  v_original_outcome_count integer;
  v_correction_outcome_count integer;
  v_original_penalty_count integer;
  v_effective_penalty_count integer;
  v_effective_signed_total integer;
  v_total_contribution_rows integer;
  v_mutation_blocked boolean;
  v_delete_blocked boolean;
  v_app_execute_count integer;
  v_snapshot record;
begin
  raise notice
    '=== Score v2.2 correction regression [%] ===',
    v_run_id;

  -- --------------------------------------------------------------------------
  -- Security boundary: correction writer is backend-only.
  -- --------------------------------------------------------------------------
  select count(*)
  into v_app_execute_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name =
      'record_score_v22_payment_outcome_correction'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_app_execute_count <> 0 then
    raise exception
      'Correction writer is exposed to an app role';
  end if;

  -- --------------------------------------------------------------------------
  -- Disposable identities and first-pair $500 IOU.
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
      '{"full_name":"Correction Test Lender"}'::jsonb,
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
      '{"full_name":"Correction Test Borrower"}'::jsonb,
      false
    );

  update public.profiles
  set
    state = 'GA',
    ach_status = 'ready',
    iou_score = 700,
    active_exposure_points = 0
  where id in (v_lender_id, v_borrower_id);

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
  -- Log first installment as one day late.
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

  select e.id
  into strict v_late_outcome_id
  from public.trust_outcome_events as e
  where e.score_agreement_id = v_score_agreement_id
    and e.outcome_type = 'payment_paid_late'
    and public.score_v22_event_payment_id(to_jsonb(e))
        = v_first_payment_id;

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

  if (v_before ->> 'paid_cents')::bigint <> 25000
     or (v_before ->> 'completion_progress_points')::integer <> 14
     or (v_before ->> 'active_penalties')::integer <> 3
     or (v_before ->> 'current_public_score_effect')::integer <> -3
     or (v_before ->> 'positive_points_unlocked')::boolean then
    raise exception
      'Unexpected pre-correction progress: %',
      v_before;
  end if;

  raise notice
    'PASS 1: original late event applies -3 immediately';

  -- --------------------------------------------------------------------------
  -- Append-only correction: late -> on-time.
  -- --------------------------------------------------------------------------
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );

  v_correction_first :=
    public.record_score_v22_payment_outcome_correction(
      v_late_outcome_id,
      'payment_paid_on_time',
      'Verified lender timestamp showed payment was received by the due date',
      v_run_id || ':payment-1:on-time',
      null,
      null,
      jsonb_build_object(
        'test_run_id', v_run_id,
        'verification_source', 'disposable_regression'
      )
    );

  v_correction_outcome_id :=
    (v_correction_first ->> 'correction_outcome_event_id')::uuid;

  if (v_correction_first ->> 'replayed')::boolean then
    raise exception
      'First correction call incorrectly reported replay';
  end if;

  -- Exact replay must return the same event without inserting another row.
  v_correction_replay :=
    public.record_score_v22_payment_outcome_correction(
      v_late_outcome_id,
      'payment_paid_on_time',
      'Verified lender timestamp showed payment was received by the due date',
      v_run_id || ':payment-1:on-time',
      null,
      null,
      jsonb_build_object(
        'test_run_id', v_run_id,
        'verification_source', 'disposable_regression'
      )
    );

  if not (v_correction_replay ->> 'replayed')::boolean
     or (
       v_correction_replay
       ->> 'correction_outcome_event_id'
     )::uuid <> v_correction_outcome_id then
    raise exception
      'Correction replay was not idempotent: first=%, replay=%',
      v_correction_first,
      v_correction_replay;
  end if;

  select
    count(*) filter (where e.id = v_late_outcome_id)::integer,
    count(*) filter (
      where e.id = v_correction_outcome_id
        and e.supersedes_outcome_event_id = v_late_outcome_id
        and e.outcome_type = 'payment_paid_on_time'
    )::integer
  into
    v_original_outcome_count,
    v_correction_outcome_count
  from public.trust_outcome_events as e
  where e.id in (
    v_late_outcome_id,
    v_correction_outcome_id
  );

  select count(*)::integer
  into v_original_penalty_count
  from public.score_v2_contributions as c
  where c.outcome_event_id = v_late_outcome_id
    and c.model_version = 'v2.2-shadow'
    and c.contribution_type = 'payment_late_penalty'
    and c.points_awarded = 3;

  select
    count(*) filter (
      where c.contribution_type = 'payment_late_penalty'
    )::integer,
    coalesce(sum(c.signed_points), 0)::integer
  into
    v_effective_penalty_count,
    v_effective_signed_total
  from public.score_v22_effective_contributions as c
  where c.score_agreement_id = v_score_agreement_id;

  if v_original_outcome_count <> 1
     or v_correction_outcome_count <> 1
     or v_original_penalty_count <> 1
     or v_effective_penalty_count <> 0
     or v_effective_signed_total <> 0 then
    raise exception
      'Append-only/effective correction mismatch: original_outcome=%, correction_outcome=%, original_penalty=%, effective_penalties=%, effective_total=%',
      v_original_outcome_count,
      v_correction_outcome_count,
      v_original_penalty_count,
      v_effective_penalty_count,
      v_effective_signed_total;
  end if;

  -- Original and corrected payment outcomes are immutable.
  v_mutation_blocked := false;
  begin
    update public.trust_outcome_events
    set metadata = metadata || '{"illegal_mutation":true}'::jsonb
    where id = v_late_outcome_id;
  exception
    when others then
      v_mutation_blocked := true;
  end;

  v_delete_blocked := false;
  begin
    delete from public.trust_outcome_events
    where id = v_correction_outcome_id;
  exception
    when others then
      v_delete_blocked := true;
  end;

  if not v_mutation_blocked or not v_delete_blocked then
    raise exception
      'Payment outcome immutability was not enforced';
  end if;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_after_correction :=
    public.get_my_iou_score_v22_progress(v_iou_id);

  if (v_after_correction ->> 'paid_cents')::bigint <> 25000
     or (
       v_after_correction
       ->> 'completion_progress_points'
     )::integer <> 14
     or (v_after_correction ->> 'active_penalties')::integer <> 0
     or (
       v_after_correction
       ->> 'current_public_score_effect'
     )::integer <> 0
     or (
       v_after_correction
       ->> 'projected_completed_contribution'
     )::integer <> 14
     or (
       v_after_correction
       ->> 'positive_points_unlocked'
     )::boolean then
    raise exception
      'Corrected pre-completion progress mismatch: %',
      v_after_correction;
  end if;

  raise notice
    'PASS 2: original evidence remains, but superseded -3 penalty is no longer effective';

  -- --------------------------------------------------------------------------
  -- Complete the IOU on time. Final net must be the full +28 base reward.
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

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_after_completion :=
    public.get_my_iou_score_v22_progress(v_iou_id);

  if (v_after_completion ->> 'paid_cents')::bigint <> 50000
     or (
       v_after_completion
       ->> 'completion_progress_points'
     )::integer <> 28
     or (
       v_after_completion
       ->> 'completion_reward_max'
     )::integer <> 28
     or (v_after_completion ->> 'early_bonus_earned')::integer <> 0
     or (v_after_completion ->> 'active_penalties')::integer <> 0
     or (
       v_after_completion
       ->> 'current_public_score_effect'
     )::integer <> 28
     or not (
       v_after_completion
       ->> 'positive_points_unlocked'
     )::boolean then
    raise exception
      'Corrected completed progress mismatch: %',
      v_after_completion;
  end if;

  -- Recalculate twice; effective score and app payload must not drift.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );

  perform public.recalculate_score_v2_agreement(
    v_score_agreement_id,
    'v2.2-shadow'
  );
  perform public.recalculate_score_v2_agreement(
    v_score_agreement_id,
    'v2.2-shadow'
  );

  select count(*)::integer
  into v_total_contribution_rows
  from public.score_v2_contributions as c
  where c.score_agreement_id = v_score_agreement_id
    and c.model_version = 'v2.2-shadow';

  select coalesce(sum(c.signed_points), 0)::integer
  into v_effective_signed_total
  from public.score_v22_effective_contributions as c
  where c.score_agreement_id = v_score_agreement_id;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_after_recalc :=
    public.get_my_iou_score_v22_progress(v_iou_id);

  if v_total_contribution_rows <> 2
     or v_effective_signed_total <> 28
     or v_after_recalc is distinct from v_after_completion then
    raise exception
      'Correction recalculation drift: total_rows=%, effective_total=%, before=%, after=%',
      v_total_contribution_rows,
      v_effective_signed_total,
      v_after_completion,
      v_after_recalc;
  end if;

  -- Snapshot must use corrected effective truth, not lifetime raw history.
  v_snapshot_id :=
    public.create_trust_score_snapshot(
      v_borrower_id,
      'v22_correction_regression'
    );

  select
    s.model_version,
    s.score_contributed_total,
    s.v2_shadow_score
  into v_snapshot
  from public.trust_score_snapshots as s
  where s.id = v_snapshot_id;

  if v_snapshot.model_version <> 'v2.2-shadow'
     or v_snapshot.score_contributed_total <> 28
     or v_snapshot.v2_shadow_score <> 728 then
    raise exception
      'Corrected snapshot mismatch: model=%, contributed=%, score=%',
      v_snapshot.model_version,
      v_snapshot.score_contributed_total,
      v_snapshot.v2_shadow_score;
  end if;

  raise notice
    'PASS 3: completion and snapshot use corrected effective truth (+28), with idempotent replay/recalculation';
end
$test$;

select jsonb_build_object(
  'suite', 'Score v2.2 append-only correction regression',
  'passed', true,
  'fixture', 'disposable transaction fixture',
  'original_outcome_preserved', true,
  'original_contribution_preserved', true,
  'superseded_penalty_effective', false,
  'corrected_precompletion_public_effect', 0,
  'corrected_completion_public_effect', 28,
  'snapshot_score', 728,
  'idempotent_replay', true,
  'idempotent_recalculation', true,
  'payment_outcomes_immutable', true,
  'cleanup', 'transaction_rollback'
) as score_v22_correction_regression_summary;

rollback;
