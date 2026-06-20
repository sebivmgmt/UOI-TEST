-- Score v2.1 get_my_current_trust_score() RPC regression suite.
-- 36 checks: auth guard, row count, model resolution, formula consistency,
-- privilege grants, boundary window tests, expired evidence, active exposure,
-- RPC/snapshot agreement, no-side-effects, version-specific totals, sole shadow.
-- Runs against DEV (colkilearqxuyldzjutw). LIVE untouched.
-- No permanent data — the entire suite runs in a transaction and is rolled back.
BEGIN;
DO $$
DECLARE
  v_fail        integer := 0;
  v_fail_detail text    := '';
  -- ── Primary fixture user (T1-T12) ─────────────────────────────────────────
  v_user_id     uuid := gen_random_uuid();
  v_email       text;
  -- ── RPC output fields ─────────────────────────────────────────────────────
  v_model_version                text;
  v_base_score                   integer;
  v_effective_contribution_total integer;
  v_shadow_score                 integer;
  v_exposure                     integer;
  v_freshness_score              integer;
  v_visible_trust                integer;
  v_trust_tier                   text;
  v_proof_depth                  integer;
  v_proof_depth_label            text;
  v_confidence_score             integer;
  v_confidence_label             text;
  v_qualifying_agreement_count   integer;
  v_qualifying_ceiling_total     integer;
  v_lifetime_reward_total        integer;
  v_lifetime_penalty_total       integer;
  v_contribution_window_start    timestamptz;
  v_days_on_platform             integer;
  -- ── Expected values from canonical helpers ────────────────────────────────
  v_exp_visible_trust integer;
  v_exp_trust_tier    text;
  v_exp_proof_label   text;
  v_exp_conf_label    text;
  -- ── Shadow model facts ────────────────────────────────────────────────────
  v_shadow_model_version text;
  v_shadow_base_score    integer;
  -- ── T1-T12 temp vars ──────────────────────────────────────────────────────
  v_row_count integer;
  -- ── Scenario users (T13-T36) ──────────────────────────────────────────────
  v_ua uuid := gen_random_uuid();
  v_ub uuid := gen_random_uuid();
  v_uc uuid := gen_random_uuid();
  v_ud uuid := gen_random_uuid();
  v_ue uuid := gen_random_uuid();
  v_uf uuid := gen_random_uuid();
  v_ug uuid := gen_random_uuid();
  v_uh uuid := gen_random_uuid();
  -- ── Agreements for scenario users ─────────────────────────────────────────
  v_sa_ua uuid := gen_random_uuid();
  v_sa_ub uuid := gen_random_uuid();
  v_sa_uc uuid := gen_random_uuid();
  v_sa_ud uuid := gen_random_uuid();
  v_sa_uf uuid := gen_random_uuid();
  v_sa_uh uuid := gen_random_uuid();
  -- ── Trust outcome events for scenario users ───────────────────────────────
  v_toe_ua uuid := gen_random_uuid();
  v_toe_ub uuid := gen_random_uuid();
  v_toe_uc uuid := gen_random_uuid();
  v_toe_ud uuid := gen_random_uuid();
  v_toe_uf uuid := gen_random_uuid();
  v_toe_uh uuid := gen_random_uuid();
  -- ── Snapshot row (T20-T27) ────────────────────────────────────────────────
  v_snap_id                 uuid;
  v_snap_model_version      text;
  v_snap_contribution_total integer;
  v_snap_shadow_score       integer;
  v_snap_exposure           integer;
  v_snap_visible_trust      integer;
  v_snap_proof_depth        integer;
  v_snap_confidence_score   integer;
  v_snap_trust_tier         text;
  -- ── Side-effect counters (T28) ────────────────────────────────────────────
  v_count_snap_before    integer;
  v_count_snap_after     integer;
  v_count_contrib_before integer;
  v_count_contrib_after  integer;
  -- ── iou_score guard (T29) ─────────────────────────────────────────────────
  v_iou_score_after integer;
  -- ── Privilege flags (T14) ─────────────────────────────────────────────────
  v_auth_has_execute boolean;
  v_anon_has_execute boolean;
  -- ── No-args check (T13) ───────────────────────────────────────────────────
  v_pronargs integer;
  -- ── Sole-shadow check (T31) ───────────────────────────────────────────────
  v_shadow_model_count   integer;
  v_shadow_model_ver_chk text;
