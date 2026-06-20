-- IOU Score v2 — Trust Outcome Bridge
-- Connects real outcomes to Score v2 shadow agreements.
--
-- No profile score changes.
-- No live scoring switch.
-- No trigger wiring yet.
--
-- Purpose:
-- Record actual trust outcomes so IOU can compare predictions to reality over time.

create or replace function public.log_trust_outcome_event(
  p_user_id uuid,
  p_score_agreement_id uuid default null,
  p_source_type text default null,
  p_source_id uuid default null,
  p_outcome_type text default null,
  p_amount_cents bigint default null,
  p_days_early integer default null,
  p_days_late integer default null,
  p_proof_tier integer default null,
  p_verification_tier integer default null,
  p_related_snapshot_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event_id uuid;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  if p_outcome_type is null then
    raise exception 'Missing outcome type';
  end if;

  insert into public.trust_outcome_events (
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    amount_cents,
    days_early,
    days_late,
    proof_tier,
    verification_tier,
    related_snapshot_id,
    metadata
  )
  values (
    p_user_id,
    p_score_agreement_id,
    p_source_type,
    p_source_id,
    p_outcome_type,
    p_amount_cents,
    p_days_early,
    p_days_late,
    p_proof_tier,
    p_verification_tier,
    p_related_snapshot_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_event_id;

  return v_event_id;
end;
$function$;


create or replace function public.log_score_agreement_outcome(
  p_score_agreement_id uuid,
  p_outcome_type text,
  p_actor_id uuid default null,
  p_amount_cents bigint default null,
  p_days_early integer default null,
  p_days_late integer default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_agreement public.score_agreements%rowtype;
  v_outcome_id uuid;
  v_agreement_event_id uuid;
  v_relationship_mode text;
begin
  if p_score_agreement_id is null then
    raise exception 'Missing score agreement id';
  end if;

  if p_outcome_type is null then
    raise exception 'Missing outcome type';
  end if;

  select *
  into v_agreement
  from public.score_agreements
  where id = p_score_agreement_id;

  if not found then
    raise exception 'Score agreement not found: %', p_score_agreement_id;
  end if;

  v_relationship_mode := public.get_relationship_mode(
    v_agreement.user_id,
    v_agreement.counterparty_id
  );

  v_outcome_id := public.log_trust_outcome_event(
    v_agreement.user_id,
    v_agreement.id,
    v_agreement.source_type,
    v_agreement.source_id,
    p_outcome_type,
    coalesce(p_amount_cents, v_agreement.amount_cents),
    p_days_early,
    p_days_late,
    v_agreement.proof_tier,
    v_agreement.verification_tier,
    null,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'score_ceiling_at_outcome', v_agreement.score_ceiling,
      'score_contributed_at_outcome', v_agreement.score_contributed,
      'same_pair_index', v_agreement.same_pair_index,
      'same_pair_multiplier', v_agreement.same_pair_multiplier,
      'relationship_mode', v_relationship_mode,
      'shadow_mode', true
    )
  );

  v_agreement_event_id := public.log_agreement_event(
    v_agreement.user_id,
    coalesce(p_actor_id, v_agreement.user_id),
    v_agreement.counterparty_id,
    v_agreement.id,
    v_agreement.source_type,
    v_agreement.source_id,
    p_outcome_type,
    coalesce(p_amount_cents, v_agreement.amount_cents),
    null,
    null,
    null,
    null,
    null,
    p_days_early,
    p_days_late,
    v_agreement.proof_tier,
    v_agreement.verification_tier,
    v_relationship_mode,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'trust_outcome_event_id', v_outcome_id,
      'score_ceiling_at_outcome', v_agreement.score_ceiling,
      'shadow_mode', true
    )
  );

  return jsonb_build_object(
    'trust_outcome_event_id', v_outcome_id,
    'agreement_event_id', v_agreement_event_id,
    'score_agreement_id', v_agreement.id,
    'outcome_type', p_outcome_type,
    'relationship_mode', v_relationship_mode
  );
end;
$function$;