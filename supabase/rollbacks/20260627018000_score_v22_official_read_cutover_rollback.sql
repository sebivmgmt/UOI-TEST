-- ============================================================================
-- Rollback: Score v2.2 Official Read Cutover
-- Restores exact legacy-read definitions from:
--   20260620007000_fix_current_trust_score_ambiguity.sql  (get_my_current_trust_score)
--   20260526017000_trust_report_shadow_view.sql           (trust_report_shadow_v)
--   20260526019000_fix_trust_report_viewer_return_type.sql (get_trust_report_for_viewer)
--
-- What this rollback does NOT do:
--   - Does not delete score_v2_contributions, trust_outcome_events, or any
--     v2.2 evidence.
--   - Does not change profiles.iou_score.
--   - Does not alter trust_model_versions.
--
-- Order: legacy consumers restored first so no call path references
-- score_v22_current_state_internal when it is dropped at the end.
-- ============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Restore get_my_current_trust_score()
--    Exact copy from 20260620007000_fix_current_trust_score_ambiguity.sql.
--    Reverts to dynamic shadow-model discovery via trust_model_versions.
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
  v_uid                 uuid := auth.uid();
  v_profile             public.profiles%rowtype;
  v_model_version       text;
  v_base_score          integer := 700;
  v_contribution_total  integer := 0;
  v_shadow_score        integer;
  v_exposure            integer := 0;
  v_freshness           integer := 100;
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
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles p where p.id = v_uid;
  if not found then
    raise exception 'Profile not found for user %', v_uid using errcode = 'P0002';
  end if;

  -- Resolve exactly one shadow model (mirrors create_trust_score_snapshot)
  begin
    select tmv.version,
           greatest(700, coalesce((tmv.config ->> 'base_score')::integer, 700))
    into strict v_model_version, v_base_score
    from public.trust_model_versions tmv
    where tmv.model_key = 'iou_score'
      and tmv.status    = 'shadow'
    order by tmv.activated_at desc nulls last;
  exception
    when no_data_found then
      raise exception 'No shadow model registered for iou_score' using errcode = 'P0002';
    when too_many_rows then
      raise exception 'Multiple shadow models found for iou_score; expected exactly one'
        using errcode = 'P0003';
  end;

  v_exposure := greatest(0, coalesce(v_profile.active_exposure_points, 0));

  -- Rolling 2-year effective contribution sum (canonical internal helper)
  v_contribution_total := public.score_v2_effective_contributions_internal(
    v_uid, v_model_version, now()
  );

  v_shadow_score := greatest(300, least(1400, v_base_score + v_contribution_total));

  -- Windowed qualifying evidence (mirrors snapshot logic exactly)
  select
    count(distinct sa.id)::integer,
    coalesce(sum(sa.score_ceiling), 0)::integer
  into v_qualifying_count, v_qualifying_ceiling
  from public.score_agreements sa
  where sa.user_id = v_uid
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

  v_visible_trust := public.score_v2_visible_trust(v_shadow_score, v_exposure, v_freshness);

  v_days_on_platform := greatest(0,
    floor(extract(epoch from (now() - coalesce(v_profile.created_at, now()))) / 86400)::integer
  );

  select count(*)::integer into v_risk_flags
  from public.score_risk_flags srf
  where srf.user_id   = v_uid
    and srf.is_active = true;

  v_trust_tier := public.score_v2_trust_tier(
    v_shadow_score, v_days_on_platform, v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  v_proof_label := public.score_v2_proof_depth_label(v_proof_depth);
  v_conf_label  := public.score_v2_confidence_label(v_confidence);

  -- Explicit alias `sc` on every column to eliminate 42702: the return-table
  -- output column `model_version` is in PL/pgSQL scope and is indistinguishable
  -- from score_v2_contributions.model_version without qualification.
  select
    coalesce(
      sum(sc.points_awarded) filter (where sc.impact_direction = 'reward'),
      0
    )::integer,
    coalesce(
      sum(sc.points_awarded) filter (where sc.impact_direction = 'penalty'),
      0
    )::integer
  into
    v_lifetime_reward,
    v_lifetime_penalty
  from public.score_v2_contributions sc
  where sc.user_id       = v_uid
    and sc.model_key     = 'iou_score'
    and sc.model_version = v_model_version;

  return query select
    v_model_version,
    v_base_score,
    v_contribution_total,
    v_shadow_score,
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

revoke all on function public.get_my_current_trust_score() from public, anon;
grant execute on function public.get_my_current_trust_score() to authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Restore trust_report_shadow_v
--    Exact copy from 20260526017000_trust_report_shadow_view.sql.
--    Reverts to coalesce(snapshot, profiles.iou_score, 700) fallback chain.
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


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Restore get_trust_report_for_viewer()
--    Exact copy from 20260526019000_fix_trust_report_viewer_return_type.sql.
--    (Unchanged by the cutover migration, included here for completeness.)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.get_trust_report_for_viewer(
  p_owner_user_id uuid,
  p_viewer_user_id uuid,
  p_scope text default 'summary'
)
returns table (
  user_id uuid,
  email text,
  public_score integer,
  visible_trust integer,
  trust_tier text,
  proof_depth integer,
  proof_depth_label text,
  confidence_score integer,
  confidence_label text,
  active_score_affecting_agreements bigint,
  active_score_affecting_counterparties bigint,
  active_score_ceiling_total numeric,
  active_risk_flag_count bigint,
  private_risk_summary text,
  sylienn_private_note text,
  latest_snapshot_at timestamptz
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_share_id uuid;
begin
  if p_owner_user_id is null or p_viewer_user_id is null then
    raise exception 'Missing owner or viewer user id';
  end if;

  if not public.has_active_trust_report_share(p_owner_user_id, p_viewer_user_id, p_scope) then
    insert into public.trust_report_access_logs (
      owner_user_id,
      viewer_user_id,
      trust_report_share_id,
      access_type,
      scope,
      metadata
    )
    values (
      p_owner_user_id,
      p_viewer_user_id,
      null,
      'access_denied',
      p_scope,
      jsonb_build_object('reason', 'no_active_share')
    );

    return;
  end if;

  select id
  into v_share_id
  from public.trust_report_shares
  where owner_user_id = p_owner_user_id
    and viewer_user_id = p_viewer_user_id
    and revoked_at is null
    and (expires_at is null or expires_at > now())
  order by created_at desc
  limit 1;

  insert into public.trust_report_access_logs (
    owner_user_id,
    viewer_user_id,
    trust_report_share_id,
    access_type,
    scope,
    metadata
  )
  values (
    p_owner_user_id,
    p_viewer_user_id,
    v_share_id,
    'view',
    p_scope,
    '{}'::jsonb
  );

  return query
  select
    tr.user_id,
    tr.email,
    tr.public_score,
    tr.visible_trust,
    tr.trust_tier,
    tr.proof_depth,
    tr.proof_depth_label,
    tr.confidence_score,
    tr.confidence_label,
    tr.active_score_affecting_agreements,
    tr.active_score_affecting_counterparties,
    tr.active_score_ceiling_total::numeric,
    tr.active_risk_flag_count,
    tr.private_risk_summary,
    tr.sylienn_private_note,
    tr.latest_snapshot_at
  from public.trust_report_shadow_v tr
  where tr.user_id = p_owner_user_id;
end;
$function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Revoke cutover-only grants (none required: score_v22_current_state_internal
--    was only granted to service_role and is dropped next).
-- ─────────────────────────────────────────────────────────────────────────────


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Drop the canonical internal function introduced by the cutover migration.
--    Done last so no restored consumer references it when it is dropped.
--    No CASCADE: the only caller (get_my_current_trust_score) was already
--    restored with its legacy body in step 1.
-- ─────────────────────────────────────────────────────────────────────────────

drop function if exists public.score_v22_current_state_internal(uuid);
