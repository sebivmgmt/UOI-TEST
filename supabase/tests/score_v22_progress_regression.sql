-- ============================================================================
-- Score v2.2 approved DEV fixture: repayment-progress regression
-- Expected final result: passed = true.
-- ============================================================================

do $test$
declare
  v_progress jsonb;
begin
  v_progress := public.score_v22_pending_agreement_progress(
    'db90834c-948f-473a-831a-453132b05f1c',
    now()
  );

  if (v_progress ->> 'pair_index')::integer <> 2 then
    raise exception 'Expected pair_index 2, got %', v_progress ->> 'pair_index';
  end if;

  if (v_progress ->> 'agreement_ceiling')::integer <> 28 then
    raise exception
      'Expected agreement_ceiling 28, got %',
      v_progress ->> 'agreement_ceiling';
  end if;

  if (v_progress ->> 'principal_cents')::bigint <> 50000 then
    raise exception
      'Expected principal_cents 50000, got %',
      v_progress ->> 'principal_cents';
  end if;

  if (v_progress ->> 'paid_cents')::bigint <> 25000 then
    raise exception
      'Expected paid_cents 25000, got %',
      v_progress ->> 'paid_cents';
  end if;

  if (v_progress ->> 'paid_installment_count')::integer <> 1 then
    raise exception
      'Expected paid_installment_count 1, got %',
      v_progress ->> 'paid_installment_count';
  end if;

  if (v_progress ->> 'repayment_fraction')::numeric <> 0.5 then
    raise exception
      'Expected repayment_fraction 0.5, got %',
      v_progress ->> 'repayment_fraction';
  end if;

  if (v_progress ->> 'completion_progress_points')::integer <> 11 then
    raise exception
      'Expected completion_progress_points 11, got %',
      v_progress ->> 'completion_progress_points';
  end if;

  if (v_progress ->> 'completion_reward_max')::integer <> 22 then
    raise exception
      'Expected completion_reward_max 22, got %',
      v_progress ->> 'completion_reward_max';
  end if;

  if (v_progress ->> 'early_bonus_earned')::integer <> 0
     or (v_progress ->> 'early_bonus_max')::integer <> 6 then
    raise exception
      'Expected early bonus 0/6, got %/%',
      v_progress ->> 'early_bonus_earned',
      v_progress ->> 'early_bonus_max';
  end if;

  if (v_progress ->> 'active_penalties')::integer <> 2 then
    raise exception
      'Expected active_penalties 2, got %',
      v_progress ->> 'active_penalties';
  end if;

  if (v_progress ->> 'projected_net_contribution')::integer <> 9 then
    raise exception
      'Expected projected_net_contribution 9, got %',
      v_progress ->> 'projected_net_contribution';
  end if;

  if (v_progress ->> 'current_public_score_effect')::integer <> -2 then
    raise exception
      'Expected current_public_score_effect -2, got %',
      v_progress ->> 'current_public_score_effect';
  end if;

  if (v_progress ->> 'positive_points_unlocked')::boolean then
    raise exception 'Positive points must remain locked before completion';
  end if;
end
$test$;

select jsonb_build_object(
  'suite', 'Score v2.2 repayment-progress regression',
  'passed', true,
  'fixture', jsonb_build_object(
    'score_agreement_id', 'db90834c-948f-473a-831a-453132b05f1c',
    'expected_paid_cents', 25000,
    'expected_completion_progress', '11/22',
    'expected_early_bonus', '0/6',
    'expected_active_penalties', 2,
    'expected_projected_net', 9,
    'expected_public_score_effect', -2
  ),
  'progress',
    public.score_v22_pending_agreement_progress(
      'db90834c-948f-473a-831a-453132b05f1c',
      now()
    )
) as score_v22_progress_regression_summary;
