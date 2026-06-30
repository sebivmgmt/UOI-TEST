begin;

-- ============================================================================
-- Payment-extension state machine
--
-- Canonical rule:
--   payments.due_date is the enforceable payment deadline.
--
-- An approved extension therefore changes due_date atomically. Existing
-- payment triggers then synchronize due_at/status, and every Score v2 path
-- continues to consume the same canonical deadline.
-- ============================================================================

alter table public.payments
  add column if not exists extension_original_due_date date;

alter table public.payments
  add column if not exists extension_request_id uuid;

comment on column public.payments.extension_original_due_date is
  'Canonical due_date captured when the currently displayed extension request was submitted.';

comment on column public.payments.extension_request_id is
  'Identifier linking the current/latest payment extension state to its append-only audit events.';

-- ============================================================================
-- Append-only extension audit ledger
-- ============================================================================

create table if not exists public.payment_extension_events (
  id uuid primary key default extensions.gen_random_uuid(),
  request_id uuid not null,
  payment_id uuid not null
    references public.payments(id) on delete restrict,
  iou_id uuid not null
    references public.ious(id) on delete restrict,
  actor_id uuid not null
    references auth.users(id) on delete restrict,
  event_type text not null
    check (event_type in ('requested', 'approved', 'denied')),
  original_due_date date not null,
  requested_until date not null,
  reason text null
    check (reason is null or char_length(reason) <= 1000),
  created_at timestamptz not null default now()
);

create index if not exists payment_extension_events_payment_created_idx
  on public.payment_extension_events(payment_id, created_at desc);

create index if not exists payment_extension_events_iou_created_idx
  on public.payment_extension_events(iou_id, created_at desc);

create unique index if not exists payment_extension_events_one_request_idx
  on public.payment_extension_events(request_id)
  where event_type = 'requested';

create unique index if not exists payment_extension_events_one_decision_idx
  on public.payment_extension_events(request_id)
  where event_type in ('approved', 'denied');

alter table public.payment_extension_events enable row level security;

drop policy if exists payment_extension_events_select_parties
  on public.payment_extension_events;

create policy payment_extension_events_select_parties
on public.payment_extension_events
for select
to authenticated
using (
  exists (
    select 1
    from public.ious i
    where i.id = payment_extension_events.iou_id
      and auth.uid() in (i.lender_id, i.borrower_id)
  )
);

revoke all
on table public.payment_extension_events
from public, anon, authenticated, service_role;

grant select
on table public.payment_extension_events
to authenticated, service_role;

comment on table public.payment_extension_events is
  'Append-only audit history for every payment extension request and decision.';

create or replace function public.block_payment_extension_event_mutation()
returns trigger
language plpgsql
set search_path = 'public'
as $function$
begin
  raise exception 'Payment extension events are append-only.'
    using errcode = '42501';
end;
$function$;

revoke all
on function public.block_payment_extension_event_mutation()
from public, anon, authenticated, service_role;

drop trigger if exists payment_extension_events_block_mutation
on public.payment_extension_events;

create trigger payment_extension_events_block_mutation
before update or delete
on public.payment_extension_events
for each row
execute function public.block_payment_extension_event_mutation();

-- ============================================================================
-- Borrower request RPC
-- ============================================================================

