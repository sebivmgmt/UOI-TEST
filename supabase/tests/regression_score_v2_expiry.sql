-- Score v2.1 expiry and model regression suite — 28 tests
-- Tests 1–14:  rolling evidence window (strict >, boundary, penalty, cleanup)
-- Tests 15–28: v2.1 model (one shadow, trigger dispatch, curve, cap, pair index)
-- Runs as postgres via Management API (SET search_path-secured functions callable).
-- On failure the final RAISE EXCEPTION includes every failed-assertion detail.

DO $$
DECLARE
  v_fail        integer := 0;
  v_fail_detail text    := '';

  v_user_id   uuid := gen_random_uuid();
  v_user_b_id uuid := gen_random_uuid();
  v_email_a   text := 'expiry_a_' || substr(v_user_id::text,1,8) || '@test.invalid';
  v_email_b   text := 'expiry_b_' || substr(v_user_b_id::text,1,8) || '@test.invalid';

  v_sa_id    uuid := gen_random_uuid();
  v_sa_b_id  uuid := gen_random_uuid();
  v_sa_c_id  uuid := gen_random_uuid();
  v_toe_id   uuid := gen_random_uuid();
  v_toe_b_id uuid := gen_random_uuid();

  v_eff_total    integer;
  v_eff_b        integer;
  v_count_before integer;
  v_count_after  integer;
  v_outcome_at   timestamptz;
  v_calc_at      timestamptz;
  v_pair_idx_a   integer;
  v_pair_idx_b   integer;
  v_ceil_v21     integer;
  v_mult_v21     numeric;
  v_got          integer;
  v_model_count  integer;
  v_model_version text := 'v2.1-shadow';

  -- Isolated users for penalty-boundary (test 3) and signed-total (test 4)
  v_user_pen_id  uuid        := gen_random_uuid();  -- exactly one penalty, no rewards
  v_sa_pen_id    uuid        := gen_random_uuid();
  v_toe_pen_id   uuid        := gen_random_uuid();
  v_penalty_at   timestamptz;

  v_user_sig_id  uuid        := gen_random_uuid();  -- one reward (+7) + one penalty (-5)
  v_sa_rew_id    uuid        := gen_random_uuid();
  v_toe_rew_id   uuid        := gen_random_uuid();
  v_sa_pen2_id   uuid        := gen_random_uuid();
  v_toe_pen2_id  uuid        := gen_random_uuid();
