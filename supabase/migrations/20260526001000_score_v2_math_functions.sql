-- IOU Score v2 — Phase B
-- Pure scoring math functions only.
-- No profile updates.
-- No triggers.
-- No live score mutation.

create or replace function public.score_v2_proof_multiplier(
  p_proof_tier integer,
  p_verification_tier integer
)
returns numeric
language plpgsql
immutable
as $function$
declare
  v_proof numeric := 0.25;
  v_verification numeric := 1.00;
begin
  v_proof :=
    case greatest(0, least(coalesce(p_proof_tier, 0), 4))
      when 0 then 0.25  -- self-entered / unverified
      when 1 then 0.60  -- manual proof / counterparty confirmed
      when 2 then 0.90  -- bank detected
      when 3 then 1.10  -- verified counterparty / landlord / business
      when 4 then 1.25  -- IOU processed payment rail
      else 0.25
    end;

  v_verification :=
    case greatest(0, least(coalesce(p_verification_tier, 0), 4))
      when 0 then 0.85
      when 1 then 0.95
      when 2 then 1.00
      when 3 then 1.10
      when 4 then 1.20
      else 1.00
    end;

  return round((v_proof * v_verification)::numeric, 4);
end;
$function$;


create or replace function public.score_v2_same_pair_multiplier(
  p_same_pair_index integer
)
returns numeric
language plpgsql
immutable
as $function$
declare
  v_index integer := greatest(1, coalesce(p_same_pair_index, 1));
begin
  if v_index = 1 then return 1.00; end if;
  if v_index = 2 then return 0.80; end if;
  if v_index = 3 then return 0.64; end if;
  if v_index = 4 then return 0.50; end if;
  if v_index = 5 then return 0.35; end if;

  return 0.20;
end;
$function$;


create or replace function public.score_v2_source_multiplier(
  p_source_type text
)
returns numeric
language plpgsql
immutable
as $function$
begin
  return case coalesce(p_source_type, '')
    when 'receipt_split' then 0.20
    when 'phone_bill' then 0.45
    when 'utility_bill' then 0.45
    when 'personal_iou' then 1.00
    when 'family_obligation' then 1.00
    when 'service_contract' then 1.15
    when 'business_obligation' then 1.25
    when 'rent' then 1.75
    when 'lender_activity' then 1.10
    when 'landlord_activity' then 1.35
    else 0.50
  end;
end;
$function$;


create or replace function public.score_v2_amount_weight(
  p_amount_cents bigint
)
returns numeric
language plpgsql
immutable
as $function$
declare
  v_amount_dollars numeric := greatest(1, coalesce(p_amount_cents, 0)::numeric / 100.0);
begin
  -- Logarithmic so $10,000 matters more than $100,
  -- but does not overpower consistency/time/proof.
  return round((ln(v_amount_dollars + 10) / ln(10))::numeric, 4);
end;
$function$;


create or replace function public.score_v2_term_weight(
  p_term_months integer
)
returns numeric
language plpgsql
immutable
as $function$
declare
  v_months integer := greatest(1, coalesce(p_term_months, 1));
begin
  -- Longer obligations matter more, but with diminishing returns.
  return round((1 + (ln(v_months::numeric + 1) / ln(10)) / 2)::numeric, 4);
end;
$function$;


create or replace function public.score_v2_rent_metadata_multiplier(
  p_metadata jsonb
)
returns numeric
language plpgsql
immutable
as $function$
declare
  v_bedrooms integer := greatest(0, coalesce((p_metadata->>'bedroom_count')::integer, 0));
  v_stream_months integer := greatest(0, coalesce((p_metadata->>'rent_stream_months')::integer, 0));
  v_same_amount numeric := greatest(0, least(1, coalesce((p_metadata->>'same_amount_consistency')::numeric, 0)));
  v_landlord_verified boolean := coalesce((p_metadata->>'landlord_verified')::boolean, false);
  v_multiplier numeric := 1.00;
begin
  -- Bedrooms boost ceiling, not instant score.
  v_multiplier := v_multiplier +
    case
      when v_bedrooms <= 0 then 0
      when v_bedrooms = 1 then 0.05
      when v_bedrooms = 2 then 0.12
      when v_bedrooms = 3 then 0.20
      else 0.25
    end;

  -- Long stable rent stream matters.
  v_multiplier := v_multiplier +
    case
      when v_stream_months >= 24 then 0.25
      when v_stream_months >= 12 then 0.18
      when v_stream_months >= 6 then 0.10
      when v_stream_months >= 3 then 0.04
      else 0
    end;

  -- Same amount consistency suggests stability.
  v_multiplier := v_multiplier + (v_same_amount * 0.10);

  if v_landlord_verified then
    v_multiplier := v_multiplier + 0.15;
  end if;

  return round(least(v_multiplier, 1.75)::numeric, 4);
end;
$function$;


