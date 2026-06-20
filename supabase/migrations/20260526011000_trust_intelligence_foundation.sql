-- IOU Score v2 — Trust Intelligence Foundation
-- Tesla-style learning loop foundation.
--
-- No profile score changes.
-- No score event changes.
-- No trigger switch.
--
-- Purpose:
-- Store model versions, score snapshots, and real-world outcomes
-- so IOU can compare predictions against actual trust behavior over time.

create table if not exists public.trust_model_versions (
  id uuid primary key default gen_random_uuid(),

  model_key text not null,
  version text not null,

  status text not null default 'draft' check (
    status in ('draft', 'shadow', 'active', 'deprecated', 'retired')
  ),

  description text null,

  config jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  activated_at timestamptz null,
  retired_at timestamptz null,

  unique (model_key, version)
);

create index if not exists trust_model_versions_key_status_idx
on public.trust_model_versions (model_key, status);


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


create table if not exists public.trust_score_snapshots (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null references public.profiles(id) on delete cascade,

  model_key text not null default 'iou_score',
  model_version text not null default 'v2.0-shadow',

  public_score integer not null,
  visible_trust integer not null,
  active_exposure_points integer not null default 0,

  trust_tier text not null,
  proof_depth integer not null default 0 check (proof_depth between 0 and 100),
  proof_depth_label text not null default 'very_thin',
  confidence_score integer not null default 0 check (confidence_score between 0 and 100),
  confidence_label text not null default 'thin',
  freshness_score integer not null default 100 check (freshness_score between 0 and 100),

  trend_30d text not null default 'stable',

  score_agreement_count integer not null default 0,
  active_score_agreement_count integer not null default 0,
  score_ceiling_total integer not null default 0,
  score_contributed_total integer not null default 0,

  risk_flag_count integer not null default 0,
  active_strike_count integer not null default 0,

  snapshot_reason text not null default 'manual_snapshot',

  summary jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);

create index if not exists trust_score_snapshots_user_created_idx
on public.trust_score_snapshots (user_id, created_at desc);

create index if not exists trust_score_snapshots_model_idx
on public.trust_score_snapshots (model_key, model_version);


create table if not exists public.trust_outcome_events (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null references public.profiles(id) on delete cascade,

  score_agreement_id uuid null references public.score_agreements(id) on delete set null,
  source_type text null,
  source_id uuid null,

  outcome_type text not null check (
    outcome_type in (
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late',
      'payment_reversed',
      'payment_disputed',
      'agreement_completed',
      'agreement_defaulted',
      'extension_requested',
      'extension_approved',
      'extension_denied',
      'rent_month_verified',
      'rent_month_missed',
      'phone_bill_verified',
      'phone_bill_missed',
      'strike_applied',
      'strike_expired',
      'recovery_progress',
      'lender_confirmed_fast',
      'lender_confirmed_slow',
      'lender_false_rejection',
      'risk_flag_created',
      'risk_flag_resolved'
    )
  ),

  outcome_at timestamptz not null default now(),

  amount_cents bigint null,
  days_early integer null,
  days_late integer null,

  proof_tier integer null check (proof_tier is null or proof_tier between 0 and 4),
  verification_tier integer null check (verification_tier is null or verification_tier between 0 and 4),

  related_snapshot_id uuid null references public.trust_score_snapshots(id) on delete set null,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);

create index if not exists trust_outcome_events_user_created_idx
on public.trust_outcome_events (user_id, created_at desc);

create index if not exists trust_outcome_events_type_idx
on public.trust_outcome_events (outcome_type);

create index if not exists trust_outcome_events_agreement_idx
on public.trust_outcome_events (score_agreement_id);


create or replace function public.create_trust_score_snapshot(
  p_user_id uuid,
  p_snapshot_reason text default 'manual_snapshot'
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_profile public.profiles%rowtype;
  v_snapshot_id uuid;

  v_score integer;
  v_exposure integer;
  v_freshness integer := 100;
  v_visible_trust integer;
  v_proof_depth integer := 0;
  v_confidence integer := 0;
  v_tier text;

  v_total_agreements integer := 0;
  v_active_agreements integer := 0;
  v_total_ceiling integer := 0;
  v_total_contributed integer := 0;
  v_risk_flags integer := 0;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  select *
  into v_profile
  from public.profiles
  where id = p_user_id;

  if not found then
    raise exception 'Profile not found for user %', p_user_id;
  end if;

  v_score := greatest(300, coalesce(v_profile.iou_score, 700));
  v_exposure := greatest(0, coalesce(v_profile.active_exposure_points, 0));

  select
    count(*),
    count(*) filter (where status in ('active', 'completed')),
    coalesce(sum(score_ceiling), 0),
    coalesce(sum(score_contributed), 0)
  into
    v_total_agreements,
    v_active_agreements,
    v_total_ceiling,
    v_total_contributed
  from public.score_agreements
  where user_id = p_user_id;

  select count(*)
  into v_risk_flags
  from public.score_risk_flags
  where user_id = p_user_id
    and is_active = true;

  -- Early shadow approximation:
  -- Proof depth grows with verified agreements and ceiling diversity.
  v_proof_depth := least(
    100,
    greatest(
      0,
      (v_active_agreements * 10)
      + least(40, floor(v_total_ceiling / 25)::integer)
    )
  );

  -- Confidence uses proof depth and freshness.
  v_confidence := least(
    100,
    greatest(
      0,
      round((v_proof_depth * 0.70) + (v_freshness * 0.30))::integer
    )
  );

  v_visible_trust := public.score_v2_visible_trust(v_score, v_exposure, v_freshness);

  v_tier := public.score_v2_trust_tier(
    v_score,
    greatest(0, floor(extract(epoch from (now() - coalesce(v_profile.created_at, now()))) / 86400)::integer),
    v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  insert into public.trust_score_snapshots (
    user_id,
    model_key,
    model_version,
    public_score,
    visible_trust,
    active_exposure_points,
    trust_tier,
    proof_depth,
    proof_depth_label,
    confidence_score,
    confidence_label,
    freshness_score,
    trend_30d,
    score_agreement_count,
    active_score_agreement_count,
    score_ceiling_total,
    score_contributed_total,
    risk_flag_count,
    active_strike_count,
    snapshot_reason,
    summary
  )
  values (
    p_user_id,
    'iou_score',
    'v2.0-shadow',
    v_score,
    v_visible_trust,
    v_exposure,
    v_tier,
    v_proof_depth,
    public.score_v2_proof_depth_label(v_proof_depth),
    v_confidence,
    public.score_v2_confidence_label(v_confidence),
    v_freshness,
    'stable',
    v_total_agreements,
    v_active_agreements,
    v_total_ceiling,
    v_total_contributed,
    v_risk_flags,
    coalesce(v_profile.strike_count, 0),
    coalesce(p_snapshot_reason, 'manual_snapshot'),
    jsonb_build_object(
      'shadow_mode', true,
      'raw_score_decay', false,
      'note', 'Snapshot generated for Score v2 trust intelligence learning loop.'
    )
  )
  returning id into v_snapshot_id;

  return v_snapshot_id;
end;
$function$;