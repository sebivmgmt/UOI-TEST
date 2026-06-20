-- IOU Score v2 — Rent Market Adjustment
-- Pure math update only.
-- No triggers.
-- No profile updates.
-- Rent score now considers local market context through metadata:
-- market_median_rent_cents and rent_to_market_ratio.

create or replace function public.score_v2_rent_market_multiplier(
  p_metadata jsonb default '{}'::jsonb
)
returns numeric
language plpgsql
immutable
as $function$
declare
  v_ratio numeric := coalesce((p_metadata->>'rent_to_market_ratio')::numeric, null);
  v_market_median_cents numeric := coalesce((p_metadata->>'market_median_rent_cents')::numeric, null);
  v_monthly_rent_cents numeric := coalesce((p_metadata->>'monthly_rent_cents')::numeric, null);
begin
  -- If ratio was not precomputed, calculate it from monthly rent and local median.
  if v_ratio is null
     and v_market_median_cents is not null
     and v_market_median_cents > 0
     and v_monthly_rent_cents is not null then
    v_ratio := v_monthly_rent_cents / v_market_median_cents;
  end if;

  -- No local market data = conservative neutral-low multiplier.
  -- We do not reward raw high rent without area context.
  if v_ratio is null then
    return 0.85;
  end if;

  -- Market-adjusted obligation seriousness:
  -- Too low relative to market = valid but lighter signal.
  -- Around local median = strong normal signal.
  -- Moderately above median = serious obligation.
  -- Extreme above median = possible overextension/fake/inflated rent, cap benefit.
  return case
    when v_ratio < 0.50 then 0.65
    when v_ratio < 0.75 then 0.80
    when v_ratio <= 1.15 then 1.00
    when v_ratio <= 1.35 then 1.08
    when v_ratio <= 1.60 then 1.12
    when v_ratio <= 1.90 then 1.05
    else 0.90
  end;
end;
$function$;


create or replace function public.score_v2_rent_ceiling(
  p_amount_cents bigint,
  p_term_months integer,
  p_proof_tier integer,
  p_verification_tier integer,
  p_metadata jsonb default '{}'::jsonb
)
returns integer
language plpgsql
immutable
as $function$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric / 100.0);
  v_months integer := greatest(1, coalesce(p_term_months, 1));
  v_bedrooms integer := greatest(0, coalesce((p_metadata->>'bedroom_count')::integer, 0));
  v_same_amount numeric := greatest(0, least(1, coalesce((p_metadata->>'same_amount_consistency')::numeric, 0)));
  v_landlord_verified boolean := coalesce((p_metadata->>'landlord_verified')::boolean, false);

  v_base numeric := 0;
  v_term numeric := 1;
  v_bedroom_bonus numeric := 1;
  v_proof numeric := 1;
  v_consistency numeric := 1;
  v_market numeric := 1;
begin
  -- Raw rent amount still matters, but no longer dominates.
  v_base := case
    when v_amount < 500 then 25
    when v_amount < 900 then 45
    when v_amount < 1500 then 70
    when v_amount < 2400 then 100
    when v_amount < 3500 then 130
    else 160
  end;

  -- Time is a major trust factor.
  v_term := case
    when v_months >= 36 then 1.45
    when v_months >= 24 then 1.30
    when v_months >= 18 then 1.18
    when v_months >= 12 then 1.05
    when v_months >= 6 then 0.90
    else 0.70
  end;

  -- Bedrooms increase responsibility, but only moderately.
  v_bedroom_bonus := case
    when v_bedrooms <= 0 then 1.00
    when v_bedrooms = 1 then 1.03
    when v_bedrooms = 2 then 1.07
    when v_bedrooms = 3 then 1.12
    else 1.16
  end;

  -- Tier 4 IOU rail is the biggest proof boost.
  v_proof := case greatest(0, least(coalesce(p_proof_tier, 0), 4))
    when 0 then 0.25
    when 1 then 0.45
    when 2 then 0.75
    when 3 then 0.95
    when 4 then 1.35
    else 0.25
  end;

  v_proof := v_proof * case greatest(0, least(coalesce(p_verification_tier, 0), 4))
    when 0 then 0.80
    when 1 then 0.90
    when 2 then 1.00
    when 3 then 1.05
    when 4 then 1.30
    else 1.00
  end;

  -- Consistency and verified landlord are confidence boosters.
  v_consistency := 1.00 + (v_same_amount * 0.05);

  if v_landlord_verified then
    v_consistency := v_consistency + 0.05;
  end if;

  -- Local market adjustment.
  v_market := public.score_v2_rent_market_multiplier(coalesce(p_metadata, '{}'::jsonb));

  return least(
    350,
    greatest(
      20,
      round(v_base * v_term * v_bedroom_bonus * v_proof * v_consistency * v_market)::integer
    )
  );
end;
$function$;