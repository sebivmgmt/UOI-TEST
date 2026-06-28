-- ============================================================================
-- Score v2.2 Official Read Cutover
-- DEV project only: colkilearqxuyldzjutw
-- NEVER apply to LIVE project: clxfsghyasjmfoxmhpxv
--
-- What this migration does:
--   A. Creates score_v22_current_state_internal(uuid) — the canonical
--      internal function that all score-facing reads must derive from.
--      Hardcodes 'v2.2-shadow' model; no dynamic registry lookup.
--      SECURITY DEFINER + empty search_path. Restricted to service_role.
--
--   B. Replaces get_my_current_trust_score() to delegate entirely to the
--      canonical function. Preserves exact 18-column return signature
--      and existing grants.
--
--   C. Replaces trust_report_shadow_v to compute public_score,
--      visible_trust, trust_tier, proof_depth, and confidence from live
--      v2.2 contributions rather than stale trust_score_snapshots or the
--      legacy profiles.iou_score column.
--      get_trust_report_for_viewer() is unchanged; it reads this view.
--
-- What this migration does NOT do:
--   - Does not write to score_v2_contributions, trust_outcome_events,
--     score_agreements, trust_score_snapshots, or any score history table.
--   - Does not change profiles.iou_score.
--   - Does not alter trust_model_versions status.
--   - Does not touch the LIVE project.
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- A. Canonical internal function
--    Takes an explicit user UUID; auth check is the caller's responsibility.
--    Uses score_v2_effective_contributions_internal with 'v2.2-shadow' to
--    apply the 2-year window and supersession exclusion rules defined in
--    20260620014000_add_score_v22_outcome_corrections.sql.
--    Proof depth and confidence mirror get_my_current_trust_score() exactly.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.score_v22_current_state_internal(p_user_id uuid)
returns table (
  model_version                 text,
  base_score                    integer,
  effective_contribution_total  integer,
  shadow_score                  integer,
  active_exposure_points        integer,
  freshness_score               integer,
  visible_trust                 integer,
  trust_tier                    text,
  proof_depth                   integer,
  proof_depth_label             text,
  confidence_score              integer,
  confidence_label              text,
  qualifying_agreement_count    integer,
  qualifying_ceiling_total      integer,
  lifetime_reward_total         integer,
  lifetime_penalty_total        integer,
  contribution_window_start     timestamptz,
  days_on_platform              integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_model_version       text    := 'v2.2-shadow';
  v_base_score          integer := 700;
  v_freshness           integer := 100;
  v_profile             public.profiles%rowtype;
  v_contribution_total  integer := 0;
  v_v22_score           integer;
  v_exposure            integer := 0;
  v_visible_trust       integer;
  v_qualifying_count    integer := 0;
  v_qualifying_ceiling  integer := 0;
  v_proof_depth         integer := 0;
  v_confidence          integer := 0;
  v_trust_tier          text;
  v_proof_label         text;
  v_conf_label          text;
  v_lifetime_reward     integer := 0;
  v_lifetime_penalty    integer := 0;
  v_days_on_platform    integer := 0;
  v_risk_flags          integer := 0;
begin
  select * into v_profile from public.profiles p where p.id = p_user_id;
  if not found then
    raise exception 'Profile not found for user %', p_user_id using errcode = 'P0002';
  end if;

  v_exposure := greatest(0, coalesce(v_profile.active_exposure_points, 0));

  v_contribution_total := public.score_v2_effective_contributions_internal(
    p_user_id, v_model_version, now()
  );

  v_v22_score := greatest(300, least(1400, v_base_score + v_contribution_total));

  -- Windowed qualifying evidence — same filter as get_my_current_trust_score()
  select
    count(distinct sa.id)::integer,
    coalesce(sum(sa.score_ceiling), 0)::integer
  into v_qualifying_count, v_qualifying_ceiling
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

  v_proof_depth := least(100, greatest(0,
    (v_qualifying_count * 10)
    + least(40, floor(v_qualifying_ceiling / 25.0)::integer)
  ));

  v_confidence := least(100, greatest(0,
    round((v_proof_depth * 0.70) + (v_freshness * 0.30))::integer
  ));

  v_visible_trust := public.score_v2_visible_trust(v_v22_score, v_exposure, v_freshness);

  v_days_on_platform := greatest(0,
    floor(extract(epoch from (now() - coalesce(v_profile.created_at, now()))) / 86400)::integer
  );

  select count(*)::integer into v_risk_flags
  from public.score_risk_flags srf
  where srf.user_id   = p_user_id
    and srf.is_active = true;

  v_trust_tier := public.score_v2_trust_tier(
    v_v22_score, v_days_on_platform, v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  v_proof_label := public.score_v2_proof_depth_label(v_proof_depth);
  v_conf_label  := public.score_v2_confidence_label(v_confidence);

  select
    coalesce(sum(sc.points_awarded) filter (where sc.impact_direction = 'reward'),  0)::integer,
    coalesce(sum(sc.points_awarded) filter (where sc.impact_direction = 'penalty'), 0)::integer
  into v_lifetime_reward, v_lifetime_penalty
  from public.score_v2_contributions sc
  where sc.user_id       = p_user_id
    and sc.model_key     = 'iou_score'
    and sc.model_version = v_model_version;

  return query select
    v_model_version,
    v_base_score,
    v_contribution_total,
    v_v22_score,
    v_exposure,
    v_freshness,
    v_visible_trust,
    v_trust_tier,
    v_proof_depth,
    v_proof_label,
    v_confidence,
    v_conf_label,
    v_qualifying_count,
    v_qualifying_ceiling,
    v_lifetime_reward,
    v_lifetime_penalty,
    (now() - interval '2 years')::timestamptz,
    v_days_on_platform;
end;
$$;

-- Restricted: never expose to unauthenticated or direct-API callers.
-- get_my_current_trust_score() (SECURITY DEFINER, authenticated-only) is
-- the sole public entry point into this function.
revoke all on function public.score_v22_current_state_internal(uuid) from public, anon, authenticated;
grant execute on function public.score_v22_current_state_internal(uuid) to service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- B. Replace get_my_current_trust_score()
--    Auth check preserved. Delegates to canonical function.
--    Exact 18-column return signature and grants unchanged.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.get_my_current_trust_score()
returns table (
  model_version                 text,
  base_score                    integer,
  effective_contribution_total  integer,
  shadow_score                  integer,
  active_exposure_points        integer,
  freshness_score               integer,
  visible_trust                 integer,
  trust_tier                    text,
  proof_depth                   integer,
  proof_depth_label             text,
  confidence_score              integer,
  confidence_label              text,
  qualifying_agreement_count    integer,
  qualifying_ceiling_total      integer,
  lifetime_reward_total         integer,
  lifetime_penalty_total        integer,
  contribution_window_start     timestamptz,
  days_on_platform              integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  return query
  select * from public.score_v22_current_state_internal(v_uid);
end;
$$;

revoke all on function public.get_my_current_trust_score() from public, anon;
grant execute on function public.get_my_current_trust_score() to authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- C. Replace trust_report_shadow_v
--    All 8 official score fields come from one lateral call to the canonical
--    function: score_v22_current_state_internal(p.id).
--    Privilege chain: get_trust_report_for_viewer() is SECURITY DEFINER
--    (runs as postgres), so view evaluation also runs as postgres, which can
--    call score_v22_current_state_internal. Direct authenticated queries of
--    the view fail at the lateral (permission denied) — enforced by the
--    canonical function's existing REVOKE from authenticated.
--    Non-score columns (agreement counts, risk flags, outcomes, snapshot_at)
--    are preserved exactly. get_trust_report_for_viewer() is unchanged.
-- ─────────────────────────────────────────────────────────────────────────────

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
    count(*) filter (where rf.is_active = true)                                   as active_risk_flag_count,
    count(*) filter (where rf.is_active = true and rf.severity = 'low')           as low_risk_flag_count,
    count(*) filter (where rf.is_active = true and rf.severity = 'medium')        as medium_risk_flag_count,
    count(*) filter (where rf.is_active = true and rf.severity = 'high')          as high_risk_flag_count,
    count(*) filter (where rf.is_active = true and rf.severity = 'critical')      as critical_risk_flag_count,
    jsonb_agg(
      jsonb_build_object(
        'flag_type',   rf.flag_type,
        'severity',    rf.severity,
        'description', rf.description,
        'metadata',    rf.metadata,
        'created_at',  rf.created_at
      )
      order by rf.created_at desc
    ) filter (where rf.is_active = true)                                           as active_risk_flags
  from public.score_risk_flags rf
  group by rf.user_id
),
agreement_summary as (
  select
    sa.user_id,

    count(*)                                                                       as total_score_agreements,

    count(*) filter (
      where sa.status in ('active', 'completed')
        and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    )                                                                              as active_score_affecting_agreements,

    count(*) filter (
      where sa.status in ('active', 'completed')
        and not public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    )                                                                              as active_no_score_agreements,

    coalesce(sum(sa.score_ceiling) filter (
      where sa.status in ('active', 'completed')
        and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    ), 0)                                                                          as active_score_ceiling_total,

    coalesce(sum(sa.score_contributed) filter (
      where sa.status in ('active', 'completed')
        and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    ), 0)                                                                          as active_score_contributed_total,

    count(distinct sa.counterparty_id) filter (
      where sa.status in ('active', 'completed')
        and sa.counterparty_id is not null
        and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    )                                                                              as active_score_affecting_counterparties,

    max(sa.same_pair_index) filter (
      where sa.status in ('active', 'completed')
    )                                                                              as max_same_pair_index

  from public.score_agreements sa
  group by sa.user_id
),
outcome_summary as (
  select
    toe.user_id,
    count(*)                                                                       as total_outcomes,
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
    )                                                                              as positive_outcomes,
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
    )                                                                              as negative_outcomes
  from public.trust_outcome_events toe
  group by toe.user_id
)
select
  p.id    as user_id,
  p.email,

  -- all 8 official score fields come from one canonical function call (alias cs)
  cs.shadow_score                                                                  as public_score,
  cs.visible_trust                                                                 as visible_trust,
  cs.active_exposure_points                                                        as active_exposure_points,
  cs.trust_tier                                                                    as trust_tier,
  cs.proof_depth                                                                   as proof_depth,
  cs.proof_depth_label                                                             as proof_depth_label,
  cs.confidence_score                                                              as confidence_score,
  cs.confidence_label                                                              as confidence_label,

  -- freshness and trend remain snapshot-sourced (historical metadata, not live score inputs)
  coalesce(s.freshness_score, 100)                                                 as freshness_score,
  coalesce(s.trend_30d, 'stable')                                                  as public_trend_30d,

  coalesce(a.total_score_agreements, 0)                                            as total_score_agreements,
  coalesce(a.active_score_affecting_agreements, 0)                                 as active_score_affecting_agreements,
  coalesce(a.active_no_score_agreements, 0)                                        as active_no_score_agreements,
  coalesce(a.active_score_ceiling_total, 0)                                        as active_score_ceiling_total,
  coalesce(a.active_score_contributed_total, 0)                                    as active_score_contributed_total,
  coalesce(a.active_score_affecting_counterparties, 0)                             as active_score_affecting_counterparties,
  coalesce(a.max_same_pair_index, 0)                                               as max_same_pair_index,

  coalesce(r.active_risk_flag_count, 0)                                            as active_risk_flag_count,
  coalesce(r.low_risk_flag_count, 0)                                               as low_risk_flag_count,
  coalesce(r.medium_risk_flag_count, 0)                                            as medium_risk_flag_count,
  coalesce(r.high_risk_flag_count, 0)                                              as high_risk_flag_count,
  coalesce(r.critical_risk_flag_count, 0)                                          as critical_risk_flag_count,
  coalesce(r.active_risk_flags, '[]'::jsonb)                                       as active_risk_flags,

  coalesce(o.total_outcomes, 0)                                                    as total_outcomes,
  coalesce(o.positive_outcomes, 0)                                                 as positive_outcomes,
  coalesce(o.negative_outcomes, 0)                                                 as negative_outcomes,

  case
    when coalesce(r.active_risk_flag_count, 0) = 0
      then 'No active private risk flags.'
    when coalesce(r.high_risk_flag_count, 0) > 0
      or  coalesce(r.critical_risk_flag_count, 0) > 0
      then 'Private review recommended before expanding trust.'
    when coalesce(r.medium_risk_flag_count, 0) > 0
      then 'Trust activity has concentration or pattern warnings.'
    else 'Minor private trust notes available.'
  end                                                                              as private_risk_summary,

  case
    when cs.proof_depth < 35
      then 'Build proof depth by completing verified obligations or adding rent/phone bill verification.'
    when coalesce(a.active_score_affecting_counterparties, 0) <= 1
      and coalesce(a.active_score_affecting_agreements, 0) >= 3
      then 'Most trust activity is concentrated with one counterparty. More verified counterparties would improve trust depth.'
    when coalesce(s.freshness_score, 100) < 70
      then 'Proof is getting stale. Refresh trust with recent verified activity.'
    else 'Trust profile is developing cleanly.'
  end                                                                              as sylienn_private_note,

  -- snapshot timestamp preserved as metadata (no longer used for score values)
  s.created_at                                                                     as latest_snapshot_at

from public.profiles p

-- single canonical source for all 8 official score fields.
-- Called once per row; runs as postgres via the SECURITY DEFINER chain from
-- get_trust_report_for_viewer(). Direct authenticated callers cannot reach this
-- lateral because score_v22_current_state_internal is revoked from authenticated.
cross join lateral (
  select * from public.score_v22_current_state_internal(p.id)
) cs

left join latest_snapshot  s on s.user_id = p.id
left join risk_summary     r on r.user_id  = p.id
left join agreement_summary a on a.user_id = p.id
left join outcome_summary  o on o.user_id  = p.id;
