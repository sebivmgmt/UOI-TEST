-- ============================================================================
-- Score v2.2 correction audit/read security regression
--
-- Disposable scenario:
--   1. A first-pair $500 IOU records a one-day-late $250 payment.
--   2. Trusted backend corrects the immutable outcome from late to on-time.
--   3. Support audit receives full internal evidence.
--   4. Borrower receives only a curated correction notice.
--   5. Anonymous and non-subject callers are denied.
--
-- Entire test rolls back.
-- ============================================================================

begin;

do $tests$
declare
  v_run_id text :=
    'v22_correction_audit_' ||
    substring(replace(gen_random_uuid()::text, '-', ''), 1, 10);

  v_lender_id uuid := gen_random_uuid();
  v_borrower_id uuid := gen_random_uuid();
  v_iou_id uuid := gen_random_uuid();
  v_payment_id uuid := gen_random_uuid();
  v_second_payment_id uuid := gen_random_uuid();
  v_score_agreement_id uuid;
  v_late_outcome_id uuid;
  v_correction_outcome_id uuid;

  v_secret_reason text :=
    'INTERNAL SUPPORT NOTE: verified bank settlement timestamp';
  v_secret_key text;
  v_support jsonb;
  v_borrower jsonb;
  v_progress jsonb;
  v_denied boolean;
  v_count integer;