create or replace function public.score_v2_obligation_weight(
  p_source_type text,
  p_amount_cents bigint,
  p_term_months integer,
  p_frequency text,
  p_proof_tier integer,
  p_verification_tier integer,
  p_same_pair_index integer,
  p_metadata jsonb default '{}'::jsonb
)
returns numeric
language plpgsql
immutable
as $function$
declare
  v_source numeric;
  v_amount numeric;
  v_term numeric;
  v_proof numeric;
  v_pair numeric;
  v_rent_meta numeric := 1.00;
  v_frequency numeric := 1.00;
  v_weight numeric;
begin
  v_source := public.score_v2_source_multiplier(p_source_type);
  v_amount := public.score_v2_amount_weight(p_amount_cents);
  v_term := public.score_v2_term_weight(p_term_months);
  v_proof := public.score_v2_proof_multiplier(p_proof_tier, p_verification_tier);
  v_pair := public.score_v2_same_pair_multiplier(p_same_pair_index);

  v_frequency :=
    case coalesce(p_frequency, '')
      when 'weekly' then 1.05
      when 'biweekly' then 1.03
      when 'monthly' then 1.00
      when 'one_time' then 0.85
      else 1.00
    end;

  if p_source_type = 'rent' then
    v_rent_meta := public.score_v2_rent_metadata_multiplier(coalesce(p_metadata, '{}'::jsonb));
  end if;

  v_weight := v_source * v_amount * v_term * v_proof * v_pair * v_frequency * v_rent_meta;

  return round(greatest(0, v_weight)::numeric, 4);
end;
$function$;


create or replace function public.score_v2_score_ceiling(
  p_source_type text,
  p_amount_cents bigint,
  p_term_months integer,
  p_frequency text,
  p_proof_tier integer,
  p_verification_tier integer,
  p_same_pair_index integer,
  p_metadata jsonb default '{}'::jsonb
)
returns integer
language plpgsql
immutable
as $function$
declare
  v_weight numeric;
  v_raw numeric;
  v_ceiling integer;
begin
  v_weight := public.score_v2_obligation_weight(
    p_source_type,
    p_amount_cents,
    p_term_months,
    p_frequency,
    p_proof_tier,
    p_verification_tier,
    p_same_pair_index,
    coalesce(p_metadata, '{}'::jsonb)
  );

  -- Conservative starting calibration.
  -- We can tune after test table outputs.
  v_raw := 8 * v_weight;

  v_ceiling :=
    case p_source_type
      when 'receipt_split' then least(15, greatest(0, round(v_raw)::integer))
      when 'phone_bill' then least(60, greatest(3, round(v_raw)::integer))
      when 'utility_bill' then least(60, greatest(3, round(v_raw)::integer))
      when 'personal_iou' then least(140, greatest(3, round(v_raw)::integer))
      when 'family_obligation' then least(140, greatest(3, round(v_raw)::integer))
      when 'service_contract' then least(180, greatest(5, round(v_raw)::integer))
      when 'business_obligation' then least(220, greatest(5, round(v_raw)::integer))
      when 'rent' then least(350, greatest(20, round(v_raw)::integer))
      when 'lender_activity' then least(120, greatest(3, round(v_raw)::integer))
      when 'landlord_activity' then least(180, greatest(5, round(v_raw)::integer))
      else least(50, greatest(1, round(v_raw)::integer))
    end;

  return v_ceiling;
end;
$function$;


create or replace function public.score_v2_trust_tier(
  p_score integer,
  p_time_with_iou_days integer default 0,
  p_proof_depth integer default 0,
  p_has_active_strike boolean default false,
  p_has_high_risk_flag boolean default false
)
returns text
language plpgsql
immutable
as $function$
declare
  v_score integer := coalesce(p_score, 700);
  v_days integer := greatest(0, coalesce(p_time_with_iou_days, 0));
  v_proof integer := greatest(0, least(100, coalesce(p_proof_depth, 0)));
begin
  if p_has_active_strike then
    return 'rebuilding_user';
  end if;

  if v_score < 650 then
    return 'rebuilding_user';
  end if;

  if v_score < 725 then
    return 'verified_user';
  end if;

  if v_score < 800 then
    return 'developing_trust';
  end if;

  if v_score < 875 then
    return 'reliable';
  end if;

  if v_score < 950 then
    return 'strong';
  end if;

  if v_score < 1050 then
    return 'excellent';
  end if;

  -- Elite requires score plus proof/time.
  if v_score < 1250 then
    if v_days >= 365 and v_proof >= 70 and not p_has_high_risk_flag then
      return 'elite_trust';
    end if;
    return 'excellent';
  end if;

  -- IOU Pillar should be extremely rare.
  -- Requires 5+ years and very high proof depth.
  if v_score >= 1300 and v_days >= 1825 and v_proof >= 90 and not p_has_high_risk_flag then
    return 'iou_pillar';
  end if;

  return 'elite_trust';
end;
$function$;