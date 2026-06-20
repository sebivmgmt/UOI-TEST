-- IOU Score v2 — Trust Prediction Accuracy View
-- Brain-of-the-brain analytics layer.
--
-- No profile score changes.
-- No score event changes.
-- No live scoring switch.
--
-- Purpose:
-- Compare Score v2 shadow predictions against real outcomes.

create or replace view public.trust_prediction_accuracy_v as
select
  toe.id as outcome_event_id,
  toe.created_at as outcome_logged_at,
  toe.outcome_at,

  toe.user_id,
  borrower.email as user_email,

  toe.score_agreement_id,
  sa.source_type,
  sa.source_id,
  sa.status as agreement_status,

  sa.amount_cents,
  round((sa.amount_cents::numeric / 100.0), 2) as amount_dollars,

  sa.term_months,
  sa.frequency,

  sa.proof_tier,
  sa.verification_tier,
  coalesce(
  toe.metadata->>'relationship_mode',
  public.get_relationship_mode(sa.user_id, sa.counterparty_id)
) as relationship_mode,
  sa.same_pair_index,
  sa.same_pair_multiplier,

  sa.obligation_weight,
  sa.score_ceiling,
  sa.score_contributed,

  sa.counterparty_id,
  counterparty.email as counterparty_email,

  toe.outcome_type,
  toe.amount_cents as outcome_amount_cents,
  round((toe.amount_cents::numeric / 100.0), 2) as outcome_amount_dollars,
  toe.days_early,
  toe.days_late,

  case
    when toe.outcome_type in (
      'payment_paid_early',
      'payment_paid_on_time',
      'agreement_completed',
      'rent_month_verified',
      'phone_bill_verified',
      'recovery_progress',
      'lender_confirmed_fast'
    ) then true
    else false
  end as is_positive_outcome,

  case
    when toe.outcome_type in (
      'payment_paid_late',
      'payment_reversed',
      'payment_disputed',
      'agreement_defaulted',
      'rent_month_missed',
      'phone_bill_missed',
      'strike_applied',
      'lender_false_rejection'
    ) then true
    else false
  end as is_negative_outcome,

  case
    when toe.outcome_type = 'payment_paid_early' then 'better_than_expected'
    when toe.outcome_type = 'payment_paid_on_time' then 'as_expected_good'
    when toe.outcome_type = 'agreement_completed' then 'as_expected_good'
    when toe.outcome_type = 'payment_paid_late' then 'weaker_than_expected'
    when toe.outcome_type = 'agreement_defaulted' then 'failed'
    when toe.outcome_type = 'payment_reversed' then 'failed_or_uncertain'
    when toe.outcome_type = 'payment_disputed' then 'uncertain'
    else 'informational'
  end as outcome_quality_label,

  case
    when sa.score_ceiling >= 100 then 'high_predicted_value'
    when sa.score_ceiling >= 40 then 'medium_predicted_value'
    when sa.score_ceiling >= 10 then 'low_predicted_value'
    else 'tiny_predicted_value'
  end as prediction_value_band,

  case
    when sa.same_pair_index >= 6 then 'high_same_pair_repetition'
    when sa.same_pair_index >= 3 then 'medium_same_pair_repetition'
    else 'low_same_pair_repetition'
  end as same_pair_repetition_band,

  toe.metadata as outcome_metadata,
  sa.metadata as agreement_metadata

from public.trust_outcome_events toe
left join public.score_agreements sa on sa.id = toe.score_agreement_id
left join public.profiles borrower on borrower.id = toe.user_id
left join public.profiles counterparty on counterparty.id = sa.counterparty_id;