begin
  v_secret_key := v_run_id || ':payment-1:on-time';

  -- Security grants remain fail-closed.
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
      'Correction audit regression: internal/support audit has % app-role grants',
      v_count;
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
      'Correction audit regression: correction writer is exposed to app roles';
  end if;

  -- Disposable identities.
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
      '{"full_name":"Correction Audit Lender"}'::jsonb,
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
      '{"full_name":"Correction Audit Borrower"}'::jsonb,
      false
    );

  update public.profiles
  set
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

  -- Two-installment schedule. Only installment 1 is paid in this test,
  -- so correction of its late classification must not unlock completion.
  insert into public.payments (
    id,
    iou_id,
    due_date,
    amount_cents
  )
  values
    (
      v_payment_id,
      v_iou_id,
      current_date - 1,
      25000
    ),
    (
      v_second_payment_id,
      v_iou_id,
      current_date + 30,
      25000
    );

  select sa.id
  into strict v_score_agreement_id
  from public.score_agreements as sa
  where sa.source_type = 'personal_iou'
    and sa.source_id = v_iou_id
    and sa.user_id = v_borrower_id;

  -- Borrower claims, lender confirms: create immutable one-day-late outcome.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  perform public.claim_payment(v_payment_id, v_borrower_id);

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_lender_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  perform public.pay_and_receipt(v_payment_id);

  select e.id
  into strict v_late_outcome_id
  from public.trust_outcome_events as e
  where e.score_agreement_id = v_score_agreement_id
    and e.outcome_type = 'payment_paid_late'
    and public.score_v22_event_payment_id(to_jsonb(e)) = v_payment_id;

  -- Trusted backend records the correction.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );

  v_correction_outcome_id :=
    (
      public.record_score_v22_payment_outcome_correction(
        v_late_outcome_id,
        'payment_paid_on_time',
        v_secret_reason,
        v_secret_key,
        null,
        null,
        jsonb_build_object(
          'support_ticket', 'SUP-TEST-123',
          'verification_source', 'bank_settlement'
        )
      )
      ->> 'correction_outcome_event_id'
    )::uuid;

  -- Full support/backend audit contains internal evidence.
  v_support :=
    public.get_score_v22_iou_correction_audit(v_iou_id);

  if (v_support ->> 'score_agreement_id')::uuid
       <> v_score_agreement_id
     or (v_support ->> 'correction_count')::integer <> 1
     or not (v_support ->> 'has_corrections')::boolean
     or (
       v_support
       -> 'corrections'
       -> 0
       ->> 'original_outcome_event_id'
     )::uuid <> v_late_outcome_id
     or (
       v_support
       -> 'corrections'
       -> 0
       ->> 'correction_outcome_event_id'
     )::uuid <> v_correction_outcome_id
     or (
       v_support
       -> 'corrections'
       -> 0
       ->> 'correction_reason'
     ) <> v_secret_reason
     or (
       v_support
       -> 'corrections'
       -> 0
       ->> 'correction_key'
     ) <> v_secret_key
     or (
       v_support
       -> 'corrections'
       -> 0
       ->> 'previous_signed_points'
     )::integer <> -3
     or (
       v_support
       -> 'corrections'
       -> 0
       ->> 'corrected_signed_points'
     )::integer <> 0
     or (
       v_support
       -> 'corrections'
       -> 0
       ->> 'net_score_effect_change'
     )::integer <> 3
  then
    raise exception
      'Correction audit regression: support payload mismatch: %',
      v_support;
  end if;

  -- App-role claims cannot call the full support audit even under a postgres
  -- test session because the function also validates caller claims.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_score_v22_iou_correction_audit(v_iou_id);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'Correction audit regression: authenticated caller reached support audit';
  end if;

  -- Anonymous borrower-history access is denied.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'anon')::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_correction_history(v_iou_id);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'Correction audit regression: anonymous caller reached borrower history';
  end if;

  -- Lender is not the score subject and must be denied.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_lender_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_correction_history(v_iou_id);
  exception
    when insufficient_privilege then
      v_denied := true;
  end;

  if not v_denied then
    raise exception
      'Correction audit regression: non-subject lender reached borrower history';
  end if;

  -- Unknown IOU uses the same generic denial.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_denied := false;
  begin
    perform public.get_my_iou_score_v22_correction_history(
      gen_random_uuid()
    );
  exception
    when insufficient_privilege then
      if sqlerrm = 'IOU correction history not found or not accessible' then
        v_denied := true;
      else
        raise;
      end if;
  end;

  if not v_denied then
    raise exception
      'Correction audit regression: unknown IOU was not generically denied';
  end if;

  -- Borrower receives only curated history.
  v_borrower :=
    public.get_my_iou_score_v22_correction_history(v_iou_id);

  if (v_borrower ->> 'iou_id')::uuid <> v_iou_id
     or (v_borrower ->> 'model_version') <> 'v2.2-shadow'
     or (v_borrower ->> 'correction_count')::integer <> 1
     or not (v_borrower ->> 'has_corrections')::boolean
     or (
       v_borrower
       -> 'corrections'
       -> 0
       ->> 'payment_id'
     )::uuid <> v_payment_id
     or (
       v_borrower
       -> 'corrections'
       -> 0
       ->> 'previous_outcome'
     ) <> 'late'
     or (
       v_borrower
       -> 'corrections'
       -> 0
       ->> 'corrected_outcome'
     ) <> 'on_time'
     or (
       v_borrower
       -> 'corrections'
       -> 0
       ->> 'notice'
     ) <> 'Payment outcome corrected after review'
  then
    raise exception
      'Correction audit regression: borrower payload mismatch: %',
      v_borrower;
  end if;

  if v_borrower::text like '%' || v_secret_reason || '%'
     or v_borrower::text like '%' || v_secret_key || '%'
     or (
       v_borrower
       -> 'corrections'
       -> 0
     ) ?| array[
       'original_outcome_event_id',
       'correction_outcome_event_id',
       'correction_reason',
       'correction_key',
       'request_metadata',
       'previous_signed_points',
       'corrected_signed_points',
       'net_score_effect_change'
     ] then
    raise exception
      'Correction audit regression: borrower payload leaked internal evidence: %',
      v_borrower;
  end if;

  -- Corrected public progress remains consistent with the correction layer.
  v_progress := public.get_my_iou_score_v22_progress(v_iou_id);

  if (v_progress ->> 'paid_cents')::bigint <> 25000
     or (v_progress ->> 'active_penalties')::integer <> 0
     or (v_progress ->> 'current_public_score_effect')::integer <> 0
     or (v_progress ->> 'agreement_completed')::boolean
     or (v_progress ->> 'positive_points_unlocked')::boolean then
    raise exception
      'Correction audit regression: corrected progress mismatch: %',
      v_progress;
  end if;
end
$tests$;

select jsonb_build_object(
  'suite', 'Score v2.2 correction audit/read security',
  'passed', true,
  'cleanup', 'transaction_rollback',
  'support_full_audit', true,
  'borrower_curated_history', true,
  'anonymous_denied', true,
  'non_subject_denied', true,
  'unknown_iou_generically_denied', true,
  'internal_reason_not_leaked', true,
  'correction_writer_still_private', true,
  'corrected_progress_consistent', true
) as score_v22_correction_audit_security_summary;

rollback;