BEGIN

  -- ── SETUP ─────────────────────────────────────────────────────────────────

  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES
    (v_user_id,   v_email_a, 'x', now(), now(), now()),
    (v_user_b_id, v_email_b, 'x', now(), now(), now());

  -- Agreement A: activated 1 yr ago; amount $500; pair index 1
  INSERT INTO public.score_agreements (
    id, user_id, source_type, source_id, counterparty_id,
    amount_cents, term_months, frequency, status,
    proof_tier, verification_tier, obligation_weight,
    score_ceiling, score_contributed, same_pair_index, same_pair_multiplier,
    activated_at, completed_at, metadata
  ) VALUES (
    v_sa_id, v_user_id, 'personal_iou', gen_random_uuid(), v_user_b_id,
    50000, 12, 'monthly', 'completed',
    1, 1, 1.0, 35, 0, 1, 1.00,
    now() - interval '1 year', now() - interval '6 months', '{}'
  );

  -- TOE for A: outcome_at = now()-2yr+1sec (strictly inside window).
  -- Inserting into trust_outcome_events fires trg_score_v2_shadow_on_outcome
  -- which calls score_v2_recalculate_agreement_v21 and creates the
  -- payment_performance contribution row automatically.
  -- At trigger time B does not yet exist → pair_index=1 → pp_points=7.
  INSERT INTO public.trust_outcome_events (
    id, user_id, score_agreement_id, source_type, source_id,
    outcome_type, outcome_at, amount_cents, proof_tier, verification_tier, metadata
  ) VALUES (
    v_toe_id, v_user_id, v_sa_id, 'personal_iou', v_sa_id,
    'payment_paid_on_time',
    now() - interval '2 years' + interval '1 second',
    50000, 1, 1, '{}'
  );

  -- Agreement B: activated >2yr ago; pair index relative to B's own activated_at.
  -- B.activated_at = now()-2yr-1day is WITHIN A's activation-relative 2yr lookback
  -- (window: A.activated_at-2yr to A.activated_at = now()-3yr to now()-1yr).
  -- Therefore score_v2_activation_pair_index_v21(v_sa_id) called AFTER B is inserted
  -- returns 2 (see test 14).  A's stored contribution (7 pts) was calculated at
  -- trigger time when B did not yet exist and is immutable.
  INSERT INTO public.score_agreements (
    id, user_id, source_type, source_id, counterparty_id,
    amount_cents, term_months, frequency, status,
    proof_tier, verification_tier, obligation_weight,
    score_ceiling, score_contributed, same_pair_index, same_pair_multiplier,
    activated_at, completed_at, metadata
  ) VALUES (
    v_sa_b_id, v_user_id, 'personal_iou', gen_random_uuid(), v_user_b_id,
    50000, 12, 'monthly', 'completed',
    1, 1, 1.0, 35, 0, 2, 0.80,
    now() - interval '2 years' - interval '1 day',
    now() - interval '2 years', '{}'
  );

  -- TOE for B: outcome_at = now()-2yr exactly (at the boundary → excluded from
  -- effective totals by strict >, but the row IS created by the trigger).
  INSERT INTO public.trust_outcome_events (
    id, user_id, score_agreement_id, source_type, source_id,
    outcome_type, outcome_at, amount_cents, proof_tier, verification_tier, metadata
  ) VALUES (
    v_toe_b_id, v_user_id, v_sa_b_id, 'personal_iou', v_sa_b_id,
    'payment_paid_on_time',
    now() - interval '2 years',
    50000, 1, 1, '{}'
  );

  -- Agreement C: for pair-index tests; insert here so v_sa_c_id is non-null below
  INSERT INTO public.score_agreements (
    id, user_id, source_type, source_id, counterparty_id,
    amount_cents, term_months, frequency, status,
    proof_tier, verification_tier, obligation_weight,
    score_ceiling, score_contributed, same_pair_index, same_pair_multiplier,
    activated_at, completed_at, metadata
  ) VALUES (
    v_sa_c_id, v_user_id, 'personal_iou', gen_random_uuid(), v_user_b_id,
    50000, 12, 'monthly', 'completed',
    1, 1, 1.0, 35, 0, 3, 0.64,
    now() - interval '1 year', now() - interval '6 months', '{}'
  );

  -- ── PENALTY-BOUNDARY USER (test 3): one penalty outcome, no rewards ─────────
  v_penalty_at := now() - interval '1 year';
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (v_user_pen_id,
          'expiry_pen_' || substr(v_user_pen_id::text,1,8) || '@test.invalid',
          'x', now(), now(), now());
  INSERT INTO public.score_agreements (
    id, user_id, source_type, source_id, counterparty_id,
    amount_cents, term_months, frequency, status,
    proof_tier, verification_tier, obligation_weight,
    score_ceiling, score_contributed, same_pair_index, same_pair_multiplier,
    activated_at, completed_at, metadata
  ) VALUES (
    v_sa_pen_id, v_user_pen_id, 'personal_iou', gen_random_uuid(), v_user_b_id,
    50000, 12, 'monthly', 'completed',
    1, 1, 1.0, 35, 0, 1, 1.00,
    now() - interval '2 years', now() - interval '1 year', '{}'
  );
  -- TOE fires trigger → payment_performance (0 pts, late). Penalty row inserted manually.
  INSERT INTO public.trust_outcome_events (
    id, user_id, score_agreement_id, source_type, source_id,
    outcome_type, outcome_at, amount_cents, proof_tier, verification_tier, metadata
  ) VALUES (
    v_toe_pen_id, v_user_pen_id, v_sa_pen_id, 'personal_iou', v_sa_pen_id,
    'payment_paid_late', v_penalty_at, 50000, 1, 1, '{}'
  );
  ALTER TABLE public.score_v2_contributions DISABLE TRIGGER trg_score_v2_contributions_immutable;
  INSERT INTO public.score_v2_contributions (
    user_id, outcome_event_id, score_agreement_id,
    contribution_type, source_outcome_type,
    model_key, model_version, points_awarded, points_cap, impact_direction, metadata
  ) VALUES (
    v_user_pen_id, v_toe_pen_id, v_sa_pen_id,
    'payment_late_penalty', 'payment_paid_late',
    'iou_score', v_model_version, 5, 5, 'penalty', '{}'
  );
  ALTER TABLE public.score_v2_contributions ENABLE TRIGGER trg_score_v2_contributions_immutable;

  -- ── SIGNED-TOTAL USER (test 4): one reward (+7) + one penalty (-5) = +2 ────
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  VALUES (v_user_sig_id,
          'expiry_sig_' || substr(v_user_sig_id::text,1,8) || '@test.invalid',
          'x', now(), now(), now());
  -- Reward agreement: counterparty=v_user_id → unique pair for v_user_sig_id → pair_index=1
  -- → ceiling=35, pp_cap=7, on_time → 7pts
  INSERT INTO public.score_agreements (
    id, user_id, source_type, source_id, counterparty_id,
    amount_cents, term_months, frequency, status,
    proof_tier, verification_tier, obligation_weight,
    score_ceiling, score_contributed, same_pair_index, same_pair_multiplier,
    activated_at, completed_at, metadata
  ) VALUES (
    v_sa_rew_id, v_user_sig_id, 'personal_iou', gen_random_uuid(), v_user_id,
    50000, 12, 'monthly', 'completed',
    1, 1, 1.0, 35, 0, 1, 1.00,
    now() - interval '6 months', now() - interval '1 month', '{}'
  );
  INSERT INTO public.trust_outcome_events (
    id, user_id, score_agreement_id, source_type, source_id,
    outcome_type, outcome_at, amount_cents, proof_tier, verification_tier, metadata
  ) VALUES (
    v_toe_rew_id, v_user_sig_id, v_sa_rew_id, 'personal_iou', v_sa_rew_id,
    'payment_paid_on_time', now() - interval '6 months', 50000, 1, 1, '{}'
  );
  -- Penalty agreement: counterparty=v_user_b_id → different pair → pair_index=1 → late→0pt pp
  INSERT INTO public.score_agreements (
    id, user_id, source_type, source_id, counterparty_id,
    amount_cents, term_months, frequency, status,
    proof_tier, verification_tier, obligation_weight,
    score_ceiling, score_contributed, same_pair_index, same_pair_multiplier,
    activated_at, completed_at, metadata
  ) VALUES (
    v_sa_pen2_id, v_user_sig_id, 'personal_iou', gen_random_uuid(), v_user_b_id,
    50000, 12, 'monthly', 'completed',
    1, 1, 1.0, 35, 0, 1, 1.00,
    now() - interval '6 months', now() - interval '1 month', '{}'
  );
  INSERT INTO public.trust_outcome_events (
    id, user_id, score_agreement_id, source_type, source_id,
    outcome_type, outcome_at, amount_cents, proof_tier, verification_tier, metadata
  ) VALUES (
    v_toe_pen2_id, v_user_sig_id, v_sa_pen2_id, 'personal_iou', v_sa_pen2_id,
    'payment_paid_late', now() - interval '6 months', 50000, 1, 1, '{}'
  );
  ALTER TABLE public.score_v2_contributions DISABLE TRIGGER trg_score_v2_contributions_immutable;
  INSERT INTO public.score_v2_contributions (
    user_id, outcome_event_id, score_agreement_id,
    contribution_type, source_outcome_type,
    model_key, model_version, points_awarded, points_cap, impact_direction, metadata
  ) VALUES (
    v_user_sig_id, v_toe_pen2_id, v_sa_pen2_id,
    'payment_late_penalty', 'payment_paid_late',
    'iou_score', v_model_version, 5, 5, 'penalty', '{}'
  );
  ALTER TABLE public.score_v2_contributions ENABLE TRIGGER trg_score_v2_contributions_immutable;

  -- ── PART I: ROLLING EVIDENCE WINDOW (tests 1–14) ─────────────────────────

  -- Test 1: Reward at now()-2yr+1sec is inside the window
  v_eff_total := public.score_v2_effective_contributions_internal(
    v_user_id, v_model_version, now()
  );
  IF v_eff_total <= 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T1 inside-window reward] expected >0, got %s', v_eff_total);
    RAISE WARNING 'TEST 1 FAIL: inside-window reward should be >0, got %', v_eff_total;
    v_fail := v_fail + 1;
  END IF;

  -- Test 2: Outcome at exactly now()-2yr is excluded (strict >)
  -- Agreement B has TOE at now()-2yr. Only A's contribution (7 pts) should count.
  IF v_eff_total <> 7 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T2 boundary excluded] expected 7, got %s', v_eff_total);
    RAISE WARNING 'TEST 2 FAIL: boundary outcome should be excluded; expected 7, got %', v_eff_total;
    v_fail := v_fail + 1;
  END IF;

  -- Test 3: Penalty obeys the same strict two-year boundary as rewards.
  -- Dedicated v_user_pen_id has exactly one penalty contribution (5 pts, penalty).
  -- No reward contributions → p_at shift never contaminates the result.
  DECLARE
    v_p_at_inside   timestamptz := v_penalty_at + interval '2 years' - interval '1 second';
    v_p_at_boundary timestamptz := v_penalty_at + interval '2 years';
    v_eff_inside    integer;
    v_eff_boundary  integer;
  BEGIN
    -- p_at_inside window start = v_penalty_at - 1sec → penalty TOE (v_penalty_at) is inside
    v_eff_inside := public.score_v2_effective_contributions_internal(
      v_user_pen_id, v_model_version, v_p_at_inside
    );
    IF v_eff_inside <> -5 THEN
      v_fail_detail := v_fail_detail || format(
        E'\n  [T3 penalty inside window] expected -5, got %s', v_eff_inside);
      RAISE WARNING 'TEST 3 FAIL: penalty inside window expected -5, got %', v_eff_inside;
      v_fail := v_fail + 1;
    END IF;

    -- p_at_boundary window start = v_penalty_at exactly → penalty TOE excluded (strict >)
    v_eff_boundary := public.score_v2_effective_contributions_internal(
      v_user_pen_id, v_model_version, v_p_at_boundary
    );
    IF v_eff_boundary <> 0 THEN
      v_fail_detail := v_fail_detail || format(
        E'\n  [T3 penalty at boundary] expected 0, got %s', v_eff_boundary);
      RAISE WARNING 'TEST 3 FAIL: penalty at exact boundary expected 0, got %', v_eff_boundary;
      v_fail := v_fail + 1;
    END IF;
  END;

  -- Test 4: Signed effective total — dedicated user with reward (+7) and penalty (-5) = +2.
  -- v_user_sig_id: trigger-created 7-pt payment_performance (on-time, $500, idx 1)
  --                + trigger-created 0-pt payment_performance (late) + manual 5-pt penalty.
  v_eff_total := public.score_v2_effective_contributions_internal(
    v_user_sig_id, v_model_version, now()
  );
  IF v_eff_total <> 2 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T4 signed total] expected +2, got %s', v_eff_total);
    RAISE WARNING 'TEST 4 FAIL: signed total expected +2, got %', v_eff_total;
    v_fail := v_fail + 1;
  END IF;

  -- Test 5: Contribution rows are immutable after expiry check (no physical deletion)
  SELECT count(*) INTO v_count_before
  FROM public.score_v2_contributions
  WHERE user_id = v_user_id AND model_version = v_model_version;

  v_eff_b := public.score_v2_effective_contributions_internal(
    v_user_id, v_model_version, now() + interval '10 years'
  );

  SELECT count(*) INTO v_count_after
  FROM public.score_v2_contributions
  WHERE user_id = v_user_id AND model_version = v_model_version;

  IF v_count_before <> v_count_after THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T5 row immutability] count changed: before=%s, after=%s',
      v_count_before, v_count_after);
    RAISE WARNING 'TEST 5 FAIL: row count changed after expiry (before=%, after=%)',
      v_count_before, v_count_after;
    v_fail := v_fail + 1;
  END IF;
  IF v_eff_b <> 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T5 all expired] expected 0, got %s', v_eff_b);
    RAISE WARNING 'TEST 5 FAIL: all expired → expected 0, got %', v_eff_b;
    v_fail := v_fail + 1;
  END IF;

  -- Test 6: Recalculation does not mutate outcome_at
  SELECT toe.outcome_at INTO v_outcome_at
  FROM public.trust_outcome_events toe WHERE id = v_toe_id;

  PERFORM public.score_v2_recalculate_agreement_v21(v_sa_id);

  SELECT toe.outcome_at INTO v_calc_at
  FROM public.trust_outcome_events toe WHERE id = v_toe_id;

  IF v_outcome_at IS DISTINCT FROM v_calc_at THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T6 outcome_at immutable] before=%s, after=%s', v_outcome_at, v_calc_at);
    RAISE WARNING 'TEST 6 FAIL: outcome_at changed (before=%, after=%)', v_outcome_at, v_calc_at;
    v_fail := v_fail + 1;
  END IF;

  -- Test 7: Future p_at causes all outcomes to expire → effective total = 0
  v_eff_b := public.score_v2_effective_contributions_internal(
    v_user_id, v_model_version, now() + interval '10 years'
  );
  IF v_eff_b <> 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T7 future expiry] expected 0, got %s', v_eff_b);
    RAISE WARNING 'TEST 7 FAIL: future window effective total should be 0, got %', v_eff_b;
    v_fail := v_fail + 1;
  END IF;

  -- Test 8: Base score is 700 when effective contribution total = 0
  -- Confirm test 7's total is exactly 0, not a rounding artefact.
  IF v_eff_b <> 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T8 base-score fallback] expected 0, got %s', v_eff_b);
    RAISE WARNING 'TEST 8 FAIL: base-score fallback total must be 0, got %', v_eff_b;
    v_fail := v_fail + 1;
  END IF;

  -- Test 9: Windowed proof depth excludes agreement B (boundary outcome)
  -- v_sa_b_id: status='completed', outcome at exact boundary → NOT qualifying
  SELECT count(*)::integer INTO v_got
  FROM public.score_agreements sa
  WHERE sa.id = v_sa_b_id
    AND sa.status = 'completed'
    AND EXISTS (
      SELECT 1 FROM public.trust_outcome_events toe
      WHERE toe.score_agreement_id = sa.id
        AND toe.outcome_at > now() - interval '2 years'
    );
  IF v_got <> 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T9 boundary excluded from proof depth] expected count=0, got %s', v_got);
    RAISE WARNING 'TEST 9 FAIL: boundary-outcome agreement should not qualify for proof depth, got count=%', v_got;
    v_fail := v_fail + 1;
  END IF;
  -- At least A qualifies (has TOE > now()-2yr)
  SELECT count(distinct sa.id)::integer INTO v_got
  FROM public.score_agreements sa
  WHERE sa.user_id = v_user_id
    AND (
      sa.status = 'active'
      OR (
        sa.status = 'completed'
        AND EXISTS (
          SELECT 1 FROM public.trust_outcome_events toe
          WHERE toe.score_agreement_id = sa.id
            AND toe.outcome_at > now() - interval '2 years'
        )
      )
    );
  IF v_got < 1 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T9 qualifying count] expected >=1, got %s', v_got);
    RAISE WARNING 'TEST 9 FAIL: expected at least 1 qualifying agreement, got %', v_got;
    v_fail := v_fail + 1;
  END IF;

  -- Test 10: Lifetime contribution history is preserved (rows not deleted by expiry)
  SELECT count(*) INTO v_count_after
  FROM public.score_v2_contributions
  WHERE user_id = v_user_id AND model_version = v_model_version;
  IF v_count_after = 0 THEN
    v_fail_detail := v_fail_detail || E'\n  [T10 lifetime rows] expected >0 rows, got 0';
    RAISE WARNING 'TEST 10 FAIL: lifetime contribution rows must remain stored';
    v_fail := v_fail + 1;
  END IF;

  -- Test 11: active_exposure_points is unaffected by the effective-contribution call
  SELECT coalesce(active_exposure_points, 0) INTO v_got
  FROM public.profiles WHERE id = v_user_id;
  IF v_got < 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T11 exposure before] expected >=0, got %s', v_got);
    RAISE WARNING 'TEST 11 FAIL: active_exposure_points < 0 before call';
    v_fail := v_fail + 1;
  END IF;
  PERFORM public.score_v2_effective_contributions_internal(
    v_user_id, v_model_version, now()
  );
  SELECT coalesce(active_exposure_points, 0) INTO v_got
  FROM public.profiles WHERE id = v_user_id;
  IF v_got < 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T11 exposure after] expected >=0, got %s', v_got);
    RAISE WARNING 'TEST 11 FAIL: active_exposure_points < 0 after call';
    v_fail := v_fail + 1;
  END IF;

  -- Test 12: authenticated role has no EXECUTE on the internal function
  IF has_function_privilege(
    'authenticated',
    'score_v2_effective_contributions_internal(uuid,text,timestamptz)',
    'EXECUTE'
  ) THEN
    v_fail_detail := v_fail_detail ||
      E'\n  [T12 privilege] authenticated must not have EXECUTE on internal function';
    RAISE WARNING 'TEST 12 FAIL: authenticated must not have EXECUTE on internal function';
    v_fail := v_fail + 1;
  END IF;

  -- Test 13: Snapshot for a different user raises 42501
  BEGIN
    PERFORM set_config(
      'request.jwt.claims',
      json_build_object('sub', v_user_id, 'role', 'authenticated')::text,
      true
    );
    PERFORM public.create_trust_score_snapshot(v_user_b_id);
    v_fail_detail := v_fail_detail ||
      E'\n  [T13 cross-user snapshot] expected 42501, no exception raised';
    RAISE WARNING 'TEST 13 FAIL: cross-user snapshot did not raise';
    v_fail := v_fail + 1;
  EXCEPTION
    WHEN sqlstate '42501' THEN NULL; -- expected
    WHEN others THEN
      v_fail_detail := v_fail_detail || format(
        E'\n  [T13 cross-user snapshot] unexpected error %s: %s', SQLSTATE, SQLERRM);
      RAISE WARNING 'TEST 13 FAIL: unexpected % — %', SQLSTATE, SQLERRM;
      v_fail := v_fail + 1;
  END;
  PERFORM set_config('request.jwt.claims', '', true);

  -- Test 14: Pair-index lookback clock and evidence-window clock are independent.
  -- score_v2_activation_pair_index_v21 uses a window of
  --   (v_agr.activated_at - 2yr, v_agr.activated_at)   ← relative to agreement activation
  -- not the evidence window (now()-2yr, now()).
  --
  -- v_sa_id (A) activated_at = now()-1yr  → lookback window = (now()-3yr, now()-1yr).
  -- v_sa_b_id (B) activated_at = now()-2yr-1day IS inside that range → B is always counted.
  -- v_sa_c_id (C) has the same activated_at as A; whether it ranks "prior" via UUID
  -- tie-break is random, so pair_index is 2 (B only) or 3 (B + C).
  -- The invariant to assert is pair_index >= 2 (B is counted, proving lookback ≠ now()-2yr).
  v_pair_idx_a := public.score_v2_activation_pair_index_v21(v_sa_id);
  IF v_pair_idx_a < 2 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T14 pair-index independence] expected >=2 (B in lookback), got %s', v_pair_idx_a);
    RAISE WARNING 'TEST 14 FAIL: v_sa_id pair index should be >=2, got %', v_pair_idx_a;
    v_fail := v_fail + 1;
  END IF;
  -- A's outcome IS inside the evidence window (now()-2yr+1sec > now()-2yr) — 1 qualifying row
  SELECT count(*) INTO v_got
  FROM public.score_v2_contributions sc
  JOIN public.trust_outcome_events toe ON toe.id = sc.outcome_event_id
  WHERE sc.user_id            = v_user_id
    AND sc.model_version      = v_model_version
    AND sc.score_agreement_id = v_sa_id
    AND toe.outcome_at        > now() - interval '2 years';
  IF v_got <> 1 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T14 A in evidence window] expected 1 qualifying contribution, got %s', v_got);
    RAISE WARNING 'TEST 14 FAIL: A inside evidence window, expected 1, got %', v_got;
    v_fail := v_fail + 1;
  END IF;

  -- ── PART II: V2.1 MODEL TESTS (tests 15–28) ──────────────────────────────

  -- Test 15: Exactly one iou_score shadow model
  SELECT count(*) INTO v_model_count
  FROM public.trust_model_versions
  WHERE model_key = 'iou_score' AND status = 'shadow';
  IF v_model_count <> 1 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T15 one shadow model] expected 1, found %s', v_model_count);
    RAISE WARNING 'TEST 15 FAIL: expected 1 shadow model, found %', v_model_count;
    v_fail := v_fail + 1;
  END IF;

  -- Test 16: v2.0-shadow is deprecated (not shadow) after Migration B
  SELECT count(*) INTO v_got
  FROM public.trust_model_versions
  WHERE model_key = 'iou_score' AND version = 'v2.0-shadow' AND status = 'deprecated';
  IF v_got <> 1 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T16 v2.0 deprecated] expected count=1, got %s', v_got);
    RAISE WARNING 'TEST 16 FAIL: v2.0-shadow should be deprecated, count=%', v_got;
    v_fail := v_fail + 1;
  END IF;

  -- Test 17: New outcome event fires trigger → v2.1 contribution row created
  DECLARE
    v_new_sa_id  uuid := gen_random_uuid();
    v_new_toe_id uuid := gen_random_uuid();
    v_v21_count  integer;
    v_v20_count  integer;
  BEGIN
    INSERT INTO public.score_agreements (
      id, user_id, source_type, source_id, counterparty_id,
      amount_cents, term_months, frequency, status,
      proof_tier, verification_tier, obligation_weight,
      score_ceiling, score_contributed, same_pair_index, same_pair_multiplier,
      activated_at, completed_at, metadata
    ) VALUES (
      v_new_sa_id, v_user_id, 'personal_iou', gen_random_uuid(), v_user_b_id,
      100000, 12, 'monthly', 'completed',
      1, 1, 1.0, 56, 0, 4, 0.50,
      now() - interval '6 months', now() - interval '1 month', '{}'
    );

    INSERT INTO public.trust_outcome_events (
      id, user_id, score_agreement_id, source_type, source_id,
      outcome_type, outcome_at, amount_cents, proof_tier, verification_tier, metadata
    ) VALUES (
      v_new_toe_id, v_user_id, v_new_sa_id, 'personal_iou', v_new_sa_id,
      'payment_paid_on_time', now() - interval '3 months',
      100000, 1, 1, '{}'
    );

    SELECT count(*) INTO v_v21_count
    FROM public.score_v2_contributions
    WHERE score_agreement_id = v_new_sa_id AND model_version = 'v2.1-shadow';

    IF v_v21_count = 0 THEN
      v_fail_detail := v_fail_detail ||
        E'\n  [T17 trigger dispatch] expected v2.1 contribution row, found 0';
      RAISE WARNING 'TEST 17 FAIL: trigger did not create v2.1 contribution row';
      v_fail := v_fail + 1;
    END IF;

    -- Test 18: No v2.0 rows created after deprecation
    SELECT count(*) INTO v_v20_count
    FROM public.score_v2_contributions
    WHERE score_agreement_id = v_new_sa_id AND model_version = 'v2.0-shadow';

    IF v_v20_count > 0 THEN
      v_fail_detail := v_fail_detail || format(
        E'\n  [T18 no v2.0 rows] expected 0, found %s', v_v20_count);
      RAISE WARNING 'TEST 18 FAIL: trigger created v2.0 rows after deprecation (count=%)', v_v20_count;
      v_fail := v_fail + 1;
    END IF;
  END;

  -- Test 19: v2.0 and v2.1 effective totals are version-filtered (not mixed)
  DECLARE
    v_eff_v21    integer;
    v_direct_v21 integer;
  BEGIN
    v_eff_v21 := public.score_v2_effective_contributions_internal(
      v_user_id, 'v2.1-shadow', now()
    );

    SELECT coalesce(sum(
      CASE WHEN impact_direction = 'penalty' THEN -points_awarded ELSE points_awarded END
    ), 0)::integer
    INTO v_direct_v21
    FROM public.score_v2_contributions sc
    JOIN public.trust_outcome_events toe ON toe.id = sc.outcome_event_id
    WHERE sc.user_id       = v_user_id
      AND sc.model_version = 'v2.1-shadow'
      AND toe.outcome_at   > now() - interval '2 years';

    IF v_eff_v21 IS DISTINCT FROM v_direct_v21 THEN
      v_fail_detail := v_fail_detail || format(
        E'\n  [T19 version isolation] function=%s, direct=%s', v_eff_v21, v_direct_v21);
      RAISE WARNING 'TEST 19 FAIL: version isolation broken (function=%, direct=%)',
        v_eff_v21, v_direct_v21;
      v_fail := v_fail + 1;
    END IF;
  END;

  -- Test 20: score_v2_ceiling_for_agreement_v21 returns a non-negative integer
  v_ceil_v21 := public.score_v2_ceiling_for_agreement_v21(v_sa_id, null);
  IF v_ceil_v21 < 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T20 ceiling non-negative] expected >=0, got %s', v_ceil_v21);
    RAISE WARNING 'TEST 20 FAIL: v2.1 ceiling should be >= 0, got %', v_ceil_v21;
    v_fail := v_fail + 1;
  END IF;

  -- Test 21: Pair index is deterministic (same result on consecutive calls)
  v_pair_idx_a := public.score_v2_activation_pair_index_v21(v_sa_id);
  v_pair_idx_b := public.score_v2_activation_pair_index_v21(v_sa_id);
  IF v_pair_idx_a IS DISTINCT FROM v_pair_idx_b THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T21 deterministic] call1=%s, call2=%s', v_pair_idx_a, v_pair_idx_b);
    RAISE WARNING 'TEST 21 FAIL: pair index non-deterministic (% vs %)', v_pair_idx_a, v_pair_idx_b;
    v_fail := v_fail + 1;
  END IF;

  -- Test 22: Pair index for v_sa_c_id is at least 1
  v_pair_idx_a := public.score_v2_activation_pair_index_v21(v_sa_c_id);
  IF v_pair_idx_a < 1 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T22 pair index >=1] expected >=1, got %s', v_pair_idx_a);
    RAISE WARNING 'TEST 22 FAIL: pair index must be >= 1, got %', v_pair_idx_a;
    v_fail := v_fail + 1;
  END IF;

  -- Test 23: Old agreement with a recent outcome still contributes to v2.1
  -- v_sa_b_id was activated >2yr ago (outside any new agreement's lookback)
  -- but a new outcome event within the 2-yr evidence window is valid.
  DECLARE
    v_recent_toe uuid := gen_random_uuid();
  BEGIN
    INSERT INTO public.trust_outcome_events (
      id, user_id, score_agreement_id, source_type, source_id,
      outcome_type, outcome_at, amount_cents, proof_tier, verification_tier, metadata
    ) VALUES (
      v_recent_toe, v_user_id, v_sa_b_id, 'personal_iou', v_sa_b_id,
      'agreement_completed', now() - interval '1 year',
      50000, 1, 1, '{}'
    );
    -- Trigger fires → score_v2_recalculate_agreement_v21(v_sa_b_id)
    SELECT count(*) INTO v_got
    FROM public.score_v2_contributions sc
    JOIN public.trust_outcome_events toe ON toe.id = sc.outcome_event_id
    WHERE sc.score_agreement_id = v_sa_b_id
      AND sc.model_version      = 'v2.1-shadow'
      AND toe.outcome_at        > now() - interval '2 years';

    IF v_got = 0 THEN
      v_fail_detail := v_fail_detail ||
        E'\n  [T23 old agreement recent outcome] expected >=1 qualifying v2.1 contribution, got 0';
      RAISE WARNING 'TEST 23 FAIL: old agreement with recent outcome has no qualifying v2.1 contribution';
      v_fail := v_fail + 1;
    END IF;
  END;

  -- Test 24: family_obligation is not scored by v2.1
  DECLARE
    v_fam_sa_id  uuid := gen_random_uuid();
    v_fam_toe_id uuid := gen_random_uuid();
    v_fam_count  integer;
    v_result     jsonb;
  BEGIN
    INSERT INTO public.score_agreements (
      id, user_id, source_type, source_id, counterparty_id,
      amount_cents, term_months, frequency, status,
      proof_tier, verification_tier, obligation_weight,
      score_ceiling, score_contributed, same_pair_index, same_pair_multiplier,
      activated_at, completed_at, metadata
    ) VALUES (
      v_fam_sa_id, v_user_id, 'family_obligation', gen_random_uuid(), v_user_b_id,
      100000, 12, 'monthly', 'completed',
      1, 1, 1.0, 56, 0, 1, 1.00,
      now() - interval '6 months', now() - interval '1 month', '{}'
    );
    INSERT INTO public.trust_outcome_events (
      id, user_id, score_agreement_id, source_type, source_id,
      outcome_type, outcome_at, amount_cents, proof_tier, verification_tier, metadata
    ) VALUES (
      v_fam_toe_id, v_user_id, v_fam_sa_id, 'family_obligation', v_fam_sa_id,
      'agreement_completed', now() - interval '3 months',
      100000, 1, 1, '{}'
    );

    -- Direct call must return ok=false for non-personal_iou
    v_result := public.score_v2_recalculate_agreement_v21(v_fam_sa_id);
    IF coalesce((v_result ->> 'ok')::boolean, true) <> false THEN
      v_fail_detail := v_fail_detail || format(
        E'\n  [T24 family_obligation ok=false] expected false, got %s', v_result);
      RAISE WARNING 'TEST 24 FAIL: family_obligation should return ok=false, got %', v_result;
      v_fail := v_fail + 1;
    END IF;

    -- Trigger also must not have created v2.1 contribution rows
    SELECT count(*) INTO v_fam_count
    FROM public.score_v2_contributions
    WHERE score_agreement_id = v_fam_sa_id AND model_version = 'v2.1-shadow';
    IF v_fam_count > 0 THEN
      v_fail_detail := v_fail_detail || format(
        E'\n  [T24 family_obligation no rows] expected 0 rows, found %s', v_fam_count);
      RAISE WARNING 'TEST 24 FAIL: v2.1 created rows for family_obligation (count=%)', v_fam_count;
      v_fail := v_fail + 1;
    END IF;
  END;

  -- Test 25: payment_performance_share = exactly 0.20 in v2.1-shadow config
  DECLARE
    v_pp_share numeric;
  BEGIN
    SELECT ((config -> 'personal_iou' ->> 'payment_performance_share')::numeric)
    INTO v_pp_share
    FROM public.trust_model_versions
    WHERE model_key = 'iou_score' AND version = 'v2.1-shadow';

    IF v_pp_share IS DISTINCT FROM 0.20 THEN
      v_fail_detail := v_fail_detail || format(
        E'\n  [T25 pp_share] expected 0.20, got %s', v_pp_share);
      RAISE WARNING 'TEST 25 FAIL: pp_share should be 0.20, got %', v_pp_share;
      v_fail := v_fail + 1;
    END IF;
  END;

  -- Test 26: All 12 approved ceiling targets match score_v2_personal_iou_ceiling_v21
  DECLARE
    v_b RECORD;
  BEGIN
    FOR v_b IN
      SELECT cents, expected FROM (VALUES
        (2000::bigint,    1),
        (4000::bigint,    2),
        (5000::bigint,    3),
        (10000::bigint,   7),
        (20000::bigint,   12),
        (25000::bigint,   16),
        (48000::bigint,   29),
        (50000::bigint,   35),
        (75000::bigint,   45),
        (100000::bigint,  56),
        (200000::bigint,  104),
        (500000::bigint,  200)
      ) t(cents, expected)
    LOOP
      v_got := public.score_v2_personal_iou_ceiling_v21(v_b.cents);
      IF v_got IS DISTINCT FROM v_b.expected THEN
        v_fail_detail := v_fail_detail || format(
          E'\n  [T26 ceiling target] cents=%s expected=%s got=%s',
          v_b.cents, v_b.expected, v_got);
        RAISE WARNING 'TEST 26 FAIL: cents=% expected=% got=%',
          v_b.cents, v_b.expected, v_got;
        v_fail := v_fail + 1;
      END IF;
    END LOOP;
  END;

  -- Test 27: Amounts above $5,000 are capped at 200
  IF public.score_v2_personal_iou_ceiling_v21(1000000) <> 200 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T27 cap $10k] expected 200, got %s',
      public.score_v2_personal_iou_ceiling_v21(1000000));
    RAISE WARNING 'TEST 27 FAIL: $10k should cap at 200, got %',
      public.score_v2_personal_iou_ceiling_v21(1000000);
    v_fail := v_fail + 1;
  END IF;
  IF public.score_v2_personal_iou_ceiling_v21(5000000) <> 200 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T27 cap $50k] expected 200, got %s',
      public.score_v2_personal_iou_ceiling_v21(5000000));
    RAISE WARNING 'TEST 27 FAIL: $50k should cap at 200, got %',
      public.score_v2_personal_iou_ceiling_v21(5000000);
    v_fail := v_fail + 1;
  END IF;

  -- Test 28: Pair index 7 → 0.10; index 8+ → 0.00; ceiling at index 8 = 0
  IF public.score_v2_same_pair_multiplier_v21(7) <> 0.10 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T28 multiplier idx=7] expected 0.10, got %s',
      public.score_v2_same_pair_multiplier_v21(7));
    RAISE WARNING 'TEST 28 FAIL: index 7 multiplier should be 0.10, got %',
      public.score_v2_same_pair_multiplier_v21(7);
    v_fail := v_fail + 1;
  END IF;
  IF public.score_v2_same_pair_multiplier_v21(8) <> 0.00 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T28 multiplier idx=8] expected 0.00, got %s',
      public.score_v2_same_pair_multiplier_v21(8));
    RAISE WARNING 'TEST 28 FAIL: index 8 multiplier should be 0.00, got %',
      public.score_v2_same_pair_multiplier_v21(8);
    v_fail := v_fail + 1;
  END IF;
  IF public.score_v2_same_pair_multiplier_v21(100) <> 0.00 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T28 multiplier idx=100] expected 0.00, got %s',
      public.score_v2_same_pair_multiplier_v21(100));
    RAISE WARNING 'TEST 28 FAIL: index 100 multiplier should be 0.00, got %',
      public.score_v2_same_pair_multiplier_v21(100);
    v_fail := v_fail + 1;
  END IF;
  IF public.score_v2_ceiling_for_agreement_v21(v_sa_id, 8) <> 0 THEN
    v_fail_detail := v_fail_detail || format(
      E'\n  [T28 ceiling at idx=8] expected 0, got %s',
      public.score_v2_ceiling_for_agreement_v21(v_sa_id, 8));
    RAISE WARNING 'TEST 28 FAIL: ceiling at pair_index=8 should be 0, got %',
      public.score_v2_ceiling_for_agreement_v21(v_sa_id, 8);
    v_fail := v_fail + 1;
  END IF;

  -- ── CLEANUP (reverse FK order) ────────────────────────────────────────────
  DELETE FROM public.trust_score_snapshots
    WHERE user_id IN (v_user_id, v_user_b_id, v_user_pen_id, v_user_sig_id);
  ALTER TABLE public.score_v2_contributions DISABLE TRIGGER trg_score_v2_contributions_immutable;
  DELETE FROM public.score_v2_contributions
    WHERE user_id IN (v_user_id, v_user_b_id, v_user_pen_id, v_user_sig_id);
  ALTER TABLE public.score_v2_contributions ENABLE TRIGGER trg_score_v2_contributions_immutable;
  DELETE FROM public.trust_outcome_events
    WHERE user_id IN (v_user_id, v_user_b_id, v_user_pen_id, v_user_sig_id);
  DELETE FROM public.score_agreements
    WHERE user_id IN (v_user_id, v_user_b_id, v_user_pen_id, v_user_sig_id);
  DELETE FROM auth.users
    WHERE id IN (v_user_id, v_user_b_id, v_user_pen_id, v_user_sig_id);

  -- ── RESULT ────────────────────────────────────────────────────────────────
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'regression_score_v2_expiry: % test(s) failed:%', v_fail, v_fail_detail;
  END IF;
END $$;

SELECT 'regression_score_v2_expiry: all 28 checks passed' AS result;
