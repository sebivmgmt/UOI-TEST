-- IOU Score v2 — Shadow Same-Pair Recalculation
-- Updates score_agreements shadow rows only.
-- No profile score changes.
-- No score_events changes.
-- No live scoring switch.
--
-- Purpose:
-- Apply same-pair diminishing returns to existing personal IOU shadow agreements
-- so repeated borrower/lender pairs cannot appear as full-value trust over and over.

with ranked as (
  select
    sa.id as score_agreement_id,
    sa.user_id,
    sa.counterparty_id,
    sa.amount_cents,
    sa.term_months,
    sa.frequency,
    sa.proof_tier,
    sa.verification_tier,
    sa.metadata,
    sa.status,

    row_number() over (
      partition by sa.user_id, sa.counterparty_id
      order by
        case
          when sa.status in ('active', 'completed') then 0
          else 1
        end,
        sa.activated_at nulls last,
        sa.created_at,
        sa.id
    ) as same_pair_index
  from public.score_agreements sa
  where sa.source_type = 'personal_iou'
    and sa.counterparty_id is not null
),
recalc as (
  select
    r.score_agreement_id,
    r.same_pair_index,
    public.score_v2_same_pair_multiplier(r.same_pair_index::integer) as same_pair_multiplier,
    public.score_v2_obligation_weight(
      'personal_iou',
      r.amount_cents,
      r.term_months,
      r.frequency,
      r.proof_tier,
      r.verification_tier,
      r.same_pair_index::integer,
      coalesce(r.metadata, '{}'::jsonb)
    ) as obligation_weight,

    case
      -- Cancelled/deleted/archived rows stay in shadow history, but should not count as active trust potential.
      when r.status in ('cancelled', 'archived') then 0

      else public.score_v2_score_ceiling(
        'personal_iou',
        r.amount_cents,
        r.term_months,
        r.frequency,
        r.proof_tier,
        r.verification_tier,
        r.same_pair_index::integer,
        coalesce(r.metadata, '{}'::jsonb)
      )
    end as score_ceiling
  from ranked r
)
update public.score_agreements sa
set
  same_pair_index = recalc.same_pair_index,
  same_pair_multiplier = recalc.same_pair_multiplier,
  obligation_weight = recalc.obligation_weight,
  score_ceiling = recalc.score_ceiling,
  metadata = coalesce(sa.metadata, '{}'::jsonb) || jsonb_build_object(
    'same_pair_recalculated', true,
    'same_pair_index', recalc.same_pair_index,
    'same_pair_multiplier', recalc.same_pair_multiplier,
    'inactive_shadow_ceiling_zeroed', sa.status in ('cancelled', 'archived')
  )
from recalc
where sa.id = recalc.score_agreement_id;