BEGIN
  -- ══════════════════════════════════════════════════════════════════════════
  -- SETUP — primary fixture
  -- ══════════════════════════════════════════════════════════════════════════
  v_email := 'rpc_t1_' || substr(v_user_id::text, 1, 8) || '@iou.test';
  INSERT INTO auth.users (
    id,
    email,
    raw_app_meta_data,
    raw_user_meta_data,
    is_super_admin,
    encrypted_password,
    created_at,
    updated_at,
    aud,
    role
  )
  VALUES (
    v_user_id,
    v_email,
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb,
    false,
    '',
    now(),
    now(),
    'authenticated',
    'authenticated'
  );
  INSERT INTO public.profiles (
    id,
    email,
    full_name,
    iou_hash,
    created_at
  )
  VALUES (
    v_user_id,
    v_email,
    '',
    public.generate_iou_hash(),
    now()
  )
  ON CONFLICT (id) DO NOTHING;
  SELECT
    tmv.version,
    greatest(
      700,
      coalesce((tmv.config ->> 'base_score')::integer, 700)
    )
  INTO
    v_shadow_model_version,
    v_shadow_base_score
  FROM public.trust_model_versions tmv
  WHERE tmv.model_key = 'iou_score'
    AND tmv.status = 'shadow'
  ORDER BY tmv.activated_at DESC NULLS LAST
  LIMIT 1;
  -- ── Test 1: unauthenticated call raises 42501 ──────────────────────────────
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    PERFORM public.get_my_current_trust_score();
    v_fail_detail := v_fail_detail
      || E'\n  [T1 auth-guard] expected 42501, got no exception';
    RAISE WARNING 'TEST 1 FAIL: expected auth exception, got none';
    v_fail := v_fail + 1;
  EXCEPTION
    WHEN sqlstate '42501' THEN
      NULL;
    WHEN OTHERS THEN
      v_fail_detail := v_fail_detail
        || format(
          E'\n  [T1 auth-guard] expected 42501, got %s: %s',
          sqlstate,
          sqlerrm
        );
      RAISE WARNING
        'TEST 1 FAIL: wrong exception %: %',
        sqlstate,
        sqlerrm;
      v_fail := v_fail + 1;
  END;
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_user_id::text,
      'role', 'authenticated'
    )::text,
    true
  );
  SELECT
    r.model_version,
    r.base_score,
    r.effective_contribution_total,
    r.shadow_score,
    r.active_exposure_points,
    r.freshness_score,
    r.visible_trust,
    r.trust_tier,
    r.proof_depth,
    r.proof_depth_label,
    r.confidence_score,
    r.confidence_label,
    r.qualifying_agreement_count,
    r.qualifying_ceiling_total,
    r.lifetime_reward_total,
    r.lifetime_penalty_total,
    r.contribution_window_start,
    r.days_on_platform
  INTO
    v_model_version,
    v_base_score,
    v_effective_contribution_total,
    v_shadow_score,
    v_exposure,
    v_freshness_score,
    v_visible_trust,
    v_trust_tier,
    v_proof_depth,
    v_proof_depth_label,
    v_confidence_score,
    v_confidence_label,
    v_qualifying_agreement_count,
    v_qualifying_ceiling_total,
    v_lifetime_reward_total,
    v_lifetime_penalty_total,
    v_contribution_window_start,
    v_days_on_platform
  FROM public.get_my_current_trust_score() r;
  -- ── Test 2: returns exactly one row ────────────────────────────────────────
  SELECT count(*)
  INTO v_row_count
  FROM public.get_my_current_trust_score();
  IF v_row_count IS DISTINCT FROM 1 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T2 row-count] expected 1 row, got %s',
        v_row_count
      );
    RAISE WARNING
      'TEST 2 FAIL: expected 1 row, got %',
      v_row_count;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 3: model version matches current shadow model ────────────────────
  IF v_model_version IS DISTINCT FROM v_shadow_model_version THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T3 model-version] expected %s, got %s',
        v_shadow_model_version,
        v_model_version
      );
    RAISE WARNING
      'TEST 3 FAIL: model_version mismatch: expected %, got %',
      v_shadow_model_version,
      v_model_version;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 4: base score is at least 700 ─────────────────────────────────────
  IF v_base_score < 700 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T4 base-score] expected >=700, got %s',
        v_base_score
      );
    RAISE WARNING
      'TEST 4 FAIL: base_score < 700: %',
      v_base_score;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 5: base score matches model config ────────────────────────────────
  IF v_base_score IS DISTINCT FROM v_shadow_base_score THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T5 base-score-config] expected %s, got %s',
        v_shadow_base_score,
        v_base_score
      );
    RAISE WARNING
      'TEST 5 FAIL: base_score mismatch: expected %, got %',
      v_shadow_base_score,
      v_base_score;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 6: shadow score formula ───────────────────────────────────────────
  DECLARE
    v_exp_shadow integer := greatest(
      300,
      least(
        1400,
        v_base_score + v_effective_contribution_total
      )
    );
  BEGIN
    IF v_shadow_score IS DISTINCT FROM v_exp_shadow THEN
      v_fail_detail := v_fail_detail
        || format(
          E'\n  [T6 shadow-score-formula] expected %s, got %s',
          v_exp_shadow,
          v_shadow_score
        );
      RAISE WARNING
        'TEST 6 FAIL: expected %, got %',
        v_exp_shadow,
        v_shadow_score;
      v_fail := v_fail + 1;
    END IF;
  END;
  -- ── Test 7: shadow score bounds ────────────────────────────────────────────
  IF v_shadow_score < 300 OR v_shadow_score > 1400 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T7 shadow-score-bounds] expected [300,1400], got %s',
        v_shadow_score
      );
    RAISE WARNING
      'TEST 7 FAIL: shadow_score out of bounds: %',
      v_shadow_score;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 8: freshness score ────────────────────────────────────────────────
  IF v_freshness_score IS DISTINCT FROM 100 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T8 freshness] expected 100, got %s',
        v_freshness_score
      );
    RAISE WARNING
      'TEST 8 FAIL: expected freshness 100, got %',
      v_freshness_score;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 9: visible trust canonical helper ────────────────────────────────
  v_exp_visible_trust := public.score_v2_visible_trust(
    v_shadow_score,
    v_exposure,
    v_freshness_score
  );
  IF v_visible_trust IS DISTINCT FROM v_exp_visible_trust THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T9 visible-trust] expected %s, got %s',
        v_exp_visible_trust,
        v_visible_trust
      );
    RAISE WARNING
      'TEST 9 FAIL: expected %, got %',
      v_exp_visible_trust,
      v_visible_trust;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 10: trust tier canonical helper ──────────────────────────────────
  v_exp_trust_tier := public.score_v2_trust_tier(
    v_shadow_score,
    v_days_on_platform,
    v_proof_depth,
    false,
    false
  );
  IF v_trust_tier IS DISTINCT FROM v_exp_trust_tier THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T10 trust-tier] expected %s, got %s',
        v_exp_trust_tier,
        v_trust_tier
      );
    RAISE WARNING
      'TEST 10 FAIL: expected %, got %',
      v_exp_trust_tier,
      v_trust_tier;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 11: proof-depth label ─────────────────────────────────────────────
  v_exp_proof_label :=
    public.score_v2_proof_depth_label(v_proof_depth);
  IF v_proof_depth_label IS DISTINCT FROM v_exp_proof_label THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T11 proof-label] expected %s, got %s',
        v_exp_proof_label,
        v_proof_depth_label
      );
    RAISE WARNING
      'TEST 11 FAIL: expected %, got %',
      v_exp_proof_label,
      v_proof_depth_label;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 12: confidence label ──────────────────────────────────────────────
  v_exp_conf_label :=
    public.score_v2_confidence_label(v_confidence_score);
  IF v_confidence_label IS DISTINCT FROM v_exp_conf_label THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T12 confidence-label] expected %s, got %s',
        v_exp_conf_label,
        v_confidence_label
      );
    RAISE WARNING
      'TEST 12 FAIL: expected %, got %',
      v_exp_conf_label,
      v_confidence_label;
    v_fail := v_fail + 1;
  END IF;
  -- ══════════════════════════════════════════════════════════════════════════
  -- SETUP — scenario users
  -- ══════════════════════════════════════════════════════════════════════════
  INSERT INTO auth.users (
    id,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at
  )
  VALUES
    (
      v_ua,
      'rpc_ua_' || substr(v_ua::text, 1, 8) || '@iou.test',
      'x',
      now(),
      now(),
      now()
    ),
    (
      v_ub,
      'rpc_ub_' || substr(v_ub::text, 1, 8) || '@iou.test',
      'x',
      now(),
      now(),
      now()
    ),
    (
      v_uc,
      'rpc_uc_' || substr(v_uc::text, 1, 8) || '@iou.test',
      'x',
      now(),
      now(),
      now()
    ),
    (
      v_ud,
      'rpc_ud_' || substr(v_ud::text, 1, 8) || '@iou.test',
      'x',
      now(),
      now(),
      now()
    ),
    (
      v_ue,
      'rpc_ue_' || substr(v_ue::text, 1, 8) || '@iou.test',
      'x',
      now(),
      now(),
      now()
    ),
    (
      v_uf,
      'rpc_uf_' || substr(v_uf::text, 1, 8) || '@iou.test',
      'x',
      now(),
      now(),
      now()
    ),
    (
      v_ug,
      'rpc_ug_' || substr(v_ug::text, 1, 8) || '@iou.test',
      'x',
      now(),
      now(),
      now()
    ),
    (
      v_uh,
      'rpc_uh_' || substr(v_uh::text, 1, 8) || '@iou.test',
      'x',
      now(),
      now(),
      now()
    );
  INSERT INTO public.profiles (
    id,
    email,
    full_name,
    iou_hash,
    created_at
  )
  VALUES
    (
      v_ua,
      'rpc_ua_' || substr(v_ua::text, 1, 8) || '@iou.test',
      '',
      public.generate_iou_hash(),
      now()
    ),
    (
      v_ub,
      'rpc_ub_' || substr(v_ub::text, 1, 8) || '@iou.test',
      '',
      public.generate_iou_hash(),
      now()
    ),
    (
      v_uc,
      'rpc_uc_' || substr(v_uc::text, 1, 8) || '@iou.test',
      '',
      public.generate_iou_hash(),
      now()
    ),
    (
      v_ud,
      'rpc_ud_' || substr(v_ud::text, 1, 8) || '@iou.test',
      '',
      public.generate_iou_hash(),
      now()
    ),
    (
      v_ue,
      'rpc_ue_' || substr(v_ue::text, 1, 8) || '@iou.test',
      '',
      public.generate_iou_hash(),
      now()
    ),
    (
      v_uf,
      'rpc_uf_' || substr(v_uf::text, 1, 8) || '@iou.test',
      '',
      public.generate_iou_hash(),
      now()
    ),
    (
      v_ug,
      'rpc_ug_' || substr(v_ug::text, 1, 8) || '@iou.test',
      '',
      public.generate_iou_hash(),
      now()
    ),
    (
      v_uh,
      'rpc_uh_' || substr(v_uh::text, 1, 8) || '@iou.test',
      '',
      public.generate_iou_hash(),
      now()
    )
  ON CONFLICT (id) DO NOTHING;
  UPDATE public.profiles
  SET active_exposure_points = 50
  WHERE id = v_ue;
  INSERT INTO public.score_agreements (
    id,
    user_id,
    source_type,
    source_id,
    counterparty_id,
    amount_cents,
    term_months,
    frequency,
    status,
    proof_tier,
    verification_tier,
    obligation_weight,
    score_ceiling,
    score_contributed,
    same_pair_index,
    same_pair_multiplier,
    activated_at,
    completed_at,
    metadata
  )
  VALUES
    (
      v_sa_ua,
      v_ua,
      'personal_iou',
      gen_random_uuid(),
      v_user_id,
      50000,
      12,
      'monthly',
      'completed',
      1,
      1,
      1.0,
      35,
      0,
      1,
      1.00,
      now() - interval '1 year',
      now() - interval '6 months',
      '{}'
    ),
    (
      v_sa_ub,
      v_ub,
      'personal_iou',
      gen_random_uuid(),
      v_user_id,
      50000,
      12,
      'monthly',
      'completed',
      1,
      1,
      1.0,
      35,
      0,
      1,
      1.00,
      now() - interval '1 year',
      now() - interval '6 months',
      '{}'
    ),
    (
      v_sa_uc,
      v_uc,
      'personal_iou',
      gen_random_uuid(),
      v_user_id,
      50000,
      12,
      'monthly',
      'completed',
      1,
      1,
      1.0,
      35,
      0,
      1,
      1.00,
      now() - interval '1 year',
      now() - interval '6 months',
      '{}'
    ),
    (
      v_sa_ud,
      v_ud,
      'personal_iou',
      gen_random_uuid(),
      v_user_id,
      50000,
      12,
      'monthly',
      'completed',
      1,
      1,
      1.0,
      35,
      0,
      1,
      1.00,
      now() - interval '3 years',
      now() - interval '2 years' - interval '1 day',
      '{}'
    ),
    (
      v_sa_uf,
      v_uf,
      'personal_iou',
      gen_random_uuid(),
      v_user_id,
      50000,
      12,
      'monthly',
      'completed',
      1,
      1,
      1.0,
      35,
      0,
      1,
      1.00,
      now() - interval '1 year',
      now() - interval '6 months',
      '{}'
    ),
    (
      v_sa_uh,
      v_uh,
      'personal_iou',
      gen_random_uuid(),
      v_user_id,
      50000,
      12,
      'monthly',
      'completed',
      1,
      1,
      1.0,
      35,
      0,
      1,
      1.00,
      now() - interval '1 year',
      now() - interval '6 months',
      '{}'
    );
  INSERT INTO public.trust_outcome_events (
    id,
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    outcome_at,
    amount_cents,
    proof_tier,
    verification_tier,
    metadata
  )
  VALUES (
    v_toe_ua,
    v_ua,
    v_sa_ua,
    'personal_iou',
    v_sa_ua,
    'payment_paid_on_time',
    now() - interval '2 years' + interval '2 seconds',
    50000,
    1,
    1,
    '{}'
  );
  INSERT INTO public.trust_outcome_events (
    id,
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    outcome_at,
    amount_cents,
    proof_tier,
    verification_tier,
    metadata
  )
  VALUES (
    v_toe_ub,
    v_ub,
    v_sa_ub,
    'personal_iou',
    v_sa_ub,
    'payment_paid_on_time',
    now() - interval '2 years',
    50000,
    1,
    1,
    '{}'
  );
  INSERT INTO public.trust_outcome_events (
    id,
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    outcome_at,
    amount_cents,
    proof_tier,
    verification_tier,
    metadata
  )
  VALUES (
    v_toe_uc,
    v_uc,
    v_sa_uc,
    'personal_iou',
    v_sa_uc,
    'payment_paid_late',
    now() - interval '2 years',
    50000,
    1,
    1,
    '{}'
  );
  INSERT INTO public.score_v2_contributions (
    user_id,
    outcome_event_id,
    score_agreement_id,
    contribution_type,
    source_outcome_type,
    model_key,
    model_version,
    points_awarded,
    points_cap,
    impact_direction,
    metadata
  )
  VALUES (
    v_uc,
    v_toe_uc,
    v_sa_uc,
    'payment_late_penalty',
    'payment_paid_late',
    'iou_score',
    'v2.1-shadow',
    5,
    5,
    'penalty',
    '{}'
  );
  INSERT INTO public.trust_outcome_events (
    id,
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    outcome_at,
    amount_cents,
    proof_tier,
    verification_tier,
    metadata
  )
  VALUES (
    v_toe_ud,
    v_ud,
    v_sa_ud,
    'personal_iou',
    v_sa_ud,
    'payment_paid_on_time',
    now() - interval '2 years' - interval '2 seconds',
    50000,
    1,
    1,
    '{}'
  );
  INSERT INTO public.trust_outcome_events (
    id,
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    outcome_at,
    amount_cents,
    proof_tier,
    verification_tier,
    metadata
  )
  VALUES (
    v_toe_uf,
    v_uf,
    v_sa_uf,
    'personal_iou',
    v_sa_uf,
    'payment_paid_on_time',
    now() - interval '2 years' + interval '2 seconds',
    50000,
    1,
    1,
    '{}'
  );
  INSERT INTO public.trust_outcome_events (
    id,
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    outcome_at,
    amount_cents,
    proof_tier,
    verification_tier,
    metadata
  )
  VALUES (
    v_toe_uh,
    v_uh,
    v_sa_uh,
    'personal_iou',
    v_sa_uh,
    'payment_paid_on_time',
    now() - interval '2 years' + interval '2 seconds',
    50000,
    1,
    1,
    '{}'
  );
  INSERT INTO public.score_v2_contributions (
    user_id,
    outcome_event_id,
    score_agreement_id,
    contribution_type,
    source_outcome_type,
    model_key,
    model_version,
    points_awarded,
    points_cap,
    impact_direction,
    metadata
  )
  VALUES (
    v_uh,
    v_toe_uh,
    v_sa_uh,
    'payment_performance',
    'payment_paid_on_time',
    'iou_score',
    'v2.0-shadow',
    999,
    999,
    'reward',
    '{}'
  );
  -- ── Test 13: function accepts no arguments ────────────────────────────────
  SELECT coalesce(min(p.pronargs), -1)
  INTO v_pronargs
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n
    ON n.oid = p.pronamespace
  WHERE p.proname = 'get_my_current_trust_score'
    AND n.nspname = 'public';
  IF v_pronargs IS DISTINCT FROM 0 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T13 no-args] expected pronargs=0, got %s',
        v_pronargs
      );
    RAISE WARNING
      'TEST 13 FAIL: pronargs=%',
      v_pronargs;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 14a: authenticated execute grant ─────────────────────────────────
  SELECT has_function_privilege(
    'authenticated',
    'public.get_my_current_trust_score()',
    'EXECUTE'
  )
  INTO v_auth_has_execute;
  IF NOT coalesce(v_auth_has_execute, false) THEN
    v_fail_detail := v_fail_detail
      || E'\n  [T14a grant-auth] authenticated lacks EXECUTE';
    RAISE WARNING
      'TEST 14a FAIL: authenticated lacks EXECUTE';
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 14b: anon execute denied ─────────────────────────────────────────
  SELECT has_function_privilege(
    'anon',
    'public.get_my_current_trust_score()',
    'EXECUTE'
  )
  INTO v_anon_has_execute;
  IF coalesce(v_anon_has_execute, false) THEN
    v_fail_detail := v_fail_detail
      || E'\n  [T14b grant-anon] anon unexpectedly has EXECUTE';
    RAISE WARNING
      'TEST 14b FAIL: anon should not have EXECUTE';
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 15: in-window reward ──────────────────────────────────────────────
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_ua::text,
      'role', 'authenticated'
    )::text,
    true
  );
  SELECT r.effective_contribution_total
  INTO v_effective_contribution_total
  FROM public.get_my_current_trust_score() r;
  IF v_effective_contribution_total <= 0 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T15 in-window-reward] expected >0, got %s',
        v_effective_contribution_total
      );
    RAISE WARNING
      'TEST 15 FAIL: in-window reward not counted: %',
      v_effective_contribution_total;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 16: exact boundary reward excluded ────────────────────────────────
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_ub::text,
      'role', 'authenticated'
    )::text,
    true
  );
  SELECT r.effective_contribution_total
  INTO v_effective_contribution_total
  FROM public.get_my_current_trust_score() r;
  IF v_effective_contribution_total IS DISTINCT FROM 0 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T16 boundary-reward] expected 0, got %s',
        v_effective_contribution_total
      );
    RAISE WARNING
      'TEST 16 FAIL: expected 0, got %',
      v_effective_contribution_total;
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 17: exact boundary penalty excluded ───────────────────────────────
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_uc::text,
      'role', 'authenticated'
    )::text,
    true
  );
  SELECT r.effective_contribution_total
  INTO v_effective_contribution_total
  FROM public.get_my_current_trust_score() r;
  IF v_effective_contribution_total IS DISTINCT FROM 0 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T17 boundary-penalty] expected 0, got %s',
        v_effective_contribution_total
      );
    RAISE WARNING
      'TEST 17 FAIL: expected 0, got %',
      v_effective_contribution_total;
    v_fail := v_fail + 1;
  END IF;
  -- ── Tests 18a-e: expired evidence has no current effect ───────────────────
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_ud::text,
      'role', 'authenticated'
    )::text,
    true
  );
  SELECT
    r.effective_contribution_total,
    r.shadow_score,
    r.proof_depth,
    r.confidence_score,
    r.visible_trust,
    r.trust_tier
  INTO
    v_effective_contribution_total,
    v_shadow_score,
    v_proof_depth,
    v_confidence_score,
    v_visible_trust,
    v_trust_tier
  FROM public.get_my_current_trust_score() r;
  IF v_shadow_score IS DISTINCT FROM v_shadow_base_score THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T18a expired-score] expected %s, got %s',
        v_shadow_base_score,
        v_shadow_score
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_proof_depth IS DISTINCT FROM 0 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T18b expired-proof] expected 0, got %s',
        v_proof_depth
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_confidence_score IS DISTINCT FROM 30 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T18c expired-confidence] expected 30, got %s',
        v_confidence_score
      );
    v_fail := v_fail + 1;
  END IF;
  v_exp_visible_trust :=
    public.score_v2_visible_trust(
      v_shadow_base_score,
      0,
      100
    );
  IF v_visible_trust IS DISTINCT FROM v_exp_visible_trust THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T18d expired-visible-trust] expected %s, got %s',
        v_exp_visible_trust,
        v_visible_trust
      );
    v_fail := v_fail + 1;
  END IF;
  v_exp_trust_tier :=
    public.score_v2_trust_tier(
      v_shadow_base_score,
      0,
      0,
      false,
      false
    );
  IF v_trust_tier IS DISTINCT FROM v_exp_trust_tier THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T18e expired-trust-tier] expected %s, got %s',
        v_exp_trust_tier,
        v_trust_tier
      );
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 19: active exposure remains current state ────────────────────────
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_ue::text,
      'role', 'authenticated'
    )::text,
    true
  );
  SELECT
    r.active_exposure_points,
    r.visible_trust,
    r.shadow_score
  INTO
    v_exposure,
    v_visible_trust,
    v_shadow_score
  FROM public.get_my_current_trust_score() r;
  IF v_exposure IS DISTINCT FROM 50 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T19 active-exposure] expected 50, got %s',
        v_exposure
      );
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 28: RPC creates no rows ──────────────────────────────────────────
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_ug::text,
      'role', 'authenticated'
    )::text,
    true
  );
  SELECT count(*)
  INTO v_count_snap_before
  FROM public.trust_score_snapshots tss
  WHERE tss.user_id = v_ug;
  SELECT count(*)
  INTO v_count_contrib_before
  FROM public.score_v2_contributions sc
  WHERE sc.user_id = v_ug;
  PERFORM public.get_my_current_trust_score();
  PERFORM public.get_my_current_trust_score();
  SELECT count(*)
  INTO v_count_snap_after
  FROM public.trust_score_snapshots tss
  WHERE tss.user_id = v_ug;
  SELECT count(*)
  INTO v_count_contrib_after
  FROM public.score_v2_contributions sc
  WHERE sc.user_id = v_ug;
  IF v_count_snap_after <> v_count_snap_before
     OR v_count_contrib_after <> v_count_contrib_before
  THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T28 no-side-effects] snapshots %s→%s, contributions %s→%s',
        v_count_snap_before,
        v_count_snap_after,
        v_count_contrib_before,
        v_count_contrib_after
      );
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 29: legacy score unchanged ───────────────────────────────────────
  UPDATE public.profiles
  SET iou_score = 741
  WHERE id = v_ug;
  PERFORM public.get_my_current_trust_score();
  PERFORM public.get_my_current_trust_score();
  SELECT p.iou_score
  INTO v_iou_score_after
  FROM public.profiles p
  WHERE p.id = v_ug;
  IF v_iou_score_after IS DISTINCT FROM 741 THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T29 iou-score-unchanged] expected 741, got %s',
        v_iou_score_after
      );
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 30: version-specific lifetime totals ─────────────────────────────
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_uh::text,
      'role', 'authenticated'
    )::text,
    true
  );
  SELECT
    r.lifetime_reward_total,
    r.lifetime_penalty_total
  INTO
    v_lifetime_reward_total,
    v_lifetime_penalty_total
  FROM public.get_my_current_trust_score() r;
  IF v_lifetime_reward_total >= 999
     OR v_lifetime_penalty_total <> 0
  THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T30 version-specific] expected reward<999 and penalty=0; got reward=%s penalty=%s',
        v_lifetime_reward_total,
        v_lifetime_penalty_total
      );
    v_fail := v_fail + 1;
  END IF;
  -- ── Tests 20-27: RPC and snapshot agreement ───────────────────────────────
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_uf::text,
      'role', 'authenticated'
    )::text,
    true
  );
  v_snap_id :=
    public.create_trust_score_snapshot(
      v_uf,
      'rpc_regression_test'
    );
  SELECT
    tss.model_version,
    tss.score_contributed_total,
    tss.v2_shadow_score,
    tss.active_exposure_points,
    tss.v2_shadow_visible_trust,
    tss.v2_shadow_proof_depth,
    tss.v2_shadow_confidence_score,
    tss.v2_shadow_trust_tier
  INTO
    v_snap_model_version,
    v_snap_contribution_total,
    v_snap_shadow_score,
    v_snap_exposure,
    v_snap_visible_trust,
    v_snap_proof_depth,
    v_snap_confidence_score,
    v_snap_trust_tier
  FROM public.trust_score_snapshots tss
  WHERE tss.id = v_snap_id;
  SELECT
    r.model_version,
    r.effective_contribution_total,
    r.shadow_score,
    r.active_exposure_points,
    r.visible_trust,
    r.proof_depth,
    r.confidence_score,
    r.trust_tier
  INTO
    v_model_version,
    v_effective_contribution_total,
    v_shadow_score,
    v_exposure,
    v_visible_trust,
    v_proof_depth,
    v_confidence_score,
    v_trust_tier
  FROM public.get_my_current_trust_score() r;
  IF v_model_version IS DISTINCT FROM v_snap_model_version THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T20 snapshot-model] snapshot=%s rpc=%s',
        v_snap_model_version,
        v_model_version
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_effective_contribution_total
     IS DISTINCT FROM v_snap_contribution_total
  THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T21 snapshot-contribution] snapshot=%s rpc=%s',
        v_snap_contribution_total,
        v_effective_contribution_total
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_shadow_score IS DISTINCT FROM v_snap_shadow_score THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T22 snapshot-score] snapshot=%s rpc=%s',
        v_snap_shadow_score,
        v_shadow_score
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_exposure IS DISTINCT FROM v_snap_exposure THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T23 snapshot-exposure] snapshot=%s rpc=%s',
        v_snap_exposure,
        v_exposure
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_visible_trust IS DISTINCT FROM v_snap_visible_trust THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T24 snapshot-visible-trust] snapshot=%s rpc=%s',
        v_snap_visible_trust,
        v_visible_trust
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_proof_depth IS DISTINCT FROM v_snap_proof_depth THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T25 snapshot-proof-depth] snapshot=%s rpc=%s',
        v_snap_proof_depth,
        v_proof_depth
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_confidence_score IS DISTINCT FROM v_snap_confidence_score THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T26 snapshot-confidence] snapshot=%s rpc=%s',
        v_snap_confidence_score,
        v_confidence_score
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_trust_tier IS DISTINCT FROM v_snap_trust_tier THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T27 snapshot-tier] snapshot=%s rpc=%s',
        v_snap_trust_tier,
        v_trust_tier
      );
    v_fail := v_fail + 1;
  END IF;
  -- ── Test 31: sole current shadow model ────────────────────────────────────
  SELECT count(*)
  INTO v_shadow_model_count
  FROM public.trust_model_versions tmv
  WHERE tmv.model_key = 'iou_score'
    AND tmv.status = 'shadow';
  SELECT tmv.version
  INTO v_shadow_model_ver_chk
  FROM public.trust_model_versions tmv
  WHERE tmv.model_key = 'iou_score'
    AND tmv.status = 'shadow'
  LIMIT 1;
  IF v_shadow_model_count <> 1
     OR v_shadow_model_ver_chk IS DISTINCT FROM 'v2.1-shadow'
  THEN
    v_fail_detail := v_fail_detail
      || format(
        E'\n  [T31 sole-shadow] expected count=1 version=v2.1-shadow; got count=%s version=%s',
        v_shadow_model_count,
        v_shadow_model_ver_chk
      );
    v_fail := v_fail + 1;
  END IF;
  IF v_fail > 0 THEN
    RAISE EXCEPTION
      'regression_score_v21_rpc: % test(s) failed:%',
      v_fail,
      v_fail_detail;
  END IF;
END
$$;
ROLLBACK;
SELECT 'regression_score_v21_rpc: all 36 checks passed' AS result;