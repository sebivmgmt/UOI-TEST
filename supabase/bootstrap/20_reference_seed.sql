-- Reference seed data for DEV bootstrap.
--
-- Contains only static required seed data that would otherwise be skipped
-- when migrations 20260524000000 through 20260530001000 are marked applied
-- rather than re-executed.
--
-- Source: 20260526011000_trust_intelligence_foundation.sql
-- Excluded: IOU backfills, score-agreement backfills, profile rows,
--           bank rows, Plaid tokens, payment rows, receipt rows, test data.

insert into public.trust_model_versions (
  model_key,
  version,
  status,
  description,
  config
)
values
  (
    'iou_score',
    'v2.0-shadow',
    'shadow',
    'IOU Score v2 shadow model: weighted obligations, rent market adjustment, proof freshness, same-pair diminishing returns, relationship modes.',
    jsonb_build_object(
      'range', jsonb_build_object('min', 300, 'max', 1400, 'start', 700),
      'raw_score_decay', false,
      'proof_freshness_affects_visible_trust', true,
      'rent_market_adjusted', true,
      'same_pair_diminishing_returns', true,
      'relationship_modes', true
    )
  ),
  (
    'rent_score',
    'v1.0-shadow',
    'shadow',
    'Rent scoring model using local market adjustment, proof tier, verification tier, stability, bedrooms, and rent stream duration.',
    jsonb_build_object(
      'uses_market_median_rent', true,
      'uses_rent_to_market_ratio', true,
      'tier_4_rail_weighted_highest', true
    )
  ),
  (
    'risk_signal',
    'v0.1-shadow',
    'shadow',
    'Initial internal risk-signal placeholder for same-pair concentration, tiny IOU farming, self-payment, and stale proof.',
    jsonb_build_object(
      'publicly_visible', false,
      'mutates_raw_score', false
    )
  )
on conflict (model_key, version)
do update set
  status = excluded.status,
  description = excluded.description,
  config = excluded.config;
