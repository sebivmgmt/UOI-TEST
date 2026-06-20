-- IOU Score v2 — Category Curve Tuning
-- Pure math update only.
-- No triggers.
-- No profile updates.
-- No live scoring mutation.

create or replace function public.score_v2_personal_iou_ceiling(
  p_amount_cents bigint
)
returns integer
language plpgsql
immutable
as $function$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric);
begin
  return case
    when v_amount < 5000 then
      greatest(1, round(v_amount / 2000.0)::integer) -- $20≈1, $40≈2

    when v_amount < 10000 then
      round(3 + ((v_amount - 5000) / 5000.0) * 3)::integer -- $50-$99≈3-6

    when v_amount < 25000 then
      round(7 + ((v_amount - 10000) / 15000.0) * 8)::integer -- $100-$249≈7-15

    when v_amount < 50000 then
      round(16 + ((v_amount - 25000) / 25000.0) * 14)::integer -- $250-$499≈16-30

    when v_amount < 100000 then
      round(35 + ((v_amount - 50000) / 50000.0) * 20)::integer -- $500-$999≈35-55

    when v_amount < 200000 then
      round(56 + ((v_amount - 100000) / 100000.0) * 24)::integer -- $1k-$2k≈56-80

    else
      least(140, round(68 + ln((v_amount / 100.0) / 2000.0 + 1) * 36)::integer)
  end;
end;
$function$;


create or replace function public.score_v2_phone_bill_ceiling(
  p_amount_cents bigint,
  p_term_months integer,
  p_proof_tier integer,
  p_verification_tier integer
)
returns integer
language plpgsql
immutable
as $function$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric / 100.0);
  v_months integer := greatest(1, coalesce(p_term_months, 1));
  v_base numeric := 0;
  v_time_bonus numeric := 1;
  v_proof numeric := public.score_v2_proof_multiplier(p_proof_tier, p_verification_tier);
begin
  v_base := case
    when v_amount < 30 then 2
    when v_amount < 50 then 4
    when v_amount < 80 then 7
    when v_amount < 120 then 10
    when v_amount < 200 then 14
    else 18
  end;

  v_time_bonus := case
    when v_months >= 24 then 2.2
    when v_months >= 12 then 1.7
    when v_months >= 6 then 1.3
    else 1.0
  end;

  return least(60, greatest(1, round(v_base * v_time_bonus * v_proof)::integer));
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
  v_proof numeric := public.score_v2_proof_multiplier(p_proof_tier, p_verification_tier);
  v_meta numeric := public.score_v2_rent_metadata_multiplier(coalesce(p_metadata, '{}'::jsonb));
  v_base numeric := 0;
  v_term numeric := 1;
  v_bedroom_bonus numeric := 1;
begin
  v_base := case
    when v_amount < 500 then 30
    when v_amount < 900 then 60
    when v_amount < 1500 then 95
    when v_amount < 2400 then 135
    when v_amount < 3500 then 175
    else 220
  end;

  v_term := case
    when v_months >= 24 then 1.35
    when v_months >= 12 then 1.15
    when v_months >= 6 then 1.0
    else 0.75
  end;

  v_bedroom_bonus := case
    when v_bedrooms <= 0 then 1.0
    when v_bedrooms = 1 then 1.05
    when v_bedrooms = 2 then 1.12
    when v_bedrooms = 3 then 1.20
    else 1.25
  end;

  return least(350, greatest(20, round(v_base * v_term * v_bedroom_bonus * v_proof * v_meta)::integer));
end;
$function$;


create or replace function public.score_v2_contract_ceiling(
  p_source_type text,
  p_amount_cents bigint,
  p_term_months integer,
  p_proof_tier integer,
  p_verification_tier integer
)
returns integer
language plpgsql
immutable
as $function$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric);
  v_proof numeric := public.score_v2_proof_multiplier(p_proof_tier, p_verification_tier);
  v_term numeric := public.score_v2_term_weight(p_term_months);
  v_raw numeric := 0;
  v_cap integer := 180;
begin
  v_raw := public.score_v2_personal_iou_ceiling(v_amount::bigint) * 1.2 * v_term * v_proof;

  if p_source_type = 'business_obligation' then
    v_cap := 300;
    v_raw := v_raw * 1.25;
  elsif p_source_type = 'service_contract' then
    v_cap := 180;
  else
    v_cap := 160;
  end if;

  return least(v_cap, greatest(5, round(v_raw)::integer));
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
  v_base integer := 0;
  v_pair numeric := public.score_v2_same_pair_multiplier(p_same_pair_index);
begin
  v_base := case p_source_type
    when 'personal_iou' then public.score_v2_personal_iou_ceiling(p_amount_cents)
    when 'family_obligation' then public.score_v2_personal_iou_ceiling(p_amount_cents)
    when 'phone_bill' then public.score_v2_phone_bill_ceiling(p_amount_cents, p_term_months, p_proof_tier, p_verification_tier)
    when 'utility_bill' then public.score_v2_phone_bill_ceiling(p_amount_cents, p_term_months, p_proof_tier, p_verification_tier)
    when 'rent' then public.score_v2_rent_ceiling(p_amount_cents, p_term_months, p_proof_tier, p_verification_tier, coalesce(p_metadata, '{}'::jsonb))
    when 'service_contract' then public.score_v2_contract_ceiling(p_source_type, p_amount_cents, p_term_months, p_proof_tier, p_verification_tier)
    when 'business_obligation' then public.score_v2_contract_ceiling(p_source_type, p_amount_cents, p_term_months, p_proof_tier, p_verification_tier)
    when 'receipt_split' then least(15, greatest(0, round(public.score_v2_personal_iou_ceiling(p_amount_cents) * 0.20)::integer))
    when 'lender_activity' then least(120, greatest(3, round(public.score_v2_personal_iou_ceiling(p_amount_cents) * 0.85)::integer))
    when 'landlord_activity' then least(180, greatest(5, round(public.score_v2_personal_iou_ceiling(p_amount_cents) * 1.15)::integer))
    else least(50, greatest(1, round(public.score_v2_personal_iou_ceiling(p_amount_cents) * 0.5)::integer))
  end;

  return greatest(0, round(v_base * v_pair)::integer);
end;
$function$;