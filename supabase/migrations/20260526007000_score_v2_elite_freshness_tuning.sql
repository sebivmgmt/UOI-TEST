-- IOU Score v2 — Elite Freshness Tuning
-- Pure math update only.
-- No triggers.
-- No profile updates.
-- No raw score decay.
--
-- Goal:
-- Users do not lose raw score for inactivity,
-- but stale proof cannot maintain Elite / IOU Pillar eligibility.

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
  -- Lower/middle tiers should not punish inactivity harshly.
  if v_tier in ('rebuilding_user', 'verified_user', 'developing_trust', 'reliable') then
    return true;
  end if;

  if v_tier = 'strong' then
    return v_fresh >= 45;
  end if;

  if v_tier = 'excellent' then
    return v_fresh >= 55 and v_depth >= 45;
  end if;

  -- Elite trust requires recent proof.
  -- A stale high score can keep the raw score, but cannot keep elite eligibility.
  if v_tier = 'elite_trust' then
    return v_fresh >= 80 and v_depth >= 75 and v_days >= 365;
  end if;

  -- IOU Pillar is extremely rare and requires very fresh proof + 5 years.
  if v_tier = 'iou_pillar' then
    return v_fresh >= 90 and v_depth >= 90 and v_days >= 1825;
  end if;

  return false;
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
      when v_score >= 1200 then 35
      when v_score >= 1000 then 25
      when v_score >= 850 then 12
      else 5
    end;
  elsif v_fresh >= 55 then
    v_adjustment := case
      when v_score >= 1200 then 70
      when v_score >= 1000 then 50
      when v_score >= 850 then 28
      else 12
    end;
  elsif v_fresh >= 40 then
    v_adjustment := case
      when v_score >= 1200 then 105
      when v_score >= 1000 then 80
      when v_score >= 850 then 45
      else 20
    end;
  else
    v_adjustment := case
      when v_score >= 1200 then 150
      when v_score >= 1000 then 115
      when v_score >= 850 then 70
      else 35
    end;
  end if;

  return v_adjustment;
end;
$function$;