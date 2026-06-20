-- score_v2 calibration snapshot — records current function behavior.
-- Tests only the 12 approved target amounts. Snapshot values are what
-- the function currently returns; they are NOT the intended targets.
-- Intended targets: $20–$1000 match; $2000 target=104 (actual=93); $5000 target=200 (actual=113).
-- Run via run_calibration.sh against DEV (colkilearqxuyldzjutw).
-- LIVE untouched.

DO $$
DECLARE
  v_fail integer := 0;
  v_got  integer;
  v_mult numeric;
  v_mono_fail integer;
  v_max_below_10k integer;
  v_below integer;
  v_above integer;

BEGIN

  -- ── 1. Amount-curve snapshot (approved amounts only, measured 2026-06-20) ─
  -- $20–$1000 match intended targets exactly.
  -- $2000: actual=93, intended=104 (known defect — log segment under-scaled).
  -- $5000: actual=113, intended=200 (known defect — log segment under-scaled).
  v_got := public.score_v2_personal_iou_ceiling(2000);    -- $20
  IF v_got IS DISTINCT FROM 1   THEN RAISE WARNING 'DRIFT $20:   got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(4000);    -- $40
  IF v_got IS DISTINCT FROM 2   THEN RAISE WARNING 'DRIFT $40:   got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(5000);    -- $50
  IF v_got IS DISTINCT FROM 3   THEN RAISE WARNING 'DRIFT $50:   got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(10000);   -- $100
  IF v_got IS DISTINCT FROM 7   THEN RAISE WARNING 'DRIFT $100:  got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(20000);   -- $200
  IF v_got IS DISTINCT FROM 12  THEN RAISE WARNING 'DRIFT $200:  got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(25000);   -- $250
  IF v_got IS DISTINCT FROM 16  THEN RAISE WARNING 'DRIFT $250:  got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(48000);   -- $480
  IF v_got IS DISTINCT FROM 29  THEN RAISE WARNING 'DRIFT $480:  got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(50000);   -- $500
  IF v_got IS DISTINCT FROM 35  THEN RAISE WARNING 'DRIFT $500:  got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(75000);   -- $750
  IF v_got IS DISTINCT FROM 45  THEN RAISE WARNING 'DRIFT $750:  got %', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(100000);  -- $1000
  IF v_got IS DISTINCT FROM 56  THEN RAISE WARNING 'DRIFT $1000: got %', v_got; v_fail := v_fail+1; END IF;
  -- Known defects below — snapshot guards against further drift, not against intended value.
  v_got := public.score_v2_personal_iou_ceiling(200000);  -- $2000 (target=104, actual=93)
  IF v_got IS DISTINCT FROM 93  THEN RAISE WARNING 'DRIFT $2000: got % (snapshot=93, target=104)', v_got; v_fail := v_fail+1; END IF;
  v_got := public.score_v2_personal_iou_ceiling(500000);  -- $5000 (target=200, actual=113)
  IF v_got IS DISTINCT FROM 113 THEN RAISE WARNING 'DRIFT $5000: got % (snapshot=113, target=200)', v_got; v_fail := v_fail+1; END IF;

  -- ── 2. Same-pair multiplier snapshot ────────────────────────────────────
  v_mult := public.score_v2_same_pair_multiplier(1);
  IF round(v_mult*100) IS DISTINCT FROM 100 THEN RAISE WARNING 'PAIR idx=1: got %%%', round(v_mult*100); v_fail := v_fail+1; END IF;
  v_mult := public.score_v2_same_pair_multiplier(2);
  IF round(v_mult*100) IS DISTINCT FROM 80  THEN RAISE WARNING 'PAIR idx=2: got %%%', round(v_mult*100); v_fail := v_fail+1; END IF;
  v_mult := public.score_v2_same_pair_multiplier(3);
  IF round(v_mult*100) IS DISTINCT FROM 64  THEN RAISE WARNING 'PAIR idx=3: got %%%', round(v_mult*100); v_fail := v_fail+1; END IF;
  v_mult := public.score_v2_same_pair_multiplier(4);
  IF round(v_mult*100) IS DISTINCT FROM 50  THEN RAISE WARNING 'PAIR idx=4: got %%%', round(v_mult*100); v_fail := v_fail+1; END IF;
  v_mult := public.score_v2_same_pair_multiplier(5);
  IF round(v_mult*100) IS DISTINCT FROM 35  THEN RAISE WARNING 'PAIR idx=5: got %%%', round(v_mult*100); v_fail := v_fail+1; END IF;
  v_mult := public.score_v2_same_pair_multiplier(6);
  IF round(v_mult*100) IS DISTINCT FROM 20  THEN RAISE WARNING 'PAIR idx=6: got %%%', round(v_mult*100); v_fail := v_fail+1; END IF;
  v_mult := public.score_v2_same_pair_multiplier(10);
  IF round(v_mult*100) IS DISTINCT FROM 20  THEN RAISE WARNING 'PAIR idx=10: got %%%', round(v_mult*100); v_fail := v_fail+1; END IF;

  -- ── 3. $2k piecewise boundary jump currently = 13 ───────────────────────
  -- After the log-segment fix this will become 0 (continuous). Update then.
  v_below := public.score_v2_personal_iou_ceiling(199900); -- $1999
  v_above := public.score_v2_personal_iou_ceiling(200000); -- $2000
  IF (v_above - v_below) IS DISTINCT FROM 13 THEN
    RAISE WARNING '$2k boundary jump changed: was 13, now %', v_above - v_below;
    v_fail := v_fail + 1;
  END IF;

  -- ── 4. Monotonicity: no decrease in $1–$10k ──────────────────────────────
  SELECT count(*)
  INTO v_mono_fail
  FROM (
    SELECT public.score_v2_personal_iou_ceiling(n * 100) AS c,
           lag(public.score_v2_personal_iou_ceiling(n * 100))
             OVER (ORDER BY n) AS prev_c
    FROM generate_series(1, 10000) n
  ) t
  WHERE c < prev_c;

  IF v_mono_fail > 0 THEN
    RAISE WARNING 'MONOTONICITY VIOLATION: % decreasing step(s) in $1-$10k', v_mono_fail;
    v_fail := v_fail + 1;
  END IF;

  -- ── 5. Hard cap (140) not reached within $10k ──────────────────────────
  -- After the log-segment fix the cap must be raised; update or remove then.
  SELECT max(public.score_v2_personal_iou_ceiling(n * 100))
  INTO v_max_below_10k
  FROM generate_series(1, 10000) n;

  IF v_max_below_10k >= 140 THEN
    RAISE WARNING 'CAP HIT WITHIN $10k: max=% (cap=140)', v_max_below_10k;
    v_fail := v_fail + 1;
  END IF;

  -- ── Result ────────────────────────────────────────────────────────────────
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'CALIBRATION SNAPSHOT: % check(s) drifted', v_fail;
  END IF;

END $$;

SELECT 'calibration_score_v2_curve: all snapshot checks passed' AS result;
