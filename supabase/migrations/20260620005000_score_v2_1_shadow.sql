-- Migration B: Score v2.1 shadow model
-- Creates v2.1 ceiling/multiplier/index functions, stable pair-index
-- calculation, version-aware outcome dispatcher, deprecates v2.0-shadow,
-- enforces one shadow model per key, registers v2.1-shadow, backfills
-- existing agreements, and updates snapshot proof-depth to use v2.1 ceilings.
-- LIVE untouched.

begin;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. V2.1 personal-IOU ceiling function
-- Segments 1–5 are byte-for-byte identical to v2.0.
-- Segment 6: slope 48 (continuous at $2,000 boundary; v2.0 had slope 24).
-- Segment 7: log anchored at $2,000 boundary, hard cap 200.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.score_v2_personal_iou_ceiling_v21(
  p_amount_cents bigint
)
returns integer
language plpgsql
immutable
security definer
set search_path = public, pg_temp
as $$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric);
begin
  return case
    -- Segment 1: $0–$49.99 (cents < 5000)
    when v_amount < 5000 then
      greatest(1, round(v_amount / 2000.0)::integer)

    -- Segment 2: $50–$99.99 (cents < 10000)
    when v_amount < 10000 then
      round(3 + ((v_amount - 5000) / 5000.0) * 3)::integer

    -- Segment 3: $100–$249.99 (cents < 25000)
    when v_amount < 25000 then
      round(7 + ((v_amount - 10000) / 15000.0) * 8)::integer

    -- Segment 4: $250–$499.99 (cents < 50000)
    when v_amount < 50000 then
      round(16 + ((v_amount - 25000) / 25000.0) * 14)::integer

    -- Segment 5: $500–$999.99 (cents < 100000)
    when v_amount < 100000 then
      round(35 + ((v_amount - 50000) / 50000.0) * 20)::integer

    -- Segment 6: $1,000–$1,999.99 (cents < 200000)
    -- Slope 48 → continuous with segment 7 at $2,000 (both yield 104).
    when v_amount < 200000 then
      round(56 + ((v_amount - 100000) / 100000.0) * 48)::integer

    -- Segment 7: $2,000+ (log curve anchored at $2,000; hard cap 200)
    -- At v_amount=200000: 104 + ln(0+1)*105 = 104 (continuous).
    -- At v_amount=500000: 104 + ln(2.5)*105 ≈ 200.
    else
      least(200,
        round(104 + ln((v_amount - 200000) / 200000.0 + 1) * 105)::integer
      )
  end;
end;
$$;

revoke all on function public.score_v2_personal_iou_ceiling_v21(bigint) from public, anon, authenticated;
grant execute on function public.score_v2_personal_iou_ceiling_v21(bigint) to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. V2.1 same-pair multiplier
-- Index 6 = 0.20, index 7 = 0.10, index 8+ = 0.00 (eliminates permanent
-- repeat points; any base × 0.00 = 0).
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.score_v2_same_pair_multiplier_v21(
  p_index integer
)
returns numeric
language plpgsql
immutable
security definer
set search_path = public, pg_temp
as $$
declare
  v_index integer := greatest(1, coalesce(p_index, 1));
begin
  if v_index = 1 then return 1.00; end if;
  if v_index = 2 then return 0.80; end if;
  if v_index = 3 then return 0.64; end if;
  if v_index = 4 then return 0.50; end if;
  if v_index = 5 then return 0.35; end if;
  if v_index = 6 then return 0.20; end if;
  if v_index = 7 then return 0.10; end if;
  return 0.00; -- index 8+
end;
$$;

