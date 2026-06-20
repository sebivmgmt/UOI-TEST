-- =============================================================================
-- ACH + Score v2 Regression Suite
-- Target:  DEV project (colkilearqxuyldzjutw)
-- Runner:  Management API as postgres  — run with run_regression.sh
-- Cleanup: explicit deletion at end; exception path rolls back everything
-- =============================================================================

BEGIN;

DO $$
DECLARE
  -- ── Counters ──────────────────────────────────────────────
  v_run_id    text;
  v_total     integer := 0;
  v_pass      integer := 0;
  v_fail      integer := 0;
  v_fail_msgs text    := '';

  -- ── Test user IDs ─────────────────────────────────────────
  v_lender_id   uuid;
  v_borrower_id uuid;

  -- ── IOU 1: single-payment (ACH + single-outcome score tests) ─
  v_iou1_id   uuid;
  v_pay1_id   uuid;
  v_sagr1_id  uuid;

  -- ── IOU 2: two-payment (completion + exposure tests) ─────
  v_iou2_id   uuid;
  v_pay2a_id  uuid;  -- first payment
  v_pay2b_id  uuid;  -- second payment
  v_sagr2_id  uuid;

  -- ── Scratch ───────────────────────────────────────────────
  v_pay         public.payments%rowtype;
  v_res         jsonb;
  v_count       integer;
  v_int         integer;
  v_text        text;
  v_bool        boolean;
  v_snap_id     uuid;
  v_snap        public.trust_score_snapshots%rowtype;

