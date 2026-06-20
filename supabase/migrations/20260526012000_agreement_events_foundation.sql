-- IOU Score v2 — Agreement Events Foundation
-- Universal black box recorder for IOU agreements.
--
-- No profile score changes.
-- No score event changes.
-- No trigger switch.
--
-- Purpose:
-- Track agreement lifecycle events so IOU can learn over time:
-- creation, acceptance, edits, payments, extensions, disputes, completion, default, recovery.

create table if not exists public.agreement_events (
  id uuid primary key default gen_random_uuid(),

  user_id uuid null references public.profiles(id) on delete set null,
  actor_id uuid null references public.profiles(id) on delete set null,
  counterparty_id uuid null references public.profiles(id) on delete set null,

  score_agreement_id uuid null references public.score_agreements(id) on delete set null,

  source_type text null,
  source_id uuid null,

  event_type text not null check (
    event_type in (
      'agreement_created',
      'agreement_invited',
      'agreement_viewed',
      'agreement_accepted',
      'agreement_declined',
      'agreement_cancelled',
      'agreement_archived',
      'agreement_restored',
      'agreement_completed',
      'agreement_defaulted',

      'terms_proposed',
      'terms_changed',
      'amount_changed',
      'apr_changed',
      'schedule_changed',
      'due_date_changed',

      'payment_due',
      'payment_attempt_started',
      'payment_attempt_failed',
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late',
      'payment_partial',
      'payment_confirmed',
      'payment_rejected',
      'payment_reversed',

      'extension_requested',
      'extension_approved',
      'extension_denied',
      'extension_counteroffered',

      'dispute_opened',
      'dispute_updated',
      'dispute_resolved',

      'strike_applied',
      'strike_expired',
      'recovery_progress',

      'rent_month_verified',
      'rent_month_missed',
      'phone_bill_verified',
      'phone_bill_missed',

      'relationship_mode_applied',
      'risk_flag_created',
      'risk_flag_resolved'
    )
  ),

  event_at timestamptz not null default now(),

  amount_cents bigint null,
  previous_amount_cents bigint null,

  apr_bps integer null,
  previous_apr_bps integer null,

  due_at timestamptz null,
  previous_due_at timestamptz null,

  days_early integer null,
  days_late integer null,

  proof_tier integer null check (proof_tier is null or proof_tier between 0 and 4),
  verification_tier integer null check (verification_tier is null or verification_tier between 0 and 4),

  relationship_mode text null,

  score_model_version text null,
  risk_model_version text null,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);

create index if not exists agreement_events_user_created_idx
on public.agreement_events (user_id, created_at desc);

create index if not exists agreement_events_actor_created_idx
on public.agreement_events (actor_id, created_at desc);

create index if not exists agreement_events_counterparty_created_idx
on public.agreement_events (counterparty_id, created_at desc);

create index if not exists agreement_events_score_agreement_idx
on public.agreement_events (score_agreement_id);

create index if not exists agreement_events_source_idx
on public.agreement_events (source_type, source_id);

create index if not exists agreement_events_type_idx
on public.agreement_events (event_type);

create index if not exists agreement_events_event_at_idx
on public.agreement_events (event_at desc);


create or replace function public.log_agreement_event(
  p_user_id uuid,
  p_actor_id uuid,
  p_counterparty_id uuid,
  p_score_agreement_id uuid,
  p_source_type text,
  p_source_id uuid,
  p_event_type text,
  p_amount_cents bigint default null,
  p_previous_amount_cents bigint default null,
  p_apr_bps integer default null,
  p_previous_apr_bps integer default null,
  p_due_at timestamptz default null,
  p_previous_due_at timestamptz default null,
  p_days_early integer default null,
  p_days_late integer default null,
  p_proof_tier integer default null,
  p_verification_tier integer default null,
  p_relationship_mode text default null,
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
  insert into public.agreement_events (
    user_id,
    actor_id,
    counterparty_id,
    score_agreement_id,
    source_type,
    source_id,
    event_type,
    amount_cents,
    previous_amount_cents,
    apr_bps,
    previous_apr_bps,
    due_at,
    previous_due_at,
    days_early,
    days_late,
    proof_tier,
    verification_tier,
    relationship_mode,
    score_model_version,
    risk_model_version,
    metadata
  )
  values (
    p_user_id,
    p_actor_id,
    p_counterparty_id,
    p_score_agreement_id,
    p_source_type,
    p_source_id,
    p_event_type,
    p_amount_cents,
    p_previous_amount_cents,
    p_apr_bps,
    p_previous_apr_bps,
    p_due_at,
    p_previous_due_at,
    p_days_early,
    p_days_late,
    p_proof_tier,
    p_verification_tier,
    p_relationship_mode,
    'v2.0-shadow',
    'v0.1-shadow',
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_event_id;

  return v_event_id;
end;
$function$;


-- Optional helper: backfill agreement_created events for existing shadow score agreements.
-- This is audit history only. It does not change score.
insert into public.agreement_events (
  user_id,
  actor_id,
  counterparty_id,
  score_agreement_id,
  source_type,
  source_id,
  event_type,
  amount_cents,
  apr_bps,
  proof_tier,
  verification_tier,
  relationship_mode,
  score_model_version,
  risk_model_version,
  metadata,
  event_at
)
select
  sa.user_id,
  sa.user_id,
  sa.counterparty_id,
  sa.id,
  sa.source_type,
  sa.source_id,
  'agreement_created',
  sa.amount_cents,
  nullif((sa.metadata->>'apr_bps')::integer, null),
  sa.proof_tier,
  sa.verification_tier,
  public.get_relationship_mode(sa.user_id, sa.counterparty_id),
  'v2.0-shadow',
  'v0.1-shadow',
  jsonb_build_object(
    'shadow_backfill', true,
    'source_table', 'score_agreements',
    'agreement_status', sa.status,
    'score_ceiling', sa.score_ceiling,
    'same_pair_index', sa.same_pair_index,
    'same_pair_multiplier', sa.same_pair_multiplier
  ),
  coalesce(sa.activated_at, sa.created_at)
from public.score_agreements sa
where sa.source_type = 'personal_iou'
  and not exists (
    select 1
    from public.agreement_events ae
    where ae.score_agreement_id = sa.id
      and ae.event_type = 'agreement_created'
  );