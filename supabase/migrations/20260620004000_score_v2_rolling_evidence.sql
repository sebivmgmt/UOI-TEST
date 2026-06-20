-- Migration A: Score v2 rolling evidence window
-- Adds impact_direction, secured effective-contribution function,
-- windowed proof/confidence snapshot fields, and updates snapshot creation.
-- Does NOT change the current shadow model version (remains v2.0-shadow).
-- LIVE untouched.

begin;

-- ── 1. Add impact_direction to score_v2_contributions ──────────────────────
-- All existing rows are rewards; DEFAULT 'reward' populates them correctly.
alter table public.score_v2_contributions
  add column if not exists impact_direction text
    not null default 'reward'
    check (impact_direction in ('reward', 'penalty'));

-- ── 2. Extend contribution_type to include future penalty types ───────────
alter table public.score_v2_contributions
  drop constraint if exists score_v2_contributions_type_check;

alter table public.score_v2_contributions
  add constraint score_v2_contributions_type_check
  check (contribution_type = any (array[
    'payment_performance',
    'agreement_completion',
    'payment_late_penalty',
    'agreement_default_penalty'
  ]));

-- ── 3. Index supporting the canonical effective-contribution query ─────────
create index if not exists score_v2_contributions_user_model_idx
  on public.score_v2_contributions (user_id, model_key, model_version);

-- ── 4. New windowed v2 shadow columns on trust_score_snapshots ────────────
alter table public.trust_score_snapshots
  add column if not exists v2_shadow_proof_depth        integer,
  add column if not exists v2_shadow_proof_depth_label  text,
  add column if not exists v2_shadow_confidence_score   integer,
  add column if not exists v2_shadow_confidence_label   text;

-- ── 5. Canonical effective-contribution function (internal, secured) ──────
create or replace function public.score_v2_effective_contributions_internal(
  p_user_id       uuid,
  p_model_version text,
  p_at            timestamptz
)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(
    case
      when sc.impact_direction = 'penalty' then -sc.points_awarded
      else                                       sc.points_awarded
    end
  ), 0)::integer
  from public.score_v2_contributions sc
  join public.trust_outcome_events   toe on toe.id = sc.outcome_event_id
  where sc.user_id       = p_user_id
    and sc.model_key     = 'iou_score'
    and sc.model_version = p_model_version
    and toe.outcome_at   > p_at - interval '2 years';
$$;

revoke all on function public.score_v2_effective_contributions_internal(uuid, text, timestamptz)
  from public, anon, authenticated;

grant execute on function public.score_v2_effective_contributions_internal(uuid, text, timestamptz)
  to postgres, service_role;

-- ── 6. Updated create_trust_score_snapshot ────────────────────────────────
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

  -- New: windowed v2 proof/confidence
  v2_qualifying_count       integer := 0;
  v2_qualifying_ceiling     integer := 0;
  v2_shadow_proof_depth     integer := 0;
  v2_shadow_confidence_score integer := 0;
  v2_lifetime_reward_total  integer := 0;
  v2_lifetime_penalty_total integer := 0;
begin
  -- ── Authorization ─────────────────────────────────────────────────────────
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  if v_caller_role = 'anon' then
    raise exception 'Authentication required'
      using errcode = '42501';
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

  -- Legacy proof depth, confidence, visible trust, tier (lifetime — unchanged)
  v_proof_depth := least(100, greatest(0,
    (v_active_agreements * 10)
    + least(40, floor(v_total_ceiling / 25)::integer)
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
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  -- ── Score v2 shadow — resolve exactly one shadow model ────────────────────
  -- Fails clearly (NO_DATA_FOUND or TOO_MANY_ROWS) if constraint is violated.
  begin
    select version,
           greatest(700, coalesce((config ->> 'base_score')::integer, 700))
    into strict v_shadow_model_version, v_shadow_base_score
    from public.trust_model_versions
    where model_key = 'iou_score'
      and status    = 'shadow'
    order by activated_at desc nulls last;
  exception
    when no_data_found then
      raise exception 'No shadow model registered for iou_score'
        using errcode = 'P0002';
    when too_many_rows then
      raise exception 'Multiple shadow models found for iou_score; expected exactly one'
        using errcode = 'P0003';
  end;

  -- ── Effective contribution total (rolling 2-year window) ─────────────────
  v2_contribution_total := public.score_v2_effective_contributions_internal(
    p_user_id,
    v_shadow_model_version,
    now()
  );

  -- ── Lifetime totals for audit (version-specific, not mixed) ──────────────
  select
    coalesce(sum(points_awarded) filter (where impact_direction = 'reward'),  0),
    coalesce(sum(points_awarded) filter (where impact_direction = 'penalty'), 0)
  into v2_lifetime_reward_total, v2_lifetime_penalty_total
  from public.score_v2_contributions
  where user_id       = p_user_id
    and model_key     = 'iou_score'
    and model_version = v_shadow_model_version;

  -- ── v2_shadow_score ───────────────────────────────────────────────────────
  v2_shadow_score := greatest(300, least(1400,
    v_shadow_base_score + v2_contribution_total
  ));

  -- ── Windowed qualifying evidence for v2 proof depth ──────────────────────
  -- Qualifying: active agreements (current state) OR completed agreements
  -- whose earliest qualifying outcome is within the 2-year window.
  -- Ceiling: score_agreements.score_ceiling for v2.0; Migration B will
  -- branch on model version to use v2.1-specific ceilings when active.
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
          select 1
          from public.trust_outcome_events toe
          where toe.score_agreement_id = sa.id
            and toe.outcome_at > now() - interval '2 years'
        )
      )
    );

  v2_shadow_proof_depth := least(100, greatest(0,
    (v2_qualifying_count * 10)
    + least(40, floor(v2_qualifying_ceiling / 25)::integer)
  ));

  v2_shadow_confidence_score := least(100, greatest(0,
    round((v2_shadow_proof_depth * 0.70) + (v_freshness * 0.30))::integer
  ));

  -- ── v2 shadow visible trust and tier (windowed proof depth) ──────────────
  v2_shadow_visible_trust := public.score_v2_visible_trust(
    v2_shadow_score, v_exposure, v_freshness
  );

  v2_shadow_trust_tier := public.score_v2_trust_tier(
    v2_shadow_score,
    v_days_on_platform,
    v2_shadow_proof_depth,          -- windowed, not lifetime
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  -- ── Insert snapshot ───────────────────────────────────────────────────────
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
    v2_shadow_score,
    v2_shadow_visible_trust,
    v2_shadow_trust_tier,
    v2_shadow_proof_depth,
    v2_shadow_proof_depth_label,
    v2_shadow_confidence_score,
    v2_shadow_confidence_label,
    summary
  )
  values (
    p_user_id,
    'iou_score',
    v_shadow_model_version,
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
    v2_contribution_total,          -- windowed effective total, not lifetime sum
    v_risk_flags,
    coalesce(v_profile.strike_count, 0),
    coalesce(p_snapshot_reason, 'manual_snapshot'),
    v2_shadow_score,
    v2_shadow_visible_trust,
    v2_shadow_trust_tier,
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