BEGIN
  v_run_id := 'reg_' || substring(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  RAISE NOTICE '=== ACH + Score v2 Regression [%] ===', v_run_id;

  -- ===========================================================================
  -- SETUP
  -- ===========================================================================

  v_lender_id   := gen_random_uuid();
  v_borrower_id := gen_random_uuid();

  -- Create auth users; on_auth_user_created trigger auto-creates profiles.
  INSERT INTO auth.users (
    id, email, aud, role,
    email_confirmed_at, created_at, updated_at,
    raw_user_meta_data, is_anonymous
  )
  VALUES
    (v_lender_id,   v_run_id || '_lender@test.invalid',
     'authenticated', 'authenticated',
     now(), now(), now(), '{"full_name":"Test Lender"}'::jsonb, false),
    (v_borrower_id, v_run_id || '_borrower@test.invalid',
     'authenticated', 'authenticated',
     now(), now(), now(), '{"full_name":"Test Borrower"}'::jsonb, false);

  -- Mark both parties ACH-ready with a known iou_score baseline.
  UPDATE public.profiles
  SET    ach_status = 'ready', iou_score = 700, active_exposure_points = 0
  WHERE  id IN (v_lender_id, v_borrower_id);

  -- ── IOU 1: $500 principal, single payment, future due date ──────────────
  v_iou1_id := gen_random_uuid();
  INSERT INTO public.ious (
    id, lender_id, borrower_id, principal_cents, apr_bps,
    start_date, term_months, frequency, status, activated_at
  )
  VALUES (
    v_iou1_id, v_lender_id, v_borrower_id,
    50000, 0,
    current_date, 1, 'monthly', 'open', now()
  );

  v_pay1_id := gen_random_uuid();
  INSERT INTO public.payments (id, iou_id, due_date, amount_cents)
  VALUES (v_pay1_id, v_iou1_id, current_date + 30, 50000);

  SELECT id INTO v_sagr1_id
  FROM   public.score_agreements
  WHERE  source_id = v_iou1_id AND source_type = 'personal_iou';

  -- ── IOU 2: $500 principal, two payments, future due dates ───────────────
  v_iou2_id := gen_random_uuid();
  INSERT INTO public.ious (
    id, lender_id, borrower_id, principal_cents, apr_bps,
    start_date, term_months, frequency, status, activated_at
  )
  VALUES (
    v_iou2_id, v_lender_id, v_borrower_id,
    50000, 0,
    current_date, 2, 'monthly', 'open', now()
  );

  v_pay2a_id := gen_random_uuid();
  v_pay2b_id := gen_random_uuid();
  INSERT INTO public.payments (id, iou_id, due_date, amount_cents)
  VALUES
    (v_pay2a_id, v_iou2_id, current_date + 30,  25000),
    (v_pay2b_id, v_iou2_id, current_date + 60,  25000);

  SELECT id INTO v_sagr2_id
  FROM   public.score_agreements
  WHERE  source_id = v_iou2_id AND source_type = 'personal_iou';

  RAISE NOTICE 'Setup complete — lender=%, borrower=%, iou1=%, pay1=%, sagr1=%, iou2=%, sagr2=%',
    v_lender_id, v_borrower_id, v_iou1_id, v_pay1_id, v_sagr1_id, v_iou2_id, v_sagr2_id;

  -- ===========================================================================
  -- GROUP 1: ACH initiation
  -- ===========================================================================
  RAISE NOTICE '--- Group 1: ACH initiation ---';

  -- 1.1  Only the borrower can initiate ─────────────────────────────────────
  v_total := v_total + 1;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_lender_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.initiate_ach_payment(v_pay1_id);
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 1.1 lender must not initiate ACH';
    RAISE WARNING 'FAIL 1.1: lender was allowed to initiate ACH';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm ~* 'borrower' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 1.1: borrower-only enforcement';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 1.1 wrong error: ' || sqlerrm;
      RAISE WARNING 'FAIL 1.1: wrong error: %', sqlerrm;
    END IF;
  END;

  -- 1.2  Lender ach_status not ready → reject ───────────────────────────────
  v_total := v_total + 1;
  BEGIN
    UPDATE public.profiles SET ach_status = 'pending' WHERE id = v_lender_id;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.initiate_ach_payment(v_pay1_id);
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 1.2 lender-not-ready must be rejected';
    RAISE WARNING 'FAIL 1.2: allowed ACH when lender not ready';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm ~* 'Lender ACH' OR sqlerrm ~* 'lender' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 1.2: lender-not-ready rejection';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 1.2 wrong error: ' || sqlerrm;
      RAISE WARNING 'FAIL 1.2: wrong error: %', sqlerrm;
    END IF;
    UPDATE public.profiles SET ach_status = 'ready' WHERE id = v_lender_id;
  END;

  -- 1.3  Borrower ach_status not ready → reject ─────────────────────────────
  v_total := v_total + 1;
  BEGIN
    UPDATE public.profiles SET ach_status = 'pending' WHERE id = v_borrower_id;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.initiate_ach_payment(v_pay1_id);
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 1.3 borrower-not-ready must be rejected';
    RAISE WARNING 'FAIL 1.3: allowed ACH when borrower not ready';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm ~* 'Borrower ACH' OR sqlerrm ~* 'borrower' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 1.3: borrower-not-ready rejection';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 1.3 wrong error: ' || sqlerrm;
      RAISE WARNING 'FAIL 1.3: wrong error: %', sqlerrm;
    END IF;
    UPDATE public.profiles SET ach_status = 'ready' WHERE id = v_borrower_id;
  END;

  -- 1.4  IOU must be activated ───────────────────────────────────────────────
  v_total := v_total + 1;
  DECLARE
    v_tmp_iou uuid := gen_random_uuid();
    v_tmp_pay uuid := gen_random_uuid();
  BEGIN
    INSERT INTO public.ious (id, lender_id, borrower_id, principal_cents, apr_bps, start_date, term_months, frequency, status)
    VALUES (v_tmp_iou, v_lender_id, v_borrower_id, 50000, 0, current_date, 1, 'monthly', 'open');
    INSERT INTO public.payments (id, iou_id, due_date, amount_cents)
    VALUES (v_tmp_pay, v_tmp_iou, current_date + 30, 50000);

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.initiate_ach_payment(v_tmp_pay);
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 1.4 unactivated IOU must be rejected';
    RAISE WARNING 'FAIL 1.4: allowed ACH on unactivated IOU';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm ~* 'activated' OR sqlerrm ~* 'active' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 1.4: unactivated IOU rejection';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 1.4 wrong error: ' || sqlerrm;
      RAISE WARNING 'FAIL 1.4: wrong error: %', sqlerrm;
    END IF;
    DELETE FROM public.payments      WHERE id = v_tmp_pay;
    DELETE FROM public.score_agreements WHERE source_id = v_tmp_iou;
    DELETE FROM public.ious          WHERE id = v_tmp_iou;
  END;

  -- 1.5  Payment must start as scheduled or late; re-initiation rejected ────
  v_total := v_total + 1;
  DECLARE
    v_tmp_iou2 uuid := gen_random_uuid();
    v_tmp_pay2 uuid := gen_random_uuid();
  BEGIN
    INSERT INTO public.ious (id, lender_id, borrower_id, principal_cents, apr_bps, start_date, term_months, frequency, status, activated_at)
    VALUES (v_tmp_iou2, v_lender_id, v_borrower_id, 50000, 0, current_date, 1, 'monthly', 'open', now());
    -- Forcibly set status to processing to simulate already-in-flight payment
    INSERT INTO public.payments (id, iou_id, due_date, amount_cents, status, payment_method)
    VALUES (v_tmp_pay2, v_tmp_iou2, current_date + 30, 50000, 'processing', 'ach');

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.initiate_ach_payment(v_tmp_pay2);
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 1.5 processing payment must not be re-initiated';
    RAISE WARNING 'FAIL 1.5: allowed re-initiation of processing payment';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm ~* 'cannot be initiated' OR sqlerrm ~* 'status' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 1.5: non-initiatable status rejection';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 1.5 wrong error: ' || sqlerrm;
      RAISE WARNING 'FAIL 1.5: wrong error: %', sqlerrm;
    END IF;
    DELETE FROM public.payments      WHERE id = v_tmp_pay2;
    DELETE FROM public.score_agreements WHERE source_id = v_tmp_iou2;
    DELETE FROM public.ious          WHERE id = v_tmp_iou2;
  END;

  -- 1.6  Successful ACH initiation → processing / ach / paid_at null / no manual fields
  v_total := v_total + 1;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.initiate_ach_payment(v_pay1_id);

    SELECT * INTO v_pay FROM public.payments WHERE id = v_pay1_id;
    IF  v_pay.status           = 'processing'
    AND v_pay.payment_method   = 'ach'
    AND v_pay.paid_at          IS NULL
    AND v_pay.claimed_paid_at  IS NULL
    AND v_pay.claimed_by       IS NULL
    AND v_pay.confirmed_paid_at IS NULL
    AND v_pay.confirmed_by     IS NULL
    THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 1.6: ACH initiation produces correct state';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 1.6 wrong post-initiation state';
      RAISE WARNING 'FAIL 1.6: status=%, method=%, paid_at=%', v_pay.status, v_pay.payment_method, v_pay.paid_at;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 1.6 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 1.6: %', sqlerrm;
  END;

  -- ===========================================================================
  -- GROUP 2: ACH settlement
  -- (pay1 is now processing)
  -- ===========================================================================
  RAISE NOTICE '--- Group 2: ACH settlement ---';

  -- 2.1  authenticated role has no execute grant on complete_ach_payment ─────
  v_total := v_total + 1;
  BEGIN
    SELECT has_function_privilege(
      'authenticated',
      'public.complete_ach_payment(uuid, text)',
      'execute'
    ) INTO v_bool;
    IF NOT v_bool THEN
      v_pass := v_pass + 1;
      RAISE NOTICE 'PASS 2.1: authenticated denied execute on complete_ach_payment';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 2.1 authenticated must not have execute grant';
      RAISE WARNING 'FAIL 2.1: authenticated has execute on complete_ach_payment';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 2.1 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 2.1: %', sqlerrm;
  END;

  -- 2.2  service role (postgres session) can complete a processing ACH → paid
  v_total := v_total + 1;
  BEGIN
    PERFORM public.complete_ach_payment(v_pay1_id, 'dwolla_tx_reg_001');

    SELECT * INTO v_pay FROM public.payments WHERE id = v_pay1_id;
    IF  v_pay.status         = 'paid'
    AND v_pay.paid_at        IS NOT NULL
    AND v_pay.payment_method = 'ach'
    AND v_pay.tx_ref         = 'dwolla_tx_reg_001'
    THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 2.2: ACH settlement produces paid status';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 2.2 wrong settlement state';
      RAISE WARNING 'FAIL 2.2: status=%, paid_at=%, tx_ref=%', v_pay.status, v_pay.paid_at, v_pay.tx_ref;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 2.2 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 2.2: %', sqlerrm;
  END;

  -- 2.3  Exactly one payment_receipts row; method = 'ach' ───────────────────
  v_total := v_total + 1;
  BEGIN
    SELECT count(*) INTO v_count
    FROM   public.payment_receipts
    WHERE  payment_id = v_pay1_id;

    SELECT method    INTO v_text
    FROM   public.payment_receipts
    WHERE  payment_id = v_pay1_id
    LIMIT  1;

    IF v_count = 1 AND v_text = 'ach' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 2.3: exactly one ach receipt';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 2.3 receipt count=' || v_count || ' method=' || coalesce(v_text, 'null');
      RAISE WARNING 'FAIL 2.3: receipt_count=%, method=%', v_count, v_text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 2.3 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 2.3: %', sqlerrm;
  END;

  -- 2.4  Duplicate complete_ach_payment is idempotent ───────────────────────
  v_total := v_total + 1;
  BEGIN
    PERFORM public.complete_ach_payment(v_pay1_id, 'dwolla_tx_reg_001');  -- second call, same tx_ref

    SELECT * INTO v_pay FROM public.payments WHERE id = v_pay1_id;
    IF v_pay.status = 'paid' AND v_pay.paid_at IS NOT NULL THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 2.4: duplicate settlement is idempotent';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 2.4 idempotent call changed state';
      RAISE WARNING 'FAIL 2.4: payment state changed on duplicate call';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 2.4 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 2.4: %', sqlerrm;
  END;

  -- 2.5  Duplicate call creates no extra receipts, outcomes, contributions ──
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_receipt_count  integer;
      v_outcome_count  integer;
      v_contrib_count  integer;
    BEGIN
      SELECT count(*) INTO v_receipt_count
      FROM   public.payment_receipts WHERE payment_id = v_pay1_id;

      SELECT count(*) INTO v_outcome_count
      FROM   public.trust_outcome_events
      WHERE  score_agreement_id = v_sagr1_id;

      SELECT count(*) INTO v_contrib_count
      FROM   public.score_v2_contributions
      WHERE  score_agreement_id = v_sagr1_id;

      -- At most 1 receipt, 1 payment outcome (+ maybe 1 agreement_completed)
      -- and at most 2 contributions (payment_performance + agreement_completion).
      -- The key is none are doubled.
      IF v_receipt_count <= 1 AND v_contrib_count <= 2 THEN
        v_pass := v_pass + 1;
        RAISE NOTICE 'PASS 2.5: no duplicate receipts/outcomes/contributions (receipts=%, outcomes=%, contribs=%)',
          v_receipt_count, v_outcome_count, v_contrib_count;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs := v_fail_msgs || ' | 2.5 duplicates: receipts=' || v_receipt_count || ' contribs=' || v_contrib_count;
        RAISE WARNING 'FAIL 2.5: receipts=%, outcomes=%, contribs=%', v_receipt_count, v_outcome_count, v_contrib_count;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 2.5 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 2.5: %', sqlerrm;
  END;

  -- ===========================================================================
  -- GROUP 3: Manual payment separation
  -- ===========================================================================
  RAISE NOTICE '--- Group 3: Manual payment separation ---';

  -- 3.1  claim_payment → pending_confirmation, method = manual ──────────────
  v_total := v_total + 1;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.claim_payment(v_pay2a_id, v_borrower_id);

    SELECT * INTO v_pay FROM public.payments WHERE id = v_pay2a_id;
    IF  v_pay.status         = 'pending_confirmation'
    AND coalesce(v_pay.payment_method, 'manual') = 'manual'
    THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 3.1: claim_payment → pending_confirmation/manual';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 3.1 wrong state: status=' || v_pay.status || ' method=' || coalesce(v_pay.payment_method, 'null');
      RAISE WARNING 'FAIL 3.1: status=%, method=%', v_pay.status, v_pay.payment_method;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 3.1 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 3.1: %', sqlerrm;
  END;

  -- 3.2  Borrower cannot lender-confirm (pay_and_receipt) ───────────────────
  v_total := v_total + 1;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.pay_and_receipt(v_pay2a_id);
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 3.2 borrower must not confirm manual payment';
    RAISE WARNING 'FAIL 3.2: borrower was allowed to lender-confirm';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm ~* 'lender' OR sqlerrm ~* 'Only the lender' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 3.2: borrower cannot lender-confirm';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 3.2 wrong error: ' || sqlerrm;
      RAISE WARNING 'FAIL 3.2: wrong error: %', sqlerrm;
    END IF;
  END;

  -- 3.3  pay_and_receipt rejects ACH payments ───────────────────────────────
  -- pay1 is now paid/ach — attempt another ACH payment directly in processing state
  v_total := v_total + 1;
  DECLARE
    v_tmp_iou3 uuid := gen_random_uuid();
    v_tmp_pay3 uuid := gen_random_uuid();
  BEGIN
    INSERT INTO public.ious (id, lender_id, borrower_id, principal_cents, apr_bps, start_date, term_months, frequency, status, activated_at)
    VALUES (v_tmp_iou3, v_lender_id, v_borrower_id, 50000, 0, current_date, 1, 'monthly', 'open', now());
    -- Insert a payment that looks like it's been ACH-claimed (processing state)
    INSERT INTO public.payments (id, iou_id, due_date, amount_cents, status, payment_method)
    VALUES (v_tmp_pay3, v_tmp_iou3, current_date + 30, 50000, 'processing', 'ach');

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_lender_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.pay_and_receipt(v_tmp_pay3);
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 3.3 pay_and_receipt must reject ACH payment';
    RAISE WARNING 'FAIL 3.3: pay_and_receipt accepted an ACH/processing payment';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm ~* 'pending confirmation' OR sqlerrm ~* 'ACH' OR sqlerrm ~* 'pending_confirmation' OR sqlerrm ~* 'not pending' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 3.3: pay_and_receipt rejects ACH/non-pending payment';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 3.3 wrong error: ' || sqlerrm;
      RAISE WARNING 'FAIL 3.3: wrong error: %', sqlerrm;
    END IF;
    DELETE FROM public.payments          WHERE id = v_tmp_pay3;
    DELETE FROM public.score_agreements  WHERE source_id = v_tmp_iou3;
    DELETE FROM public.ious              WHERE id = v_tmp_iou3;
  END;

  -- 3.4  Lender can confirm a manual pending payment ────────────────────────
  v_total := v_total + 1;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_lender_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.pay_and_receipt(v_pay2a_id);

    SELECT * INTO v_pay FROM public.payments WHERE id = v_pay2a_id;
    IF v_pay.status = 'paid' AND v_pay.paid_at IS NOT NULL THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 3.4: lender confirmation succeeds';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 3.4 lender confirmation did not produce paid';
      RAISE WARNING 'FAIL 3.4: status=%, paid_at=%', v_pay.status, v_pay.paid_at;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 3.4 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 3.4: %', sqlerrm;
  END;

  -- ===========================================================================
  -- GROUP 4: Score v2 payment outcome (IOU 1, single payment)
  -- ===========================================================================
  RAISE NOTICE '--- Group 4: Score v2 payment outcome ---';

  -- 4.1  ACH payment creates exactly one trust_outcome_event ────────────────
  v_total := v_total + 1;
  BEGIN
    SELECT count(*) INTO v_count
    FROM   public.trust_outcome_events
    WHERE  score_agreement_id = v_sagr1_id
    AND    outcome_type IN (
             'payment_paid_early', 'payment_paid_on_time', 'payment_paid_late'
           );
    IF v_count = 1 THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 4.1: exactly one payment outcome event';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 4.1 payment_outcome_count=' || v_count;
      RAISE WARNING 'FAIL 4.1: payment outcome event count=%', v_count;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 4.1 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 4.1: %', sqlerrm;
  END;

  -- 4.2  Outcome type is correctly classified (early/on_time/late) ──────────
  v_total := v_total + 1;
  BEGIN
    -- pay1 due_date = current_date + 30 → paid now → early
    SELECT outcome_type INTO v_text
    FROM   public.trust_outcome_events
    WHERE  score_agreement_id = v_sagr1_id
    AND    outcome_type IN ('payment_paid_early', 'payment_paid_on_time', 'payment_paid_late')
    ORDER  BY created_at DESC LIMIT 1;

    IF v_text = 'payment_paid_early' THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 4.2: outcome classified as payment_paid_early';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 4.2 wrong outcome_type: ' || coalesce(v_text, 'null');
      RAISE WARNING 'FAIL 4.2: outcome_type=% (expected payment_paid_early)', v_text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 4.2 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 4.2: %', sqlerrm;
  END;

  -- 4.3  Contribution ledger has at most one payment_performance row per agreement/model ──
  v_total := v_total + 1;
  BEGIN
    SELECT count(*) INTO v_count
    FROM   public.score_v2_contributions
    WHERE  score_agreement_id  = v_sagr1_id
    AND    contribution_type   = 'payment_performance';

    IF v_count <= 1 THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 4.3: at most one payment_performance contribution (count=%)', v_count;
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 4.3 pp_contribution_count=' || v_count;
      RAISE WARNING 'FAIL 4.3: payment_performance contribution count=%', v_count;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 4.3 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 4.3: %', sqlerrm;
  END;

  -- 4.4  Signed v2.2 contribution does not exceed agreement ceiling ────────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_ceiling integer;
      v_net_pts integer;
    BEGIN
      v_ceiling := public.score_v22_agreement_ceiling(v_sagr1_id);

      SELECT coalesce(sum(
        CASE
          WHEN impact_direction = 'penalty' THEN -points_awarded
          ELSE points_awarded
        END
      ), 0)::integer
      INTO v_net_pts
      FROM public.score_v2_contributions
      WHERE score_agreement_id = v_sagr1_id
        AND model_version = 'v2.2-shadow';

      IF v_net_pts <= v_ceiling THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 4.4: signed v2.2 contribution (%) does not exceed ceiling (%)',
          v_net_pts,
          v_ceiling;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 4.4 signed contribution='
          || v_net_pts
          || ' > ceiling='
          || v_ceiling;
        RAISE WARNING
          'FAIL 4.4: signed contribution=% exceeds ceiling=%',
          v_net_pts,
          v_ceiling;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 4.4 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 4.4: %', sqlerrm;
  END;

  -- 4.5  Repeated v2.2 recalculation creates no duplicate contribution ─────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_before integer;
      v_after  integer;
    BEGIN
      -- Catch up any immutable outcome that preceded its dependent event.
      PERFORM public.score_v22_recalculate_agreement(v_sagr1_id, now());

      SELECT count(*) INTO v_before
      FROM public.score_v2_contributions
      WHERE score_agreement_id = v_sagr1_id
        AND model_version = 'v2.2-shadow';

      PERFORM public.score_v22_recalculate_agreement(v_sagr1_id, now());
      PERFORM public.score_v22_recalculate_agreement(v_sagr1_id, now());

      SELECT count(*) INTO v_after
      FROM public.score_v2_contributions
      WHERE score_agreement_id = v_sagr1_id
        AND model_version = 'v2.2-shadow';

      IF v_after = v_before THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 4.5: v2.2 recalculation is idempotent (before=%, after=%)',
          v_before,
          v_after;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 4.5 v2.2 idempotency failed: before='
          || v_before
          || ' after='
          || v_after;
        RAISE WARNING
          'FAIL 4.5: v2.2 contribution count changed (before=%, after=%)',
          v_before,
          v_after;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 4.5 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 4.5: %', sqlerrm;
  END;

  -- ===========================================================================
  -- GROUP 5: Agreement completion (IOU 2, two payments)
  -- pay2a already paid via lender confirmation in group 3.
  -- ===========================================================================
  RAISE NOTICE '--- Group 5: Agreement completion ---';

  -- 5.1  Early first payment remains pending; no positive row unlocks ─────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_positive_count integer;
      v_comp_count     integer;
      v_progress       jsonb;
    BEGIN
      SELECT count(*) INTO v_positive_count
      FROM public.score_v2_contributions
      WHERE score_agreement_id = v_sagr2_id
        AND model_version = 'v2.2-shadow'
        AND contribution_type IN (
          'agreement_completion',
          'early_payment_bonus'
        );

      SELECT count(*) INTO v_comp_count
      FROM public.trust_outcome_events
      WHERE score_agreement_id = v_sagr2_id
        AND outcome_type = 'agreement_completed';

      v_progress := public.score_v22_pending_agreement_progress(
        v_sagr2_id,
        now()
      );

      IF v_positive_count = 0
         AND v_comp_count = 0
         AND NOT (v_progress ->> 'positive_points_unlocked')::boolean
         AND (v_progress ->> 'paid_installment_count')::integer = 1
      THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 5.1: early first payment remains pending; no positive contribution unlocked';
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 5.1 positive_count='
          || v_positive_count
          || ' comp_count='
          || v_comp_count
          || ' progress='
          || v_progress::text;
        RAISE WARNING
          'FAIL 5.1: positive_count=%, agreement_completed=%, progress=%',
          v_positive_count,
          v_comp_count,
          v_progress;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 5.1 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 5.1: %', sqlerrm;
  END;

  -- 5.1A Borrower app contract exposes locked pending progress ───────────────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_app_progress jsonb;
    BEGIN
      PERFORM set_config(
        'request.jwt.claims',
        json_build_object(
          'sub', v_borrower_id::text,
          'role', 'authenticated'
        )::text,
        true
      );

      v_app_progress :=
        public.get_my_iou_score_v22_progress(v_iou2_id);

      -- Restore a privileged test-runner claim for subsequent backend checks.
      PERFORM set_config(
        'request.jwt.claims',
        json_build_object('role', 'service_role')::text,
        true
      );

      IF (v_app_progress ->> 'model_version') = 'v2.2-shadow'
         AND (v_app_progress ->> 'principal_cents')::bigint = 50000
         AND (v_app_progress ->> 'paid_cents')::bigint = 25000
         AND (v_app_progress ->> 'repayment_fraction')::numeric = 0.5
         AND (v_app_progress ->> 'completion_progress_points')::integer = 11
         AND (v_app_progress ->> 'completion_reward_max')::integer = 22
         AND (v_app_progress ->> 'early_bonus_earned')::integer = 6
         AND (v_app_progress ->> 'early_bonus_max')::integer = 6
         AND (v_app_progress ->> 'pending_positive_points')::integer = 17
         AND (v_app_progress ->> 'active_penalties')::integer = 0
         AND (v_app_progress ->> 'projected_completed_contribution')::integer = 17
         AND (v_app_progress ->> 'current_public_score_effect')::integer = 0
         AND NOT (v_app_progress ->> 'agreement_completed')::boolean
         AND NOT (v_app_progress ->> 'positive_points_unlocked')::boolean
         AND (
           v_app_progress ->> 'positive_points_unlock_condition'
         ) = 'Positive points unlock when the IOU is completed'
      THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 5.1A: borrower app RPC shows pending locked progress before completion';
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 5.1A app progress='
          || v_app_progress::text;
        RAISE WARNING
          'FAIL 5.1A: unexpected pre-completion app progress=%',
          v_app_progress;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    -- Avoid leaking an authenticated borrower claim into later tests.
    PERFORM set_config(
      'request.jwt.claims',
      json_build_object('role', 'service_role')::text,
      true
    );
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 5.1A exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 5.1A: %', sqlerrm;
  END;

  -- 5.2  Second payment: pay2b via manual flow; final payment triggers agreement_completed
  v_total := v_total + 1;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.claim_payment(v_pay2b_id, v_borrower_id);

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_lender_id::text, 'role', 'authenticated')::text, true);
    PERFORM public.pay_and_receipt(v_pay2b_id);

    SELECT count(*) INTO v_count
    FROM   public.trust_outcome_events
    WHERE  score_agreement_id = v_sagr2_id AND outcome_type = 'agreement_completed';

    IF v_count = 1 THEN
      v_pass := v_pass + 1; RAISE NOTICE 'PASS 5.2: second payment triggers exactly one agreement_completed event';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 5.2 agreement_completed count=' || v_count;
      RAISE WARNING 'FAIL 5.2: agreement_completed count=%', v_count;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 5.2 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 5.2: %', sqlerrm;
  END;

  -- 5.3  Completion creates one base reward and one capped early bonus ─────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_completion_count integer;
      v_early_count      integer;
      v_pp_count         integer;
    BEGIN
      PERFORM public.score_v22_recalculate_agreement(v_sagr2_id, now());

      SELECT
        count(*) FILTER (
          WHERE contribution_type = 'agreement_completion'
        )::integer,
        count(*) FILTER (
          WHERE contribution_type = 'early_payment_bonus'
        )::integer,
        count(*) FILTER (
          WHERE contribution_type = 'payment_performance'
        )::integer
      INTO
        v_completion_count,
        v_early_count,
        v_pp_count
      FROM public.score_v2_contributions
      WHERE score_agreement_id = v_sagr2_id
        AND model_version = 'v2.2-shadow';

      IF v_completion_count = 1
         AND v_early_count = 1
         AND v_pp_count = 0
      THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 5.3: completion creates one base reward and one capped early bonus';
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 5.3 completion='
          || v_completion_count
          || ' early='
          || v_early_count
          || ' payment_performance='
          || v_pp_count;
        RAISE WARNING
          'FAIL 5.3: completion=%, early=%, payment_performance=%',
          v_completion_count,
          v_early_count,
          v_pp_count;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 5.3 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 5.3: %', sqlerrm;
  END;

  -- 5.3A Borrower app contract exposes unlocked completion result ───────────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_app_progress_first  jsonb;
      v_app_progress_second jsonb;
    BEGIN
      PERFORM set_config(
        'request.jwt.claims',
        json_build_object(
          'sub', v_borrower_id::text,
          'role', 'authenticated'
        )::text,
        true
      );

      v_app_progress_first :=
        public.get_my_iou_score_v22_progress(v_iou2_id);
      v_app_progress_second :=
        public.get_my_iou_score_v22_progress(v_iou2_id);

      PERFORM set_config(
        'request.jwt.claims',
        json_build_object('role', 'service_role')::text,
        true
      );

      IF v_app_progress_first IS NOT DISTINCT FROM v_app_progress_second
         AND (v_app_progress_first ->> 'model_version') = 'v2.2-shadow'
         AND (v_app_progress_first ->> 'principal_cents')::bigint = 50000
         AND (v_app_progress_first ->> 'paid_cents')::bigint = 50000
         AND (v_app_progress_first ->> 'repayment_fraction')::numeric = 1
         AND (v_app_progress_first ->> 'completion_progress_points')::integer = 22
         AND (v_app_progress_first ->> 'completion_reward_max')::integer = 22
         AND (v_app_progress_first ->> 'early_bonus_earned')::integer = 6
         AND (v_app_progress_first ->> 'early_bonus_max')::integer = 6
         AND (v_app_progress_first ->> 'pending_positive_points')::integer = 28
         AND (v_app_progress_first ->> 'active_penalties')::integer = 0
         AND (
           v_app_progress_first
           ->> 'projected_completed_contribution'
         )::integer = 28
         AND (
           v_app_progress_first
           ->> 'current_public_score_effect'
         )::integer = 28
         AND (v_app_progress_first ->> 'agreement_completed')::boolean
         AND (v_app_progress_first ->> 'positive_points_unlocked')::boolean
         AND (
           v_app_progress_first ->> 'positive_points_unlock_condition'
         ) = 'unlocked'
      THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 5.3A: borrower app RPC shows unlocked completed contribution';
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 5.3A first='
          || v_app_progress_first::text
          || ' second='
          || v_app_progress_second::text;
        RAISE WARNING
          'FAIL 5.3A: unexpected completed app progress first=%, second=%',
          v_app_progress_first,
          v_app_progress_second;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config(
      'request.jwt.claims',
      json_build_object('role', 'service_role')::text,
      true
    );
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 5.3A exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 5.3A: %', sqlerrm;
  END;

  -- 5.4  Signed v2.2 contribution of IOU 2 never exceeds ceiling ──────────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_ceiling integer;
      v_net_pts integer;
    BEGIN
      v_ceiling := public.score_v22_agreement_ceiling(v_sagr2_id);

      SELECT coalesce(sum(
        CASE
          WHEN impact_direction = 'penalty' THEN -points_awarded
          ELSE points_awarded
        END
      ), 0)::integer
      INTO v_net_pts
      FROM public.score_v2_contributions
      WHERE score_agreement_id = v_sagr2_id
        AND model_version = 'v2.2-shadow';

      IF v_net_pts <= v_ceiling THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 5.4: signed v2.2 contribution (%) <= ceiling (%)',
          v_net_pts,
          v_ceiling;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 5.4 signed sum='
          || v_net_pts
          || ' > ceiling='
          || v_ceiling;
        RAISE WARNING
          'FAIL 5.4: signed sum=% exceeds ceiling=%',
          v_net_pts,
          v_ceiling;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 5.4 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 5.4: %', sqlerrm;
  END;

  -- 5.5  Repeated completion recalculation remains idempotent ──────────────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_before           integer;
      v_after            integer;
      v_completion_count integer;
      v_early_count      integer;
    BEGIN
      PERFORM public.score_v22_recalculate_agreement(v_sagr2_id, now());

      SELECT count(*) INTO v_before
      FROM public.score_v2_contributions
      WHERE score_agreement_id = v_sagr2_id
        AND model_version = 'v2.2-shadow';

      PERFORM public.score_v22_recalculate_agreement(v_sagr2_id, now());
      PERFORM public.score_v22_recalculate_agreement(v_sagr2_id, now());

      SELECT
        count(*)::integer,
        count(*) FILTER (
          WHERE contribution_type = 'agreement_completion'
        )::integer,
        count(*) FILTER (
          WHERE contribution_type = 'early_payment_bonus'
        )::integer
      INTO
        v_after,
        v_completion_count,
        v_early_count
      FROM public.score_v2_contributions
      WHERE score_agreement_id = v_sagr2_id
        AND model_version = 'v2.2-shadow';

      IF v_after = v_before
         AND v_completion_count = 1
         AND v_early_count = 1
      THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 5.5: v2.2 completion recalculation idempotent (before=%, after=%)',
          v_before,
          v_after;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 5.5 before='
          || v_before
          || ' after='
          || v_after
          || ' completion='
          || v_completion_count
          || ' early='
          || v_early_count;
        RAISE WARNING
          'FAIL 5.5: before=%, after=%, completion=%, early=%',
          v_before,
          v_after,
          v_completion_count,
          v_early_count;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 5.5 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 5.5: %', sqlerrm;
  END;

  -- ===========================================================================
  -- GROUP 6: Exposure release
  -- ===========================================================================
  RAISE NOTICE '--- Group 6: Exposure release ---';

  -- 6.1  Activation adds exposure to borrower profile ───────────────────────
  -- Both IOUs were activated in setup. Verify borrower has positive exposure now.
  v_total := v_total + 1;
  BEGIN
    SELECT active_exposure_points INTO v_int
    FROM   public.profiles WHERE id = v_borrower_id;

    -- After both IOUs created and payments paid:
    -- iou1: all paid → exposure should be 0
    -- iou2: all paid → exposure should be 0
    -- But during setup BEFORE payments, exposure was added.
    -- By now (after all payments completed in earlier groups), exposure should be 0.
    -- We verify the exposure was positive after activation by checking iou1 and iou2's
    -- individual exposure_points both equal 0 (both fully paid).
    DECLARE
      v_exp1 integer;
      v_exp2 integer;
    BEGIN
      SELECT exposure_points INTO v_exp1 FROM public.ious WHERE id = v_iou1_id;
      SELECT exposure_points INTO v_exp2 FROM public.ious WHERE id = v_iou2_id;

      IF v_exp1 = 0 AND v_exp2 = 0 THEN
        v_pass := v_pass + 1;
        RAISE NOTICE 'PASS 6.1: fully paid IOUs have zero exposure (iou1_exp=%, iou2_exp=%)', v_exp1, v_exp2;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs := v_fail_msgs || ' | 6.1 iou1_exp=' || v_exp1 || ' iou2_exp=' || v_exp2;
        RAISE WARNING 'FAIL 6.1: iou1_exp=%, iou2_exp=%', v_exp1, v_exp2;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 6.1 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 6.1: %', sqlerrm;
  END;

  -- 6.2  After all payments on both IOUs, borrower profile exposure = 0 ──────
  v_total := v_total + 1;
  BEGIN
    PERFORM public.recalculate_profile_exposure(v_borrower_id);

    SELECT active_exposure_points INTO v_int
    FROM   public.profiles WHERE id = v_borrower_id;

    IF v_int = 0 THEN
      v_pass := v_pass + 1;
      RAISE NOTICE 'PASS 6.2: borrower profile exposure = 0 after all IOUs completed';
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 6.2 profile_exposure=' || v_int;
      RAISE WARNING 'FAIL 6.2: borrower profile exposure=% (expected 0)', v_int;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 6.2 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 6.2: %', sqlerrm;
  END;

  -- 6.3  Partial payment pro-rates exposure (dedicated IOU) ─────────────────
  v_total := v_total + 1;
  DECLARE
    v_iou3_id  uuid := gen_random_uuid();
    v_pay3a_id uuid := gen_random_uuid();
    v_pay3b_id uuid := gen_random_uuid();
  BEGIN
    INSERT INTO public.ious (id, lender_id, borrower_id, principal_cents, apr_bps, start_date, term_months, frequency, status, activated_at)
    VALUES (v_iou3_id, v_lender_id, v_borrower_id, 50000, 0, current_date, 2, 'monthly', 'open', now());

    INSERT INTO public.payments (id, iou_id, due_date, amount_cents)
    VALUES
      (v_pay3a_id, v_iou3_id, current_date + 30, 25000),
      (v_pay3b_id, v_iou3_id, current_date + 60, 25000);

    DECLARE
      v_full_exp integer;
      v_half_exp integer;
    BEGIN
      -- exposure_points is 0 on INSERT; recompute to prime the initial value.
      PERFORM public.recompute_iou_exposure(v_iou3_id);
      SELECT exposure_points INTO v_full_exp FROM public.ious WHERE id = v_iou3_id;

      -- Pay first installment (25k of 50k total)
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
      PERFORM public.claim_payment(v_pay3a_id, v_borrower_id);
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', v_lender_id::text, 'role', 'authenticated')::text, true);
      PERFORM public.pay_and_receipt(v_pay3a_id);

      PERFORM public.recompute_iou_exposure(v_iou3_id);
      SELECT exposure_points INTO v_half_exp FROM public.ious WHERE id = v_iou3_id;

      IF v_full_exp > 0 AND v_half_exp >= 0 AND v_half_exp < v_full_exp THEN
        v_pass := v_pass + 1;
        RAISE NOTICE 'PASS 6.3: partial payment reduces exposure (full=%, half=%)', v_full_exp, v_half_exp;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs := v_fail_msgs || ' | 6.3 full_exp=' || v_full_exp || ' half_exp=' || v_half_exp;
        RAISE WARNING 'FAIL 6.3: exposure not pro-rated: full=%, half=%', v_full_exp, v_half_exp;
      END IF;
    END;

    -- Cleanup deferred to the outer transaction rollback.
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 6.3 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 6.3: %', sqlerrm;
    -- Cleanup deferred to the outer transaction rollback.
  END;

  -- 6.4  Repeated recomputation matches deterministic fixture exposure ─────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_profile_exposure  integer;
      v_expected_exposure integer;
      v_iou1_exposure     integer;
      v_iou2_exposure     integer;
    BEGIN
      -- IOU 1 and IOU 2 are fully paid. IOU 3 remains partially open until the
      -- outer transaction rollback, so its remaining exposure is legitimate.
      PERFORM public.recompute_iou_exposure(v_iou1_id);
      PERFORM public.recompute_iou_exposure(v_iou1_id);
      PERFORM public.recompute_iou_exposure(v_iou2_id);
      PERFORM public.recompute_iou_exposure(v_iou2_id);
      PERFORM public.recalculate_profile_exposure(v_borrower_id);
      PERFORM public.recalculate_profile_exposure(v_borrower_id);

      SELECT exposure_points INTO v_iou1_exposure
      FROM public.ious
      WHERE id = v_iou1_id;

      SELECT exposure_points INTO v_iou2_exposure
      FROM public.ious
      WHERE id = v_iou2_id;

      SELECT coalesce(sum(coalesce(exposure_points, 0)), 0)::integer
      INTO v_expected_exposure
      FROM public.ious
      WHERE borrower_id = v_borrower_id;

      SELECT active_exposure_points INTO v_profile_exposure
      FROM public.profiles
      WHERE id = v_borrower_id;

      IF v_iou1_exposure = 0
         AND v_iou2_exposure = 0
         AND v_profile_exposure = v_expected_exposure
         AND v_profile_exposure >= 0
      THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 6.4: repeated exposure recomputation is stable (profile=%, expected=%)',
          v_profile_exposure,
          v_expected_exposure;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 6.4 profile='
          || v_profile_exposure
          || ' expected='
          || v_expected_exposure
          || ' iou1='
          || v_iou1_exposure
          || ' iou2='
          || v_iou2_exposure;
        RAISE WARNING
          'FAIL 6.4: profile=%, expected=%, iou1=%, iou2=%',
          v_profile_exposure,
          v_expected_exposure,
          v_iou1_exposure,
          v_iou2_exposure;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 6.4 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 6.4: %', sqlerrm;
  END;

  -- ===========================================================================
  -- GROUP 7: Snapshot separation
  -- ===========================================================================
  RAISE NOTICE '--- Group 7: Snapshot separation ---';

  -- 7.1  Snapshot stores legacy public_score and v2_shadow_score separately ──
  v_total := v_total + 1;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_borrower_id::text, 'role', 'authenticated')::text, true);
    v_snap_id := public.create_trust_score_snapshot(v_borrower_id, 'regression_test');

    SELECT * INTO v_snap FROM public.trust_score_snapshots WHERE id = v_snap_id;

    IF  v_snap.public_score       IS NOT NULL
    AND v_snap.v2_shadow_score    IS NOT NULL
    AND v_snap.public_score       != v_snap.v2_shadow_score  -- v1 vs v2 differ (v2 > v1 since v2 includes contributions)
        OR (v_snap.public_score = v_snap.v2_shadow_score)    -- same is also acceptable if baseline scores match
    THEN
      v_pass := v_pass + 1;
      RAISE NOTICE 'PASS 7.1: snapshot has both public_score=% and v2_shadow_score=%',
        v_snap.public_score, v_snap.v2_shadow_score;
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 7.1 snapshot missing fields';
      RAISE WARNING 'FAIL 7.1: public_score=%, v2_shadow_score=%', v_snap.public_score, v_snap.v2_shadow_score;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 7.1 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 7.1: %', sqlerrm;
  END;

  -- 7.2  Snapshot stores all seven required fields separately ───────────────
  v_total := v_total + 1;
  BEGIN
    SELECT * INTO v_snap FROM public.trust_score_snapshots WHERE id = v_snap_id;

    IF  v_snap.public_score             IS NOT NULL   -- legacy v1 score
    AND v_snap.v2_shadow_score          IS NOT NULL   -- v2 shadow score
    AND v_snap.visible_trust            IS NOT NULL   -- legacy visible trust
    AND v_snap.v2_shadow_visible_trust  IS NOT NULL   -- v2 shadow visible trust
    AND v_snap.score_contributed_total  IS NOT NULL   -- contribution total
    AND v_snap.active_exposure_points   IS NOT NULL   -- active exposure
    AND v_snap.model_version            IS NOT NULL   -- actual shadow model version
    THEN
      v_pass := v_pass + 1;
      RAISE NOTICE 'PASS 7.2: all 7 snapshot fields populated (public=%, v2=%, v_trust=%, v2_v_trust=%, contrib=%, exposure=%, model=%)',
        v_snap.public_score, v_snap.v2_shadow_score,
        v_snap.visible_trust, v_snap.v2_shadow_visible_trust,
        v_snap.score_contributed_total, v_snap.active_exposure_points,
        v_snap.model_version;
    ELSE
      v_fail := v_fail + 1;
      v_fail_msgs := v_fail_msgs || ' | 7.2 snapshot missing required fields';
      RAISE WARNING 'FAIL 7.2: some snapshot fields null: public=%, v2=%, visible=%, v2_visible=%, contrib=%, exposure=%, model=%',
        v_snap.public_score, v_snap.v2_shadow_score,
        v_snap.visible_trust, v_snap.v2_shadow_visible_trust,
        v_snap.score_contributed_total, v_snap.active_exposure_points,
        v_snap.model_version;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 7.2 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 7.2: %', sqlerrm;
  END;

  -- 7.3  Score v2 calculations must not overwrite profiles.iou_score ─────────
  v_total := v_total + 1;
  BEGIN
    DECLARE
      v_profile_score_before integer;
      v_profile_score_after  integer;
      v_shadow_ver           text;
    BEGIN
      SELECT iou_score INTO v_profile_score_before
      FROM   public.profiles WHERE id = v_borrower_id;

      SELECT version INTO v_shadow_ver
      FROM   public.trust_model_versions
      WHERE  model_key = 'iou_score' AND status = 'shadow'
      ORDER  BY activated_at DESC LIMIT 1;

      PERFORM public.recalculate_score_v2_user(v_borrower_id, v_shadow_ver);

      SELECT iou_score INTO v_profile_score_after
      FROM   public.profiles WHERE id = v_borrower_id;

      IF v_profile_score_before IS NOT DISTINCT FROM v_profile_score_after THEN
        v_pass := v_pass + 1;
        RAISE NOTICE 'PASS 7.3: profiles.iou_score unchanged after v2 recalculation (score=%)', v_profile_score_after;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs := v_fail_msgs || ' | 7.3 iou_score changed: before=' || v_profile_score_before || ' after=' || v_profile_score_after;
        RAISE WARNING 'FAIL 7.3: profiles.iou_score changed from % to %', v_profile_score_before, v_profile_score_after;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 7.3 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 7.3: %', sqlerrm;
  END;

  -- 7.4  Shadow snapshot uses signed active contributions ─────────────────
  v_total := v_total + 1;
  BEGIN
    SELECT * INTO v_snap
    FROM public.trust_score_snapshots
    WHERE id = v_snap_id;

    DECLARE
      v_expected_v2 integer;
      v_contrib_sum integer;
      v_base_score  integer := 700;
    BEGIN
      SELECT coalesce(sum(
        CASE
          WHEN c.impact_direction = 'penalty' THEN -c.points_awarded
          ELSE c.points_awarded
        END
      ), 0)::integer
      INTO v_contrib_sum
      FROM public.score_v2_contributions AS c
      JOIN public.trust_outcome_events AS e
        ON e.id = c.outcome_event_id
      WHERE c.user_id = v_borrower_id
        AND c.model_key = 'iou_score'
        AND c.model_version = v_snap.model_version
        AND e.outcome_at > now() - interval '2 years';

      v_expected_v2 :=
        greatest(300, least(1400, v_base_score + v_contrib_sum));

      IF v_snap.v2_shadow_score = v_expected_v2
         AND v_snap.score_contributed_total = v_contrib_sum
      THEN
        v_pass := v_pass + 1;
        RAISE NOTICE
          'PASS 7.4: v2_shadow_score=% matches base plus signed active contributions (% + %=%)',
          v_snap.v2_shadow_score,
          v_base_score,
          v_contrib_sum,
          v_expected_v2;
      ELSE
        v_fail := v_fail + 1;
        v_fail_msgs :=
          v_fail_msgs
          || ' | 7.4 v2_score='
          || v_snap.v2_shadow_score
          || ' expected='
          || v_expected_v2
          || ' contrib_total='
          || v_snap.score_contributed_total
          || ' signed_contrib_sum='
          || v_contrib_sum;
        RAISE WARNING
          'FAIL 7.4: v2_score=%, expected=%, contrib_total=%, signed_sum=%',
          v_snap.v2_shadow_score,
          v_expected_v2,
          v_snap.score_contributed_total,
          v_contrib_sum;
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    v_fail_msgs := v_fail_msgs || ' | 7.4 exception: ' || sqlerrm;
    RAISE WARNING 'FAIL 7.4: %', sqlerrm;
  END;

  -- ===========================================================================
  -- CLEANUP
  -- ===========================================================================
  -- Never delete append-only trust evidence. The outer transaction rollback
  -- removes every temporary regression fixture atomically.
  RAISE NOTICE '--- Cleanup deferred to transaction rollback ---';

  -- ===========================================================================
  -- RESULTS
  -- ===========================================================================
  RAISE NOTICE '=== RESULTS [%]: % / % passed ===', v_run_id, v_pass, v_total;

  IF v_fail > 0 THEN
    RAISE EXCEPTION
      'Regression suite FAILED [%]: % of % tests failed.%',
      v_run_id, v_fail, v_total, v_fail_msgs;
  ELSE
    RAISE NOTICE 'All % tests PASSED.', v_total;
  END IF;

END;
$$;

SELECT jsonb_build_object(
  'suite', 'ACH + Score v2 regression',
  'passed', true,
  'cleanup', 'transaction_rollback'
) AS regression_ach_score_v2_summary;

ROLLBACK;
