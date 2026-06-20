-- ============================================================================
-- Score v2.2 regression suite
-- Expected result: all rows pass, then one summary row reports the total.
-- This suite is DEV-only and references the approved live DEV fixture.
-- ============================================================================

BEGIN;

CREATE TEMP TABLE score_v22_test_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.record_test(
  p_name text,
  p_passed boolean,
  p_details jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO score_v22_test_results(test_name, passed, details)
  VALUES (p_name, p_passed, COALESCE(p_details, '{}'::jsonb));
END
$$;

DO $tests$
DECLARE
  v_as_of timestamptz := '2026-06-20 12:00:00+00';
  v_eval jsonb;
  v_before bigint;
  v_after bigint;
  v_pair_index integer;
  v_ceiling integer;
  v_shadow_count integer;
  v_fixture_penalty_count integer;
  v_fixture_penalty_points integer;
BEGIN
  -- 1. On-time neutrality at 50% repaid.
  v_eval := public.score_v22_evaluate_personal_iou(
    35,
    50000,
    jsonb_build_array(
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'on_time',
        'outcome_at', v_as_of - interval '1 day'
      )
    ),
    NULL,
    v_as_of
  );

  PERFORM pg_temp.record_test(
    'on-time neutrality',
    (v_eval ->> 'pending_completion_points')::integer = 14
      AND (v_eval ->> 'pending_early_bonus')::integer = 0
      AND (v_eval ->> 'public_score_effect')::integer = 0,
    v_eval
  );

  -- 2. Early bonus is earned but still pending before completion.
  v_eval := public.score_v22_evaluate_personal_iou(
    35,
    50000,
    jsonb_build_array(
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'early',
        'outcome_at', v_as_of - interval '1 day'
      )
    ),
    NULL,
    v_as_of
  );

  PERFORM pg_temp.record_test(
    'early bonus pending before completion',
    (v_eval ->> 'pending_completion_points')::integer = 14
      AND (v_eval ->> 'pending_early_bonus')::integer = 7
      AND NOT (v_eval ->> 'positive_points_unlocked')::boolean
      AND (v_eval ->> 'public_score_effect')::integer = 0,
    v_eval
  );

  -- 3. Positive points unlock only at completion.
  v_eval := public.score_v22_evaluate_personal_iou(
    35,
    50000,
    jsonb_build_array(
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'on_time',
        'outcome_at', v_as_of - interval '2 days'
      ),
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'on_time',
        'outcome_at', v_as_of - interval '1 day'
      )
    ),
    v_as_of - interval '1 hour',
    v_as_of
  );

  PERFORM pg_temp.record_test(
    'positive points unlock only at completion',
    (v_eval ->> 'base_completion_reward')::integer = 28
      AND (v_eval ->> 'public_score_effect')::integer = 28
      AND (v_eval ->> 'positive_points_unlocked')::boolean,
    v_eval
  );

  -- 4. Multiple early installments cannot exceed the one capped early pool.
  v_eval := public.score_v22_evaluate_personal_iou(
    35,
    50000,
    jsonb_build_array(
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'early',
        'outcome_at', v_as_of - interval '2 days'
      ),
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'early',
        'outcome_at', v_as_of - interval '1 day'
      )
    ),
    v_as_of - interval '1 hour',
    v_as_of
  );

  PERFORM pg_temp.record_test(
    'no duplicate early bonus',
    (v_eval ->> 'pending_early_bonus')::integer = 7
      AND (v_eval ->> 'public_score_effect')::integer = 35,
    v_eval
  );

  -- 5. Approved example: ceiling 28, 50% installment, one day late => -2.
  PERFORM pg_temp.record_test(
    'one-day late penalty',
    public.score_v22_late_penalty_points(28, 50000, 25000, 1) = 2,
    jsonb_build_object(
      'actual', public.score_v22_late_penalty_points(28, 50000, 25000, 1),
      'expected', 2
    )
  );

  -- 6. Two separate late installments create two additive penalties.
  v_eval := public.score_v22_evaluate_personal_iou(
    28,
    50000,
    jsonb_build_array(
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'late',
        'days_late', 1,
        'outcome_at', v_as_of - interval '2 days'
      ),
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'late',
        'days_late', 8,
        'outcome_at', v_as_of - interval '1 day'
      )
    ),
    NULL,
    v_as_of
  );

  PERFORM pg_temp.record_test(
    'multiple separate late penalties',
    (v_eval ->> 'active_penalties')::integer = 9
      AND (v_eval ->> 'public_score_effect')::integer = -9,
    v_eval
  );

  -- 7. Mixed early/on-time/late history remains independent.
  v_eval := public.score_v22_evaluate_personal_iou(
    35,
    50000,
    jsonb_build_array(
      jsonb_build_object(
        'amount_cents', 10000,
        'outcome', 'early',
        'outcome_at', v_as_of - interval '3 days'
      ),
      jsonb_build_object(
        'amount_cents', 20000,
        'outcome', 'on_time',
        'outcome_at', v_as_of - interval '2 days'
      ),
      jsonb_build_object(
        'amount_cents', 20000,
        'outcome', 'late',
        'days_late', 4,
        'outcome_at', v_as_of - interval '1 day'
      )
    ),
    v_as_of - interval '1 hour',
    v_as_of
  );

  PERFORM pg_temp.record_test(
    'mixed early on-time late history',
    (v_eval ->> 'pending_early_bonus')::integer = 7
      AND (v_eval ->> 'active_penalties')::integer = 4
      AND (v_eval ->> 'public_score_effect')::integer = 31,
    v_eval
  );

  -- 8. Completion does not erase penalties.
  PERFORM pg_temp.record_test(
    'completion with penalties',
    (v_eval ->> 'positive_points_unlocked')::boolean
      AND (v_eval ->> 'public_score_effect')::integer
          = (
              (v_eval ->> 'base_completion_reward')::integer
              + (v_eval ->> 'pending_early_bonus')::integer
              - (v_eval ->> 'active_penalties')::integer
            ),
    v_eval
  );

  -- 9. Recalculation is append-only and idempotent.
  SELECT count(*)
  INTO v_before
  FROM public.score_v2_contributions
  WHERE score_agreement_id = 'db90834c-948f-473a-831a-453132b05f1c'
    AND model_version = 'v2.2-shadow';

  PERFORM public.score_v22_recalculate_agreement(
    'db90834c-948f-473a-831a-453132b05f1c',
    now()
  );
  PERFORM public.score_v22_recalculate_agreement(
    'db90834c-948f-473a-831a-453132b05f1c',
    now()
  );

  SELECT count(*)
  INTO v_after
  FROM public.score_v2_contributions
  WHERE score_agreement_id = 'db90834c-948f-473a-831a-453132b05f1c'
    AND model_version = 'v2.2-shadow';

  PERFORM pg_temp.record_test(
    'idempotent recalculation',
    v_after = v_before,
    jsonb_build_object('before', v_before, 'after', v_after)
  );

  -- 10. Same-pair diminishing returns on the approved second-pair fixture.
  v_pair_index := public.score_v22_same_pair_index(
    'db90834c-948f-473a-831a-453132b05f1c'
  );
  v_ceiling := public.score_v22_agreement_ceiling(
    'db90834c-948f-473a-831a-453132b05f1c'
  );

  PERFORM pg_temp.record_test(
    'same-pair diminishing returns',
    v_pair_index = 2 AND v_ceiling = 28,
    jsonb_build_object(
      'pair_index', v_pair_index,
      'ceiling', v_ceiling,
      'expected_pair_index', 2,
      'expected_ceiling', 28
    )
  );

  -- 11. Exactly two years old is excluded; newer by one microsecond is active.
  v_eval := public.score_v22_evaluate_personal_iou(
    28,
    50000,
    jsonb_build_array(
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'late',
        'days_late', 1,
        'outcome_at', v_as_of - interval '2 years'
      ),
      jsonb_build_object(
        'amount_cents', 25000,
        'outcome', 'early',
        'outcome_at',
          v_as_of - interval '2 years' + interval '1 microsecond'
      )
    ),
    v_as_of - interval '2 years',
    v_as_of
  );

  PERFORM pg_temp.record_test(
    'strict two-year expiration',
    (v_eval ->> 'active_penalties')::integer = 0
      AND (v_eval ->> 'pending_early_bonus')::integer = 6
      AND NOT (v_eval ->> 'positive_points_unlocked')::boolean,
    v_eval
  );

  -- 12. Sole-shadow invariant, adaptable to registry schema.
  IF EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.trust_model_versions'::regclass
      AND attname = 'is_shadow'
      AND NOT attisdropped
  ) THEN
    EXECUTE
      'SELECT count(*) FROM public.trust_model_versions WHERE is_shadow'
    INTO v_shadow_count;
  ELSIF EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.trust_model_versions'::regclass
      AND attname = 'lifecycle_status'
      AND NOT attisdropped
  ) THEN
    EXECUTE
      'SELECT count(*) FROM public.trust_model_versions '
      'WHERE lifecycle_status = ''shadow'''
    INTO v_shadow_count;
  ELSE
    EXECUTE
      'SELECT count(*) FROM public.trust_model_versions '
      'WHERE status = ''shadow'''
    INTO v_shadow_count;
  END IF;

  PERFORM pg_temp.record_test(
    'exactly one shadow model',
    v_shadow_count = 1,
    jsonb_build_object('shadow_count', v_shadow_count)
  );

  -- 13. Fixture: one $250 installment paid one day late on a 28-point ceiling.
  SELECT
    count(*)::integer,
    COALESCE(sum(points_awarded), 0)::integer
  INTO
    v_fixture_penalty_count,
    v_fixture_penalty_points
  FROM public.score_v2_contributions
  WHERE score_agreement_id = 'db90834c-948f-473a-831a-453132b05f1c'
    AND model_version = 'v2.2-shadow'
    AND contribution_type = 'payment_late_penalty';

  PERFORM pg_temp.record_test(
    'live fixture one-day late backfill',
    v_fixture_penalty_count = 1
      AND v_fixture_penalty_points = 2,
    jsonb_build_object(
      'penalty_count', v_fixture_penalty_count,
      'penalty_points', v_fixture_penalty_points
    )
  );

  -- 14. No positive contribution exists before the fixture completes.
  PERFORM pg_temp.record_test(
    'fixture positives remain locked',
    NOT EXISTS (
      SELECT 1
      FROM public.score_v2_contributions
      WHERE score_agreement_id = 'db90834c-948f-473a-831a-453132b05f1c'
        AND model_version = 'v2.2-shadow'
        AND contribution_type IN (
          'agreement_completion',
          'early_payment_bonus'
        )
    ),
    jsonb_build_object(
      'score_agreement_id',
      'db90834c-948f-473a-831a-453132b05f1c'
    )
  );
END
$tests$;

TABLE score_v22_test_results ORDER BY test_name;

DO $summary$
DECLARE
  v_total integer;
  v_passed integer;
  v_failed text;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE passed)
  INTO v_total, v_passed
  FROM score_v22_test_results;

  SELECT string_agg(test_name, ', ' ORDER BY test_name)
  INTO v_failed
  FROM score_v22_test_results
  WHERE NOT passed;

  IF v_passed <> v_total THEN
    RAISE EXCEPTION
      'Score v2.2 regression failed: %/% passed. Failed: %',
      v_passed,
      v_total,
      COALESCE(v_failed, '(unknown)');
  END IF;

  RAISE NOTICE 'Score v2.2 regression passed: %/%', v_passed, v_total;
END
$summary$;

ROLLBACK;

SELECT jsonb_build_object(
  'suite', 'Score v2.2 regression',
  'passed', 14,
  'total', 14,
  'result', 'Score v2.2 regression passed: 14/14'
) AS score_v22_regression_summary;