revoke all on function public.score_v2_same_pair_multiplier_v21(integer) from public, anon, authenticated;
grant execute on function public.score_v2_same_pair_multiplier_v21(integer) to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Stable activation-relative pair index (v2.1)
-- The pair index for agreement X = 1 + count of qualifying prior agreements
-- (same user/counterparty, personal_iou, active/completed, activated within
-- the 2 years immediately preceding X's activated_at).
-- This is computed relative to X's own activated_at and does not change as
-- calendar time advances.  An agreement with activated_at IS NULL returns 1.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.score_v2_activation_pair_index_v21(
  p_score_agreement_id uuid
)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_agr  public.score_agreements%rowtype;
  v_index integer;
begin
  select * into v_agr
  from public.score_agreements
  where id = p_score_agreement_id;

  if not found or v_agr.activated_at is null then
    return 1;
  end if;

  -- Count prior qualifying agreements within the 2-year lookback
  -- that precede this agreement in deterministic activation order.
  select (1 + count(*))::integer
  into v_index
  from public.score_agreements sa
  where sa.user_id         = v_agr.user_id
    and sa.counterparty_id = v_agr.counterparty_id
    and sa.source_type     = 'personal_iou'
    and sa.id              <> p_score_agreement_id
    and sa.activated_at    is not null
    and sa.status          in ('active', 'completed')
    and sa.activated_at    > v_agr.activated_at - interval '2 years'
    and (
      sa.activated_at < v_agr.activated_at
      or (
        sa.activated_at = v_agr.activated_at
        and (sa.created_at::text, sa.id::text)
            < (v_agr.created_at::text, v_agr.id::text)
      )
    );

  return coalesce(v_index, 1);
end;
$$;

revoke all on function public.score_v2_activation_pair_index_v21(uuid) from public, anon, authenticated;
grant execute on function public.score_v2_activation_pair_index_v21(uuid) to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. V2.1 model-specific ceiling for an agreement
-- Uses the stable activation-relative pair index unless one is supplied.
-- Returns 0 for any source_type other than personal_iou.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.score_v2_ceiling_for_agreement_v21(
  p_score_agreement_id uuid,
  p_pair_index         integer default null
)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_agr        public.score_agreements%rowtype;
  v_pair_index integer;
  v_base       integer;
  v_mult       numeric;
begin
  select * into v_agr
  from public.score_agreements
  where id = p_score_agreement_id;

  if not found then return 0; end if;

  -- v2.1 only models personal_iou with the new curve
  if v_agr.source_type <> 'personal_iou' then return 0; end if;

  -- Cancelled agreements earn zero ceiling
  if v_agr.status = 'cancelled' then return 0; end if;

  v_pair_index := coalesce(
    p_pair_index,
    public.score_v2_activation_pair_index_v21(p_score_agreement_id)
  );

  v_base := public.score_v2_personal_iou_ceiling_v21(v_agr.amount_cents);
  v_mult := public.score_v2_same_pair_multiplier_v21(v_pair_index);

  return greatest(0, round(v_base::numeric * v_mult)::integer);
end;
$$;

revoke all on function public.score_v2_ceiling_for_agreement_v21(uuid, integer) from public, anon, authenticated;
grant execute on function public.score_v2_ceiling_for_agreement_v21(uuid, integer) to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. V2.1 agreement contribution calculator
-- Mirrors the structure of score_v2_recalculate_agreement_internal but uses
-- v2.1 ceiling/multiplier functions and writes under 'v2.1-shadow'.
-- payment_performance_share = 0.20 (20%).
-- ON CONFLICT DO NOTHING makes backfill and re-runs idempotent.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.score_v2_recalculate_agreement_v21(
  p_score_agreement_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_agreement  public.score_agreements%rowtype;
  v_model      public.trust_model_versions%rowtype;
  v_config     jsonb;
  v_pair_index integer;
  v_v21_ceiling integer;
  v_pp_share   numeric;
  v_pp_cap     integer;
  v_comp_cap   integer;
  v_pp_event   public.trust_outcome_events%rowtype;
  v_comp_event public.trust_outcome_events%rowtype;
  v_pp_found   boolean := false;
  v_comp_found boolean := false;
  v_pp_points  integer := 0;
  v_comp_points integer := 0;
  v_sum        integer := 0;
  c_version    constant text := 'v2.1-shadow';
begin
  -- Lock the agreement
  select * into v_agreement
  from public.score_agreements
  where id = p_score_agreement_id
  for update;

  if not found then
    raise exception 'Score agreement not found: %', p_score_agreement_id;
  end if;

  -- v2.1 only handles personal_iou
  if v_agreement.source_type <> 'personal_iou' then
    return jsonb_build_object(
      'ok',          false,
      'reason',      'source_type not supported by v2.1',
      'source_type', v_agreement.source_type
    );
  end if;

  -- Load v2.1-shadow model config
  select * into v_model
  from public.trust_model_versions
  where model_key = 'iou_score'
    and version   = c_version;

  if not found then
    raise exception 'Model version not found: iou_score/%', c_version;
  end if;

  v_config   := v_model.config;
  v_pp_share := coalesce(
    (v_config -> 'personal_iou' ->> 'payment_performance_share')::numeric,
    0.20
  );

  -- Stable activation-relative pair index
  v_pair_index  := public.score_v2_activation_pair_index_v21(p_score_agreement_id);
  v_v21_ceiling := public.score_v2_ceiling_for_agreement_v21(p_score_agreement_id, v_pair_index);

  -- Cancelled or index-8+ (ceiling=0): no contributions
  if v_v21_ceiling = 0 then
    return jsonb_build_object(
      'ok',                      true,
      'score_agreement_id',      p_score_agreement_id,
      'model_version',           c_version,
      'v2.1-shadow.pair_index',  v_pair_index,
      'v2.1-shadow.ceiling',     0,
      'reason',                  'ceiling is zero'
    );
  end if;

  -- PP cap: 20% of ceiling, minimum 1
  v_pp_cap  := least(v_v21_ceiling,
                 greatest(1, floor(v_v21_ceiling::numeric * v_pp_share)::integer));
  v_comp_cap := v_v21_ceiling - v_pp_cap;

  -- Earliest payment outcome
  select * into v_pp_event
  from public.trust_outcome_events
  where score_agreement_id = p_score_agreement_id
    and outcome_type in (
      'payment_paid_early', 'payment_paid_on_time', 'payment_paid_late'
    )
  order by outcome_at asc
  limit 1;
  v_pp_found := found;

  if v_pp_found then
    v_pp_points := case
      when v_pp_event.outcome_type in ('payment_paid_early', 'payment_paid_on_time')
        then v_pp_cap
      else 0
    end;

    insert into public.score_v2_contributions (
      user_id, outcome_event_id, score_agreement_id,
      contribution_type, source_outcome_type,
      model_key, model_version,
      points_awarded, points_cap,
      impact_direction, metadata
    ) values (
      v_agreement.user_id,
      v_pp_event.id,
      p_score_agreement_id,
      'payment_performance',
      v_pp_event.outcome_type,
      v_model.model_key,
      c_version,
      v_pp_points,
      v_pp_cap,
      'reward',
      jsonb_build_object(
        'v2.1-shadow.same_pair_index',      v_pair_index,
        'v2.1-shadow.same_pair_multiplier', public.score_v2_same_pair_multiplier_v21(v_pair_index),
        'v2.1-shadow.score_ceiling',        v_v21_ceiling,
        'ceiling_at_calculation',           v_v21_ceiling
      )
    )
    on conflict do nothing;
  end if;

  -- Earliest agreement_completed outcome
  select * into v_comp_event
  from public.trust_outcome_events
  where score_agreement_id = p_score_agreement_id
    and outcome_type = 'agreement_completed'
  order by outcome_at asc
  limit 1;
  v_comp_found := found;

  if v_comp_found then
    v_comp_points := v_comp_cap;

    insert into public.score_v2_contributions (
      user_id, outcome_event_id, score_agreement_id,
      contribution_type, source_outcome_type,
      model_key, model_version,
      points_awarded, points_cap,
      impact_direction, metadata
    ) values (
      v_agreement.user_id,
      v_comp_event.id,
      p_score_agreement_id,
      'agreement_completion',
      v_comp_event.outcome_type,
      v_model.model_key,
      c_version,
      v_comp_points,
      v_comp_cap,
      'reward',
      jsonb_build_object(
        'v2.1-shadow.same_pair_index',      v_pair_index,
        'v2.1-shadow.same_pair_multiplier', public.score_v2_same_pair_multiplier_v21(v_pair_index),
        'v2.1-shadow.score_ceiling',        v_v21_ceiling,
        'ceiling_at_calculation',           v_v21_ceiling
      )
    )
    on conflict do nothing;
  end if;

  -- Total contributed under v2.1 for this agreement
  select coalesce(sum(points_awarded), 0)::integer
  into v_sum
  from public.score_v2_contributions
  where score_agreement_id = p_score_agreement_id
    and model_version      = c_version;

  return jsonb_build_object(
    'ok',                           true,
    'score_agreement_id',           p_score_agreement_id,
    'model_version',                c_version,
    'v2.1-shadow.pair_index',       v_pair_index,
    'v2.1-shadow.ceiling',          v_v21_ceiling,
    'payment_performance_cap',      v_pp_cap,
    'completion_cap',               v_comp_cap,
    'payment_performance_points',   v_pp_points,
    'completion_points',            v_comp_points,
    'total_v21_contributed',        least(v_v21_ceiling, v_sum)
  );
end;
$$;

revoke all on function public.score_v2_recalculate_agreement_v21(uuid) from public, anon, authenticated;
grant execute on function public.score_v2_recalculate_agreement_v21(uuid) to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. Version-aware outcome trigger dispatcher
-- Resolves the single current shadow model and routes to the correct
-- version-specific calculator.  Fail-open: a warning is raised on error so
-- the trust_outcome_events INSERT always succeeds.
-- After v2.0 is deprecated, no v2.0 contribution rows will be created.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.trg_score_v2_shadow_on_outcome()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_shadow_version text;
begin
  -- Resolve exactly one current shadow model
  select version into v_shadow_version
  from public.trust_model_versions
  where model_key = 'iou_score'
    and status    = 'shadow';

  if v_shadow_version is null then
    return new; -- no shadow model registered
  end if;

  if new.score_agreement_id is null then
    return new;
  end if;

  begin
    case v_shadow_version
      when 'v2.1-shadow' then
        perform public.score_v2_recalculate_agreement_v21(new.score_agreement_id);
      when 'v2.0-shadow' then
        perform public.score_v2_recalculate_agreement_internal(
          new.score_agreement_id, v_shadow_version
        );
      else
        raise warning
          'trg_score_v2_shadow_on_outcome: no dispatcher for model %; outcome event %',
          v_shadow_version, new.id;
    end case;
  exception
    when others then
      raise warning
        'Score v2 shadow calculation failed for outcome event %: %',
        new.id, sqlerrm;
  end;

  return new;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. Deprecate v2.0-shadow
-- Must happen BEFORE the unique partial index is created to avoid conflict.
-- ═══════════════════════════════════════════════════════════════════════════
update public.trust_model_versions
set    status = 'deprecated'
where  model_key = 'iou_score'
  and  version   = 'v2.0-shadow';

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. Enforce exactly one shadow model per model key
-- Created after deprecating v2.0 so no existing row violates it.
-- ═══════════════════════════════════════════════════════════════════════════
create unique index if not exists trust_model_versions_one_shadow_per_key
  on public.trust_model_versions (model_key)
  where status = 'shadow';

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. Register v2.1-shadow
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.trust_model_versions (
  model_key, version, status, description, config, activated_at
) values (
  'iou_score',
  'v2.1-shadow',
  'shadow',
  'Score v2.1: rolling 2-year evidence window, corrected high-end personal-IOU curve, activation-relative pair index, zero floor at pair index 8+',
  jsonb_build_object(
    'base_score',              700,
    'evidence_window_years',   2,
    'evidence_boundary',       'strict_greater_than',
    'personal_iou', jsonb_build_object(
      'maximum_ceiling',                200,
      'payment_performance_share',      0.20,
      'early_fraction',                 1.00,
      'on_time_fraction',               1.00,
      'late_fraction',                  0.00,
      'completion_uses_remaining_ceiling', true,
      'same_pair_window_years',         2,
      'same_pair_multipliers', jsonb_build_object(
        '1',     1.00,
        '2',     0.80,
        '3',     0.64,
        '4',     0.50,
        '5',     0.35,
        '6',     0.20,
        '7',     0.10,
        '8_plus', 0.00
      )
    ),
    'negative_outcomes_enabled', false,
    'shadow_mode',             true
  ),
  now()
);

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. Backfill v2.1 contribution rows for existing agreements
-- Only processes personal_iou agreements that have at least one outcome event.
-- ON CONFLICT DO NOTHING inside the calculator makes this idempotent.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  v_sa_id uuid;
begin
  for v_sa_id in
    select distinct sa.id
    from public.score_agreements sa
    where sa.source_type = 'personal_iou'
      and exists (
        select 1
        from public.trust_outcome_events toe
        where toe.score_agreement_id = sa.id
      )
    order by sa.id
  loop
    perform public.score_v2_recalculate_agreement_v21(v_sa_id);
  end loop;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 11. Update create_trust_score_snapshot for v2.1 proof-depth ceilings
-- When the resolved shadow model is v2.1-shadow, qualifying agreement ceilings
-- are computed from score_v2_ceiling_for_agreement_v21 (not the stale
-- score_agreements.score_ceiling compatibility field).
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.create_trust_score_snapshot(
  p_user_id        uuid,
  p_snapshot_reason text default 'manual_snapshot'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_caller_role text;
  v_profile     public.profiles%rowtype;
  v_snapshot_id uuid;

  -- Legacy Score v1 fields
  v_score               integer;
  v_exposure            integer;
  v_freshness           integer := 100;
  v_visible_trust       integer;
  v_proof_depth         integer := 0;
  v_confidence          integer := 0;
  v_tier                text;

  v_total_agreements        integer := 0;
  v_active_agreements       integer := 0;
  v_total_ceiling           integer := 0;
  v_total_contributed       integer := 0;
  v_risk_flags              integer := 0;

  -- Score v2 shadow fields
  v_shadow_model_version    text;
  v_shadow_base_score       integer := 700;
  v2_contribution_total     integer := 0;
  v2_shadow_score           integer;
  v2_shadow_visible_trust   integer;
  v2_shadow_trust_tier      text;
  v_days_on_platform        integer;

  -- Windowed v2 proof/confidence
  v2_qualifying_count        integer := 0;
  v2_qualifying_ceiling      integer := 0;
  v2_shadow_proof_depth      integer := 0;
  v2_shadow_confidence_score integer := 0;
  v2_lifetime_reward_total   integer := 0;
  v2_lifetime_penalty_total  integer := 0;
begin
  -- ── Authorization ─────────────────────────────────────────────────────────
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  if v_caller_role = 'anon' then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'You may only create a snapshot for your own account'
      using errcode = '42501';
  end if;

  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  -- ── Profile + legacy aggregates ───────────────────────────────────────────
  select * into v_profile
  from public.profiles
  where id = p_user_id;

  if not found then
    raise exception 'Profile not found for user %', p_user_id;
  end if;

  v_score    := greatest(300, coalesce(v_profile.iou_score, 700));
  v_exposure := greatest(0,   coalesce(v_profile.active_exposure_points, 0));

  select
    count(*),
    count(*) filter (where status in ('active', 'completed')),
    coalesce(sum(score_ceiling), 0),
    coalesce(sum(score_contributed), 0)
  into v_total_agreements, v_active_agreements, v_total_ceiling, v_total_contributed
  from public.score_agreements
  where user_id = p_user_id;

  select count(*) into v_risk_flags
  from public.score_risk_flags
  where user_id = p_user_id and is_active = true;

  -- Legacy proof depth and confidence (lifetime — unchanged)
  v_proof_depth := least(100, greatest(0,
    (v_active_agreements * 10) + least(40, floor(v_total_ceiling / 25)::integer)
  ));

  v_confidence := least(100, greatest(0,
    round((v_proof_depth * 0.70) + (v_freshness * 0.30))::integer
  ));

  v_visible_trust := public.score_v2_visible_trust(v_score, v_exposure, v_freshness);

  v_days_on_platform := greatest(0,
    floor(extract(epoch from (now() - coalesce(v_profile.created_at, now()))) / 86400)::integer
  );

  v_tier := public.score_v2_trust_tier(
    v_score, v_days_on_platform, v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0, v_risk_flags > 0
  );

  -- ── Score v2 shadow — resolve exactly one shadow model ────────────────────
  begin
    select version,
           greatest(700, coalesce((config ->> 'base_score')::integer, 700))
    into strict v_shadow_model_version, v_shadow_base_score
    from public.trust_model_versions
    where model_key = 'iou_score' and status = 'shadow'
    order by activated_at desc nulls last;
  exception
    when no_data_found then
      raise exception 'No shadow model registered for iou_score' using errcode = 'P0002';
    when too_many_rows then
      raise exception 'Multiple shadow models for iou_score; expected exactly one'
        using errcode = 'P0003';
  end;

  -- ── Effective contribution total (rolling 2-year window) ─────────────────
  v2_contribution_total := public.score_v2_effective_contributions_internal(
    p_user_id, v_shadow_model_version, now()
  );

  -- ── Lifetime totals by version (audit only, not summed into score) ────────
  select
    coalesce(sum(points_awarded) filter (where impact_direction = 'reward'),  0),
    coalesce(sum(points_awarded) filter (where impact_direction = 'penalty'), 0)
  into v2_lifetime_reward_total, v2_lifetime_penalty_total
  from public.score_v2_contributions
  where user_id       = p_user_id
    and model_key     = 'iou_score'
    and model_version = v_shadow_model_version;

  -- ── v2 shadow score ───────────────────────────────────────────────────────
  v2_shadow_score := greatest(300, least(1400,
    v_shadow_base_score + v2_contribution_total
  ));

  -- ── Windowed qualifying evidence — model-specific ceilings ────────────────
  -- v2.1: use score_v2_ceiling_for_agreement_v21 (activation-relative pair
  --       index, v2.1 curve, hard cap 200).  Requires personal_iou filter
  --       because the function returns 0 for other source types.
  -- v2.0 and others: fall back to score_agreements.score_ceiling.
  if v_shadow_model_version = 'v2.1-shadow' then
    select
      count(distinct sa.id)::integer,
      coalesce(sum(
        public.score_v2_ceiling_for_agreement_v21(sa.id, null)
      ), 0)::integer
    into v2_qualifying_count, v2_qualifying_ceiling
    from public.score_agreements sa
    where sa.user_id     = p_user_id
      and sa.source_type = 'personal_iou'
      and (
        sa.status = 'active'
        or (
          sa.status = 'completed'
          and exists (
            select 1 from public.trust_outcome_events toe
            where toe.score_agreement_id = sa.id
              and toe.outcome_at > now() - interval '2 years'
          )
        )
      );
  else
    select
      count(distinct sa.id)::integer,
      coalesce(sum(sa.score_ceiling), 0)::integer
    into v2_qualifying_count, v2_qualifying_ceiling
    from public.score_agreements sa
    where sa.user_id = p_user_id
      and (
        sa.status = 'active'
        or (
          sa.status = 'completed'
          and exists (
            select 1 from public.trust_outcome_events toe
            where toe.score_agreement_id = sa.id
              and toe.outcome_at > now() - interval '2 years'
          )
        )
      );
  end if;

  v2_shadow_proof_depth := least(100, greatest(0,
    (v2_qualifying_count * 10) + least(40, floor(v2_qualifying_ceiling / 25)::integer)
  ));

  v2_shadow_confidence_score := least(100, greatest(0,
    round((v2_shadow_proof_depth * 0.70) + (v_freshness * 0.30))::integer
  ));

  -- ── v2 shadow visible trust and tier (windowed proof depth) ──────────────
  v2_shadow_visible_trust := public.score_v2_visible_trust(
    v2_shadow_score, v_exposure, v_freshness
  );

  v2_shadow_trust_tier := public.score_v2_trust_tier(
    v2_shadow_score, v_days_on_platform, v2_shadow_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0, v_risk_flags > 0
  );

  -- ── Insert snapshot ───────────────────────────────────────────────────────
  insert into public.trust_score_snapshots (
    user_id, model_key, model_version,
    public_score, visible_trust, active_exposure_points,
    trust_tier, proof_depth, proof_depth_label,
    confidence_score, confidence_label,
    freshness_score, trend_30d,
    score_agreement_count, active_score_agreement_count,
    score_ceiling_total, score_contributed_total,
    risk_flag_count, active_strike_count, snapshot_reason,
    v2_shadow_score, v2_shadow_visible_trust, v2_shadow_trust_tier,
    v2_shadow_proof_depth, v2_shadow_proof_depth_label,
    v2_shadow_confidence_score, v2_shadow_confidence_label,
    summary
  ) values (
    p_user_id, 'iou_score', v_shadow_model_version,
    v_score, v_visible_trust, v_exposure,
    v_tier,
    v_proof_depth, public.score_v2_proof_depth_label(v_proof_depth),
    v_confidence,  public.score_v2_confidence_label(v_confidence),
    v_freshness, 'stable',
    v_total_agreements, v_active_agreements,
    v_total_ceiling,
    v2_contribution_total,  -- windowed effective total
    v_risk_flags, coalesce(v_profile.strike_count, 0),
    coalesce(p_snapshot_reason, 'manual_snapshot'),
    v2_shadow_score, v2_shadow_visible_trust, v2_shadow_trust_tier,
    v2_shadow_proof_depth,
    public.score_v2_proof_depth_label(v2_shadow_proof_depth),
    v2_shadow_confidence_score,
    public.score_v2_confidence_label(v2_shadow_confidence_score),
    jsonb_build_object(
      'shadow_mode',                     true,
      'legacy_public_score',             v_score,
      'v2_shadow_score',                 v2_shadow_score,
      'v2_effective_contribution_total', v2_contribution_total,
      'v2_contribution_window_start',    (now() - interval '2 years'),
      'v2_lifetime_reward_total',        v2_lifetime_reward_total,
      'v2_lifetime_penalty_total',       v2_lifetime_penalty_total,
      'v2_model_version',                v_shadow_model_version
    )
  )
  returning id into v_snapshot_id;

  return v_snapshot_id;
end;
$function$;

commit;
