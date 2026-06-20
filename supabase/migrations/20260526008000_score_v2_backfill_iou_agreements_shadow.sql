-- IOU Score v2 — Phase C
-- Shadow-mode backfill of existing IOUs into score_agreements.
--
-- This does NOT change profiles.iou_score.
-- This does NOT change score_events.
-- This does NOT replace live scoring.
-- It only creates Score v2 agreement records so we can audit v2 math safely.

create unique index if not exists score_agreements_unique_source_user
on public.score_agreements (source_type, source_id, user_id)
where source_id is not null;

insert into public.score_agreements (
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
select
  i.borrower_id as user_id,
  'personal_iou' as source_type,
  i.id as source_id,
  i.lender_id as counterparty_id,
  i.principal_cents as amount_cents,
  i.term_months,
  i.frequency,

  case
    when i.deleted_at is not null then 'cancelled'
    when i.archived_at is not null then 'archived'
    when i.status = 'paid' then 'completed'
    when i.status in ('open', 'late') then 'active'
    when i.status = 'draft' then 'draft'
    else 'active'
  end as status,

  -- Shadow defaults:
  -- Tier 1 = app-created/manual agreement.
  -- Later: payment rail / bank proof / verified counterparty can raise this.
  1 as proof_tier,
  1 as verification_tier,

  public.score_v2_obligation_weight(
    'personal_iou',
    i.principal_cents,
    i.term_months,
    i.frequency,
    1,
    1,
    1,
    jsonb_build_object(
      'shadow_backfill', true,
      'source_table', 'ious'
    )
  ) as obligation_weight,

  public.score_v2_score_ceiling(
    'personal_iou',
    i.principal_cents,
    i.term_months,
    i.frequency,
    1,
    1,
    1,
    jsonb_build_object(
      'shadow_backfill', true,
      'source_table', 'ious'
    )
  ) as score_ceiling,

  0 as score_contributed,

  1 as same_pair_index,
  public.score_v2_same_pair_multiplier(1) as same_pair_multiplier,

  i.activated_at,
  case when i.status = 'paid' then now() else null end as completed_at,

  jsonb_build_object(
    'shadow_backfill', true,
    'source_table', 'ious',
    'legacy_status', i.status,
    'title', i.title,
    'apr_bps', i.apr_bps,
    'created_at', i.created_at,
    'archived_at', i.archived_at,
    'deleted_at', i.deleted_at
  ) as metadata
from public.ious i
where i.borrower_id is not null
  and i.lender_id is not null
on conflict (source_type, source_id, user_id)
where source_id is not null
do update set
  counterparty_id = excluded.counterparty_id,
  amount_cents = excluded.amount_cents,
  term_months = excluded.term_months,
  frequency = excluded.frequency,
  status = excluded.status,
  proof_tier = excluded.proof_tier,
  verification_tier = excluded.verification_tier,
  obligation_weight = excluded.obligation_weight,
  score_ceiling = excluded.score_ceiling,
  same_pair_index = excluded.same_pair_index,
  same_pair_multiplier = excluded.same_pair_multiplier,
  activated_at = excluded.activated_at,
  completed_at = excluded.completed_at,
  metadata = excluded.metadata;