create or replace function public.request_payment_extension(
  p_payment_id uuid,
  p_requested_until date,
  p_reason text default null
)
returns public.payments
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $function$
declare
  v_actor uuid;
  v_payment public.payments%rowtype;
  v_iou public.ious%rowtype;
  v_updated public.payments%rowtype;
  v_request_id uuid;
  v_reason text;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'Authentication required.'
      using errcode = '42501';
  end if;

  if p_requested_until is null then
    raise exception 'An extension date is required.';
  end if;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');

  if v_reason is not null and char_length(v_reason) > 1000 then
    raise exception 'Extension reason cannot exceed 1000 characters.';
  end if;

  select p.*
  into v_payment
  from public.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment not found.';
  end if;

  select i.*
  into v_iou
  from public.ious i
  where i.id = v_payment.iou_id
  for update;

  if not found then
    raise exception 'Linked IOU not found.';
  end if;

  if v_actor is distinct from v_iou.borrower_id then
    raise exception 'Only the borrower can request a payment extension.'
      using errcode = '42501';
  end if;

  if v_iou.activated_at is null
     or v_iou.deleted_at is not null
     or v_iou.archived_at is not null
     or lower(coalesce(v_iou.status, '')) not in ('open', 'late')
  then
    raise exception 'This IOU is not eligible for payment extensions.';
  end if;

  if v_payment.paid_at is not null
     or lower(coalesce(v_payment.status, '')) not in ('scheduled', 'late')
  then
    raise exception 'This payment is not eligible for an extension.';
  end if;

  if coalesce(v_payment.extension_status, 'none') = 'requested' then
    raise exception 'This payment already has a pending extension request.';
  end if;

  if coalesce(v_payment.extension_status, 'none') = 'approved' then
    raise exception 'This payment has already received an approved extension.';
  end if;

  if p_requested_until <= v_payment.due_date then
    raise exception 'The extension date must be later than the current due date.';
  end if;

  if p_requested_until > v_payment.due_date + 14 then
    raise exception 'A payment may be extended by no more than 14 days.';
  end if;

  if p_requested_until <= current_date then
    raise exception 'The extension date must be in the future.';
  end if;

  v_request_id := extensions.gen_random_uuid();

  update public.payments
  set
    extension_request_id = v_request_id,
    extension_original_due_date = v_payment.due_date,
    extension_requested_at = now(),
    extension_requested_by = v_actor,
    extension_requested_until = p_requested_until,
    extension_status = 'requested',
    extension_reason = v_reason,
    extension_decision_at = null,
    extension_decided_by = null,
    updated_at = now(),
    updated_by = v_actor
  where id = p_payment_id
  returning *
  into v_updated;

  insert into public.payment_extension_events (
    request_id,
    payment_id,
    iou_id,
    actor_id,
    event_type,
    original_due_date,
    requested_until,
    reason
  )
  values (
    v_request_id,
    v_updated.id,
    v_updated.iou_id,
    v_actor,
    'requested',
    v_updated.extension_original_due_date,
    v_updated.extension_requested_until,
    v_updated.extension_reason
  );

  return v_updated;
end;
$function$;

revoke all
on function public.request_payment_extension(uuid, date, text)
from public, anon, authenticated, service_role;

grant execute
on function public.request_payment_extension(uuid, date, text)
to authenticated, service_role;

comment on function public.request_payment_extension(uuid, date, text) is
  'Borrower-only request transition for an eligible unpaid payment.';

-- ============================================================================
-- Lender decision RPC
-- ============================================================================

create or replace function public.decide_payment_extension(
  p_payment_id uuid,
  p_decision text
)
returns public.payments
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $function$
declare
  v_actor uuid;
  v_decision text;
  v_payment public.payments%rowtype;
  v_iou public.ious%rowtype;
  v_updated public.payments%rowtype;
