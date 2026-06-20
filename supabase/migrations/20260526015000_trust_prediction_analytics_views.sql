-- IOU Score v2 — Trust Prediction Analytics Views
-- Brain-of-the-brain aggregate analytics.
--
-- No profile score changes.
-- No score event changes.
-- No live scoring switch.
--
-- Purpose:
-- Let IOU study which prediction bands, relationship modes,
-- proof tiers, and same-pair patterns actually lead to good or bad outcomes.

create or replace view public.trust_prediction_outcome_summary_v as
select
  count(*) as total_outcomes,

  count(*) filter (where is_positive_outcome) as positive_outcomes,
  count(*) filter (where is_negative_outcome) as negative_outcomes,

  round(
    100.0 * count(*) filter (where is_positive_outcome) / nullif(count(*), 0),
    2
  ) as positive_rate_pct,

  round(
    100.0 * count(*) filter (where is_negative_outcome) / nullif(count(*), 0),
    2
  ) as negative_rate_pct,

  count(*) filter (where outcome_quality_label = 'better_than_expected') as better_than_expected_count,
  count(*) filter (where outcome_quality_label = 'as_expected_good') as as_expected_good_count,
  count(*) filter (where outcome_quality_label = 'weaker_than_expected') as weaker_than_expected_count,
  count(*) filter (where outcome_quality_label in ('failed', 'failed_or_uncertain')) as failed_or_uncertain_count

from public.trust_prediction_accuracy_v;


create or replace view public.trust_prediction_by_value_band_v as
select
  prediction_value_band,

  count(*) as total_outcomes,
  count(*) filter (where is_positive_outcome) as positive_outcomes,
  count(*) filter (where is_negative_outcome) as negative_outcomes,

  round(avg(score_ceiling)::numeric, 2) as avg_score_ceiling,
  round(avg(amount_dollars)::numeric, 2) as avg_amount_dollars,

  round(
    100.0 * count(*) filter (where is_positive_outcome) / nullif(count(*), 0),
    2
  ) as positive_rate_pct,

  round(
    100.0 * count(*) filter (where is_negative_outcome) / nullif(count(*), 0),
    2
  ) as negative_rate_pct

from public.trust_prediction_accuracy_v
group by prediction_value_band;


create or replace view public.trust_prediction_by_same_pair_band_v as
select
  same_pair_repetition_band,

  count(*) as total_outcomes,
  count(*) filter (where is_positive_outcome) as positive_outcomes,
  count(*) filter (where is_negative_outcome) as negative_outcomes,

  round(avg(same_pair_index)::numeric, 2) as avg_same_pair_index,
  round(avg(same_pair_multiplier)::numeric, 4) as avg_same_pair_multiplier,
  round(avg(score_ceiling)::numeric, 2) as avg_score_ceiling,

  round(
    100.0 * count(*) filter (where is_positive_outcome) / nullif(count(*), 0),
    2
  ) as positive_rate_pct,

  round(
    100.0 * count(*) filter (where is_negative_outcome) / nullif(count(*), 0),
    2
  ) as negative_rate_pct

from public.trust_prediction_accuracy_v
group by same_pair_repetition_band;


create or replace view public.trust_prediction_by_relationship_mode_v as
select
  relationship_mode,

  count(*) as total_outcomes,
  count(*) filter (where is_positive_outcome) as positive_outcomes,
  count(*) filter (where is_negative_outcome) as negative_outcomes,

  round(avg(score_ceiling)::numeric, 2) as avg_score_ceiling,
  round(avg(amount_dollars)::numeric, 2) as avg_amount_dollars,

  round(
    100.0 * count(*) filter (where is_positive_outcome) / nullif(count(*), 0),
    2
  ) as positive_rate_pct,

  round(
    100.0 * count(*) filter (where is_negative_outcome) / nullif(count(*), 0),
    2
  ) as negative_rate_pct

from public.trust_prediction_accuracy_v
group by relationship_mode;


create or replace view public.trust_prediction_by_proof_tier_v as
select
  proof_tier,
  verification_tier,

  count(*) as total_outcomes,
  count(*) filter (where is_positive_outcome) as positive_outcomes,
  count(*) filter (where is_negative_outcome) as negative_outcomes,

  round(avg(score_ceiling)::numeric, 2) as avg_score_ceiling,
  round(avg(amount_dollars)::numeric, 2) as avg_amount_dollars,

  round(
    100.0 * count(*) filter (where is_positive_outcome) / nullif(count(*), 0),
    2
  ) as positive_rate_pct,

  round(
    100.0 * count(*) filter (where is_negative_outcome) / nullif(count(*), 0),
    2
  ) as negative_rate_pct

from public.trust_prediction_accuracy_v
group by proof_tier, verification_tier;


create or replace view public.trust_prediction_by_source_type_v as
select
  source_type,

  count(*) as total_outcomes,
  count(*) filter (where is_positive_outcome) as positive_outcomes,
  count(*) filter (where is_negative_outcome) as negative_outcomes,

  round(avg(score_ceiling)::numeric, 2) as avg_score_ceiling,
  round(avg(amount_dollars)::numeric, 2) as avg_amount_dollars,

  round(
    100.0 * count(*) filter (where is_positive_outcome) / nullif(count(*), 0),
    2
  ) as positive_rate_pct,

  round(
    100.0 * count(*) filter (where is_negative_outcome) / nullif(count(*), 0),
    2
  ) as negative_rate_pct

from public.trust_prediction_accuracy_v
group by source_type;


create or replace view public.trust_prediction_learning_dashboard_v as
select
  'overall' as section,
  'all_outcomes' as label,
  total_outcomes,
  positive_outcomes,
  negative_outcomes,
  positive_rate_pct,
  negative_rate_pct,
  null::numeric as avg_score_ceiling,
  null::numeric as avg_amount_dollars
from public.trust_prediction_outcome_summary_v

union all

select
  'prediction_value_band' as section,
  prediction_value_band as label,
  total_outcomes,
  positive_outcomes,
  negative_outcomes,
  positive_rate_pct,
  negative_rate_pct,
  avg_score_ceiling,
  avg_amount_dollars
from public.trust_prediction_by_value_band_v

union all

select
  'same_pair_repetition_band' as section,
  same_pair_repetition_band as label,
  total_outcomes,
  positive_outcomes,
  negative_outcomes,
  positive_rate_pct,
  negative_rate_pct,
  avg_score_ceiling,
  null::numeric as avg_amount_dollars
from public.trust_prediction_by_same_pair_band_v

union all

select
  'relationship_mode' as section,
  relationship_mode as label,
  total_outcomes,
  positive_outcomes,
  negative_outcomes,
  positive_rate_pct,
  negative_rate_pct,
  avg_score_ceiling,
  avg_amount_dollars
from public.trust_prediction_by_relationship_mode_v

union all

select
  'source_type' as section,
  source_type as label,
  total_outcomes,
  positive_outcomes,
  negative_outcomes,
  positive_rate_pct,
  negative_rate_pct,
  avg_score_ceiling,
  avg_amount_dollars
from public.trust_prediction_by_source_type_v;