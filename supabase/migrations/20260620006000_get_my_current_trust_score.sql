-- Score v2.1 — Current-score read-path RPC
-- Dynamic calculation using the same canonical helpers as create_trust_score_snapshot.
-- No data mutation. No user_id param — auth.uid() only.
-- DEV only; LIVE untouched.

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

  select * into v_profile from public.profiles where id = v_uid;
  if not found then
    raise exception 'Profile not found for user %', v_uid using errcode = 'P0002';
  end if;

  -- Resolve exactly one shadow model (mirrors create_trust_score_snapshot)
  begin
    select version,
           greatest(700, coalesce((config ->> 'base_score')::integer, 700))
    into strict v_model_version, v_base_score
    from public.trust_model_versions
    where model_key = 'iou_score'
      and status    = 'shadow'
    order by activated_at desc nulls last;
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
  from public.score_risk_flags
  where user_id  = v_uid
    and is_active = true;

  v_trust_tier  := public.score_v2_trust_tier(
    v_shadow_score, v_days_on_platform, v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  v_proof_label := public.score_v2_proof_depth_label(v_proof_depth);
  v_conf_label  := public.score_v2_confidence_label(v_confidence);

  select
    coalesce(sum(points_awarded) filter (where impact_direction = 'reward'),  0)::integer,
    coalesce(sum(points_awarded) filter (where impact_direction = 'penalty'), 0)::integer
  into v_lifetime_reward, v_lifetime_penalty
  from public.score_v2_contributions
  where user_id       = v_uid
    and model_key     = 'iou_score'
    and model_version = v_model_version;

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