begin
  v_actor := auth.uid();
  v_decision := lower(btrim(coalesce(p_decision, '')));

  if v_actor is null then
    raise exception 'Authentication required.'
      using errcode = '42501';
  end if;

  if v_decision not in ('approved', 'denied') then
    raise exception 'Decision must be approved or denied.';
  end if;

  select p.*
  into v_payment
  from public.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment not found.';
  end if;

  select i.*
  into v_iou
  from public.ious i
  where i.id = v_payment.iou_id
  for update;

  if not found then
    raise exception 'Linked IOU not found.';
  end if;

  if v_actor is distinct from v_iou.lender_id then
    raise exception 'Only the lender can decide a payment extension.'
      using errcode = '42501';
  end if;

  if v_iou.activated_at is null
     or v_iou.deleted_at is not null
     or v_iou.archived_at is not null
     or lower(coalesce(v_iou.status, '')) not in ('open', 'late')
  then
    raise exception 'This IOU is not eligible for payment extensions.';
  end if;

  if v_payment.paid_at is not null
     or lower(coalesce(v_payment.status, '')) not in ('scheduled', 'late')
  then
    raise exception 'This payment is no longer eligible for an extension decision.';
  end if;

  if coalesce(v_payment.extension_status, 'none') <> 'requested' then
    raise exception 'This payment does not have a pending extension request.';
  end if;

  if v_payment.extension_request_id is null
     or v_payment.extension_original_due_date is null
     or v_payment.extension_requested_until is null
     or v_payment.extension_requested_by is null
  then
    raise exception 'The pending extension request is incomplete.';
  end if;

  if v_payment.due_date is distinct from v_payment.extension_original_due_date then
    raise exception 'The payment due date changed after this extension was requested.';
  end if;

  if v_payment.extension_requested_until <= v_payment.extension_original_due_date then
    raise exception 'The requested extension date is invalid.';
  end if;

  if v_payment.extension_requested_until >
     v_payment.extension_original_due_date + 14
  then
    raise exception 'The requested extension exceeds the 14-day limit.';
  end if;

  if v_decision = 'approved' then
    if v_payment.extension_requested_until <= current_date then
      raise exception 'The requested extension date is no longer in the future.';
    end if;

    update public.payments
    set
      due_date = v_payment.extension_requested_until,
      extension_status = 'approved',
      extension_decision_at = now(),
      extension_decided_by = v_actor,
      updated_at = now(),
      updated_by = v_actor
    where id = p_payment_id
    returning *
    into v_updated;
  else
    update public.payments
    set
      extension_status = 'denied',
      extension_decision_at = now(),
      extension_decided_by = v_actor,
      updated_at = now(),
      updated_by = v_actor
    where id = p_payment_id
    returning *
    into v_updated;
  end if;

  insert into public.payment_extension_events (
    request_id,
    payment_id,
    iou_id,
    actor_id,
    event_type,
    original_due_date,
    requested_until,
    reason
  )
  values (
    v_updated.extension_request_id,
    v_updated.id,
    v_updated.iou_id,
    v_actor,
    v_decision,
    v_updated.extension_original_due_date,
    v_updated.extension_requested_until,
    v_updated.extension_reason
  );

  perform public.refresh_iou_status(v_updated.iou_id);

  return v_updated;
end;
$function$;

revoke all
on function public.decide_payment_extension(uuid, text)
from public, anon, authenticated, service_role;

grant execute
on function public.decide_payment_extension(uuid, text)
to authenticated, service_role;

comment on function public.decide_payment_extension(uuid, text) is
  'Lender-only extension decision. Approval atomically replaces the canonical payment due_date.';

-- ============================================================================
-- Client mutation hardening
--
-- Payment writes must occur through reviewed SECURITY DEFINER state transitions.
-- Existing permissive RLS policies alone are insufficient because permissive
-- policies combine with OR semantics.
-- ============================================================================

revoke update
on table public.payments
from public, anon, authenticated;

-- payment_receipts are created by finalize_payment_internal. Clients only read.
revoke insert, update, delete
on table public.payment_receipts
from public, anon, authenticated;

-- Normalize exposed payment mutation functions.
revoke all
on function public.claim_payment(uuid, uuid)
from public, anon, authenticated, service_role;

grant execute
on function public.claim_payment(uuid, uuid)
to authenticated, service_role;

revoke all
on function public.reject_payment(uuid)
from public, anon, authenticated, service_role;

grant execute
on function public.reject_payment(uuid)
to authenticated, service_role;

-- Internal status recomputation helper. Reviewed SECURITY DEFINER functions
-- and triggers execute it as the owner; clients must not call it directly.
revoke all
on function public.refresh_iou_status(uuid)
from public, anon, authenticated, service_role;

grant execute
on function public.refresh_iou_status(uuid)
to postgres;

commit;
