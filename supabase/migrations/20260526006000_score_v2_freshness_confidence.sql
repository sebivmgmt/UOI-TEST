-- IOU Score v2 — Freshness + Confidence Math
-- Pure functions only.
-- No triggers.
-- No profile updates.
-- No score mutation.
--
-- Purpose:
-- Past trust remains earned, but stale proof lowers confidence,
-- tier eligibility, and Visible Trust.

create or replace function public.score_v2_domain_freshness_days(
  p_domain text
)
returns integer
language plpgsql
immutable
as $function$
begin
  return case coalesce(p_domain, '')
    when 'housing_reliability' then 60
    when 'recurring_obligation_reliability' then 60
    when 'payment_reliability' then 180
    when 'obligation_strength' then 365
    when 'proof_depth' then 180
    when 'counterparty_diversity' then 365
    when 'recovery_behavior' then 180
    when 'lender_fairness' then 365
    when 'time_with_iou' then 99999
    when 'risk_stability' then 90
    else 180
  end;
end;
$function$;


create or replace function public.score_v2_freshness_multiplier(
  p_last_verified_at timestamptz,
  p_domain text default 'payment_reliability',
  p_as_of timestamptz default now()
)
returns numeric
language plpgsql
stable
as $function$
declare
  v_days_since integer;
  v_fresh_days integer;
begin
  if p_last_verified_at is null then
    return 0.40;
  end if;

  v_days_since := greatest(0, floor(extract(epoch from (p_as_of - p_last_verified_at)) / 86400)::integer);
  v_fresh_days := public.score_v2_domain_freshness_days(p_domain);

  if v_days_since <= v_fresh_days then
    return 1.00;
  end if;

  if v_days_since <= v_fresh_days * 2 then
    return 0.85;
  end if;

  if v_days_since <= v_fresh_days * 3 then
    return 0.70;
  end if;

  if v_days_since <= v_fresh_days * 5 then
    return 0.55;
  end if;

  return 0.40;
end;
$function$;


create or replace function public.score_v2_freshness_score(
  p_last_verified_at timestamptz,
  p_domain text default 'payment_reliability',
  p_as_of timestamptz default now()
)
returns integer
language plpgsql
stable
as $function$
begin
  return round(public.score_v2_freshness_multiplier(p_last_verified_at, p_domain, p_as_of) * 100)::integer;
end;
$function$;


create or replace function public.score_v2_confidence_label(
  p_confidence integer
)
returns text
language plpgsql
immutable
as $function$
declare
  v_conf integer := greatest(0, least(100, coalesce(p_confidence, 0)));
begin
  if v_conf >= 90 then
    return 'very_high';
  elsif v_conf >= 75 then
    return 'high';
  elsif v_conf >= 55 then
    return 'medium';
  elsif v_conf >= 35 then
    return 'low';
  else
    return 'thin';
  end if;
end;
$function$;


create or replace function public.score_v2_proof_depth_label(
  p_proof_depth integer
)
returns text
language plpgsql
immutable
as $function$
declare
  v_depth integer := greatest(0, least(100, coalesce(p_proof_depth, 0)));
begin
  if v_depth >= 90 then
    return 'institutional_grade';
  elsif v_depth >= 75 then
    return 'strong';
  elsif v_depth >= 55 then
    return 'developing';
  elsif v_depth >= 35 then
    return 'thin';
  else
    return 'very_thin';
  end if;
end;
$function$;


create or replace function public.score_v2_freshness_adjustment(
  p_score integer,
  p_freshness_score integer
)
returns integer
language plpgsql
immutable
as $function$
declare
  v_score integer := greatest(300, coalesce(p_score, 700));
  v_fresh integer := greatest(0, least(100, coalesce(p_freshness_score, 100)));
  v_adjustment integer := 0;
begin
  -- No raw score decay. This only affects Visible Trust.
  -- Higher scores rely more on fresh proof.
  if v_fresh >= 85 then
    return 0;
  end if;

  if v_fresh >= 70 then
    v_adjustment := case
      when v_score >= 1000 then 20
      when v_score >= 850 then 12
      else 5
    end;
  elsif v_fresh >= 55 then
    v_adjustment := case
      when v_score >= 1000 then 45
      when v_score >= 850 then 28
      else 12
    end;
  elsif v_fresh >= 40 then
    v_adjustment := case
      when v_score >= 1000 then 75
      when v_score >= 850 then 45
      else 20
    end;
  else
    v_adjustment := case
      when v_score >= 1000 then 110
      when v_score >= 850 then 70
      else 35
    end;
  end if;

  return v_adjustment;
end;
$function$;


create or replace function public.score_v2_visible_trust(
  p_score integer,
  p_active_exposure_points integer default 0,
  p_freshness_score integer default 100
)
returns integer
language plpgsql
immutable
as $function$
declare
  v_score integer := greatest(300, coalesce(p_score, 700));
  v_exposure integer := greatest(0, coalesce(p_active_exposure_points, 0));
  v_freshness_adjustment integer := public.score_v2_freshness_adjustment(v_score, p_freshness_score);
begin
  return greatest(300, v_score - v_exposure - v_freshness_adjustment);
end;
$function$;


create or replace function public.score_v2_public_trend_label(
  p_delta_30d integer
)
returns text
language plpgsql
immutable
as $function$
declare
  v_delta integer := coalesce(p_delta_30d, 0);
begin
  if v_delta >= 15 then
    return 'improving';
  elsif v_delta <= -15 then
    return 'declining';
  elsif abs(v_delta) >= 8 then
    return 'volatile';
  else
    return 'stable';
  end if;
end;
$function$;


create or replace function public.score_v2_tier_freshness_eligible(
  p_tier text,
  p_freshness_score integer,
  p_proof_depth integer default 0,
  p_time_with_iou_days integer default 0
)
returns boolean
language plpgsql
immutable
as $function$
declare
  v_tier text := coalesce(p_tier, '');
  v_fresh integer := greatest(0, least(100, coalesce(p_freshness_score, 0)));
  v_depth integer := greatest(0, least(100, coalesce(p_proof_depth, 0)));
  v_days integer := greatest(0, coalesce(p_time_with_iou_days, 0));
begin
  -- Lower and middle tiers should not punish inactivity harshly.
  if v_tier in ('rebuilding_user', 'verified_user', 'developing_trust', 'reliable') then
    return true;
  end if;

  if v_tier = 'strong' then
    return v_fresh >= 45;
  end if;

  if v_tier = 'excellent' then
    return v_fresh >= 55 and v_depth >= 45;
  end if;

  if v_tier = 'elite_trust' then
    return v_fresh >= 70 and v_depth >= 70 and v_days >= 365;
  end if;

  if v_tier = 'iou_pillar' then
    return v_fresh >= 85 and v_depth >= 90 and v_days >= 1825;
  end if;

  return false;
end;
$function$;
