-- IOU Score v2 — Trust Report Shadow View
-- Read-only Trust Report foundation.
--
-- No profile score changes.
-- No score event changes.
-- No live scoring switch.
--
-- Purpose:
-- Provide one clean view for the future Trust Report screen:
-- score, visible trust, tier, proof depth, confidence, active agreements,
-- risk flags, and private coaching context.

create or replace view public.trust_report_shadow_v as
with latest_snapshot as (
  select distinct on (s.user_id)
    s.*
  from public.trust_score_snapshots s
  order by s.user_id, s.created_at desc
),
risk_summary as (
  select
    rf.user_id,
    count(*) filter (where rf.is_active = true) as active_risk_flag_count,
    count(*) filter (where rf.is_active = true and rf.severity = 'low') as low_risk_flag_count,
    count(*) filter (where rf.is_active = true and rf.severity = 'medium') as medium_risk_flag_count,
    count(*) filter (where rf.is_active = true and rf.severity = 'high') as high_risk_flag_count,
    count(*) filter (where rf.is_active = true and rf.severity = 'critical') as critical_risk_flag_count,
    jsonb_agg(
      jsonb_build_object(
        'flag_type', rf.flag_type,
        'severity', rf.severity,
        'description', rf.description,
        'metadata', rf.metadata,
        'created_at', rf.created_at
      )
      order by rf.created_at desc
    ) filter (where rf.is_active = true) as active_risk_flags
  from public.score_risk_flags rf
  group by rf.user_id
),
agreement_summary as (
  select
    sa.user_id,

    count(*) as total_score_agreements,

    count(*) filter (
      where sa.status in ('active', 'completed')
        and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    ) as active_score_affecting_agreements,

    count(*) filter (
      where sa.status in ('active', 'completed')
        and not public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    ) as active_no_score_agreements,

    coalesce(sum(sa.score_ceiling) filter (
      where sa.status in ('active', 'completed')
        and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    ), 0) as active_score_ceiling_total,

    coalesce(sum(sa.score_contributed) filter (
      where sa.status in ('active', 'completed')
        and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    ), 0) as active_score_contributed_total,

    count(distinct sa.counterparty_id) filter (
      where sa.status in ('active', 'completed')
        and sa.counterparty_id is not null
        and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    ) as active_score_affecting_counterparties,

    max(sa.same_pair_index) filter (
      where sa.status in ('active', 'completed')
    ) as max_same_pair_index

  from public.score_agreements sa
  group by sa.user_id
),
outcome_summary as (
  select
    toe.user_id,
    count(*) as total_outcomes,
    count(*) filter (
      where toe.outcome_type in (
        'payment_paid_early',
        'payment_paid_on_time',
        'agreement_completed',
        'rent_month_verified',
        'phone_bill_verified',
        'recovery_progress',
        'lender_confirmed_fast'
      )
    ) as positive_outcomes,
    count(*) filter (
      where toe.outcome_type in (
        'payment_paid_late',
        'payment_reversed',
        'payment_disputed',
        'agreement_defaulted',
        'rent_month_missed',
        'phone_bill_missed',
        'strike_applied',
        'lender_false_rejection'
      )
    ) as negative_outcomes
  from public.trust_outcome_events toe
  group by toe.user_id
)
select
  p.id as user_id,
  p.email,

  coalesce(s.public_score, coalesce(p.iou_score, 700)) as public_score,
  coalesce(
    s.visible_trust,
    public.score_v2_visible_trust(
      coalesce(p.iou_score, 700),
      coalesce(p.active_exposure_points, 0),
      100
    )
  ) as visible_trust,

  coalesce(s.active_exposure_points, coalesce(p.active_exposure_points, 0)) as active_exposure_points,

  coalesce(
    s.trust_tier,
    public.score_v2_trust_tier(
      coalesce(p.iou_score, 700),
      greatest(0, floor(extract(epoch from (now() - coalesce(p.created_at, now()))) / 86400)::integer),
      0,
      coalesce(p.strike_count, 0) > 0,
      false
    )
  ) as trust_tier,

  coalesce(s.proof_depth, 0) as proof_depth,
  coalesce(s.proof_depth_label, public.score_v2_proof_depth_label(0)) as proof_depth_label,

  coalesce(s.confidence_score, 0) as confidence_score,
  coalesce(s.confidence_label, public.score_v2_confidence_label(0)) as confidence_label,

  coalesce(s.freshness_score, 100) as freshness_score,
  coalesce(s.trend_30d, 'stable') as public_trend_30d,

  coalesce(a.total_score_agreements, 0) as total_score_agreements,
  coalesce(a.active_score_affecting_agreements, 0) as active_score_affecting_agreements,
  coalesce(a.active_no_score_agreements, 0) as active_no_score_agreements,
  coalesce(a.active_score_ceiling_total, 0) as active_score_ceiling_total,
  coalesce(a.active_score_contributed_total, 0) as active_score_contributed_total,
  coalesce(a.active_score_affecting_counterparties, 0) as active_score_affecting_counterparties,
  coalesce(a.max_same_pair_index, 0) as max_same_pair_index,

  coalesce(r.active_risk_flag_count, 0) as active_risk_flag_count,
  coalesce(r.low_risk_flag_count, 0) as low_risk_flag_count,
  coalesce(r.medium_risk_flag_count, 0) as medium_risk_flag_count,
  coalesce(r.high_risk_flag_count, 0) as high_risk_flag_count,
  coalesce(r.critical_risk_flag_count, 0) as critical_risk_flag_count,
  coalesce(r.active_risk_flags, '[]'::jsonb) as active_risk_flags,

  coalesce(o.total_outcomes, 0) as total_outcomes,
  coalesce(o.positive_outcomes, 0) as positive_outcomes,
  coalesce(o.negative_outcomes, 0) as negative_outcomes,

  case
    when coalesce(r.active_risk_flag_count, 0) = 0 then 'No active private risk flags.'
    when coalesce(r.high_risk_flag_count, 0) > 0 or coalesce(r.critical_risk_flag_count, 0) > 0 then 'Private review recommended before expanding trust.'
    when coalesce(r.medium_risk_flag_count, 0) > 0 then 'Trust activity has concentration or pattern warnings.'
    else 'Minor private trust notes available.'
  end as private_risk_summary,

  case
    when coalesce(s.proof_depth, 0) < 35 then 'Build proof depth by completing verified obligations or adding rent/phone bill verification.'
    when coalesce(a.active_score_affecting_counterparties, 0) <= 1 and coalesce(a.active_score_affecting_agreements, 0) >= 3 then 'Most trust activity is concentrated with one counterparty. More verified counterparties would improve trust depth.'
    when coalesce(s.freshness_score, 100) < 70 then 'Proof is getting stale. Refresh trust with recent verified activity.'
    else 'Trust profile is developing cleanly.'
  end as sylienn_private_note,

  s.created_at as latest_snapshot_at

from public.profiles p
left join latest_snapshot s on s.user_id = p.id
left join risk_summary r on r.user_id = p.id
left join agreement_summary a on a.user_id = p.id
left join outcome_summary o on o.user_id = p.id;