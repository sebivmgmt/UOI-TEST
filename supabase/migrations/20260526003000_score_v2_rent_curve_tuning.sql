-- IOU Score v2 — Rent Curve Tuning
-- Pure math update only.
-- Spreads rent ceilings so normal verified rent is powerful,
-- but Tier 4 / long-term / high-obligation rent is what reaches the cap.

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
begin
  -- Monthly rent amount sets the base seriousness.
  v_base := case
    when v_amount < 500 then 25
    when v_amount < 900 then 55
    when v_amount < 1500 then 90
    when v_amount < 2400 then 125
    when v_amount < 3500 then 155
    else 190
  end;

  -- Lease/rent stream duration matters, but should not max ordinary rent instantly.
  v_term := case
    when v_months >= 24 then 1.35
    when v_months >= 18 then 1.25
    when v_months >= 12 then 1.12
    when v_months >= 6 then 0.95
    else 0.70
  end;

  -- Bedrooms increase responsibility, but only moderately.
  v_bedroom_bonus := case
    when v_bedrooms <= 0 then 1.00
    when v_bedrooms = 1 then 1.04
    when v_bedrooms = 2 then 1.09
    when v_bedrooms = 3 then 1.15
    else 1.20
  end;

  -- Proof and verification are powerful, but capped so only Tier 4 reaches the top.
  v_proof := case greatest(0, least(coalesce(p_proof_tier, 0), 4))
    when 0 then 0.30
    when 1 then 0.55
    when 2 then 0.80
    when 3 then 1.00
    when 4 then 1.18
    else 0.30
  end;

  v_proof := v_proof * case greatest(0, least(coalesce(p_verification_tier, 0), 4))
    when 0 then 0.80
    when 1 then 0.90
    when 2 then 1.00
    when 3 then 1.08
    when 4 then 1.18
    else 1.00
  end;

  -- Same-amount consistency and landlord verification add confidence.
  v_consistency := 1.00 + (v_same_amount * 0.08);

  if v_landlord_verified then
    v_consistency := v_consistency + 0.08;
  end if;

  return least(
    350,
    greatest(
      20,
      round(v_base * v_term * v_bedroom_bonus * v_proof * v_consistency)::integer
    )
  );
end;
$function$;