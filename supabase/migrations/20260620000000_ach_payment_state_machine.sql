begin;
-- ---------------------------------------------------------------------------
-- 1. Establish one canonical payment-status constraint.
-- The two legacy constraints block processing/failed/missed/defaulted.
-- ---------------------------------------------------------------------------
alter table public.payments
  drop constraint if exists payments_status_check;
alter table public.payments
  drop constraint if exists payments_status_check_v2;
alter table public.payments
  drop constraint if exists payments_status_chk;
alter table public.payments
  add constraint payments_status_chk
  check (
    status in (
      'scheduled',
      'processing',
      'pending_confirmation',
      'paid',
      'late',
      'failed',
      'missed',
      'defaulted'
    )
  );
-- ---------------------------------------------------------------------------
-- 2. Preserve explicit processor/manual/terminal statuses.
-- Previously both trigger functions overwrote "processing" with
-- scheduled/late.
-- ---------------------------------------------------------------------------
create or replace function public.payments_status_auto()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if new.paid_at is not null then
    new.status := 'paid';
    return new;
  end if;
  if new.status in (
    'processing',
    'pending_confirmation',
    'paid',
    'failed',
    'missed',
    'defaulted'
  ) then
    return new;
  end if;
  if new.due_date < current_date then
    new.status := 'late';
  else
    new.status := 'scheduled';
  end if;
  return new;
end;
$function$;
create or replace function public.payments_status_autoupdate()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if new.paid_at is not null then
    new.status := 'paid';
    return new;
  end if;
  if new.status in (
    'processing',
    'pending_confirmation',
    'paid',
    'failed',
    'missed',
    'defaulted'
  ) then
    return new;
  end if;
  if new.due_date < current_date then
    new.status := 'late';
  else
    new.status := 'scheduled';
  end if;
  return new;
end;
$function$;
-- ---------------------------------------------------------------------------
-- 3. Private shared finalizer.
-- Both manual confirmation and processor-confirmed ACH settlement use this
-- exact receipt/status/Score path.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_payment_internal(
  p_payment_id uuid,
  p_actor_id uuid,
  p_tx_ref text default null
)
returns public.payments
language plpgsql
security definer
set search_path = public, extensions
as $function$
declare
  v_payment public.payments%rowtype;
  v_iou public.ious%rowtype;
  v_payload jsonb;
  v_hash text;
begin
  select pay.*
  into v_payment
  from public.payments pay
  where pay.id = p_payment_id
  for update;
  if not found then
    raise exception 'Payment not found: %', p_payment_id;
  end if;
  select i.*
  into v_iou
  from public.ious i
  where i.id = v_payment.iou_id
  for update;
  if not found then
    raise exception 'IOU not found for payment: %', p_payment_id;
  end if;
  -- Idempotent processor/webhook retry.
  if v_payment.status = 'paid' and v_payment.paid_at is not null then
    return v_payment;
  end if;
  update public.payments
  set
    status = 'paid',
    paid_at = now(),
    tx_ref = coalesce(nullif(btrim(p_tx_ref), ''), tx_ref),
    updated_at = now(),
    updated_by = coalesce(p_actor_id, updated_by)
  where id = p_payment_id
  returning *
  into v_payment;
  v_payload := jsonb_build_object(
    'iou_id', v_iou.id,
    'payment_id', v_payment.id,
    'amount_cents', v_payment.amount_cents,
    'payer_id', v_iou.borrower_id,
    'payee_id', v_iou.lender_id,
    'timestamp', v_payment.paid_at,
    'nonce', gen_random_uuid()
  );
  v_hash := encode(
    extensions.digest(v_payload::text, 'sha256'),
    'hex'
  );
  insert into public.payment_receipts (
    payment_id,
    iou_id,
    payer_user_id,
    payee_user_id,
    amount_cents,
    currency,
    method,
    paid_at,
    payload_json,
    receipt_hash,
    updated_by
  )
  values (
    v_payment.id,
    v_iou.id,
    v_iou.borrower_id,
    v_iou.lender_id,
    v_payment.amount_cents::integer,
    'USD',
    coalesce(v_payment.payment_method, 'manual'),
    v_payment.paid_at,
    v_payload,
    v_hash,
    p_actor_id
  )
  on conflict (payment_id) do nothing;
  perform public.refresh_iou_status(v_iou.id);
  begin
    perform public.log_payment_score_outcome_shadow(
      v_payment.id,
      p_actor_id
    );
  exception
    when others then
      raise warning
        'Shadow payment outcome logging failed for payment %: %',
        v_payment.id,
        sqlerrm;
  end;
  return v_payment;
end;
$function$;
revoke all
on function public.finalize_payment_internal(uuid, uuid, text)
from public, anon, authenticated, service_role;
grant execute
on function public.finalize_payment_internal(uuid, uuid, text)
to postgres;
-- ---------------------------------------------------------------------------
-- 4. Manual/off-platform confirmation wrapper.
-- Lender approval remains required only for manual claims.
-- ---------------------------------------------------------------------------
create or replace function public.pay_and_receipt(
  p_payment_id uuid
)
returns public.payments
language plpgsql
security definer
set search_path = public, extensions
as $function$
declare
  v_payment public.payments%rowtype;
  v_iou public.ious%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;
  select pay.*
  into v_payment
  from public.payments pay
  where pay.id = p_payment_id
  for update;
  if not found then
    raise exception 'Payment not found: %', p_payment_id;
  end if;
  select i.*
  into v_iou
  from public.ious i
  where i.id = v_payment.iou_id
  for update;
  if not found then
    raise exception 'IOU not found for payment: %', p_payment_id;
  end if;
  if auth.uid() <> v_iou.lender_id then
    raise exception 'Only the lender may confirm a manual payment'
      using errcode = '42501';
  end if;
  if v_payment.status <> 'pending_confirmation' then
    raise exception
      'Manual payment is not pending confirmation: %',
      v_payment.status;
  end if;
  if coalesce(v_payment.payment_method, 'manual') <> 'manual' then
    raise exception
      'ACH payments cannot be lender-confirmed'
      using errcode = '42501';
  end if;
  return public.finalize_payment_internal(
    p_payment_id,
    auth.uid(),
    null
  );
end;
$function$;
revoke all
on function public.pay_and_receipt(uuid)
from public, anon;
grant execute
on function public.pay_and_receipt(uuid)
to authenticated, service_role, postgres;
-- ---------------------------------------------------------------------------
-- 5. Borrower ACH initiation.
-- No lender confirmation and no pending_confirmation state.
-- ---------------------------------------------------------------------------
create or replace function public.initiate_ach_payment(
  p_payment_id uuid
)
returns public.payments
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_uid uuid := auth.uid();
  v_payment public.payments%rowtype;
  v_iou public.ious%rowtype;
begin
  if v_uid is null then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;
  select pay.*
  into v_payment
  from public.payments pay
  where pay.id = p_payment_id
  for update;
  if not found then
    raise exception 'Payment not found: %', p_payment_id;
  end if;
  select i.*
  into v_iou
  from public.ious i
  where i.id = v_payment.iou_id
  for update;
  if not found then
    raise exception 'IOU not found for payment: %', p_payment_id;
  end if;
  if v_uid <> v_iou.borrower_id then
    raise exception 'Only the borrower may initiate this payment'
      using errcode = '42501';
  end if;
  if v_iou.activated_at is null then
    raise exception 'The IOU has not been activated';
  end if;
  if not exists (
    select 1
    from public.profiles p
    where p.id = v_iou.borrower_id
      and p.ach_status = 'ready'
  ) then
    raise exception 'Borrower ACH setup is not ready';
  end if;
  if not exists (
    select 1
    from public.profiles p
    where p.id = v_iou.lender_id
      and p.ach_status = 'ready'
  ) then
    raise exception 'Lender ACH setup is not ready';
  end if;
  if v_payment.paid_at is not null
     or v_payment.status not in ('scheduled', 'late') then
    raise exception
      'Payment cannot be initiated from status: %',
      v_payment.status;
  end if;
  update public.payments
  set
    status = 'processing',
    payment_method = 'ach',
    initiated_at = now(),
    claimed_paid_at = null,
    claimed_by = null,
    confirmed_paid_at = null,
    confirmed_by = null,
    updated_at = now(),
    updated_by = v_uid
  where id = p_payment_id
  returning *
  into v_payment;
  return v_payment;
end;
$function$;
revoke all
on function public.initiate_ach_payment(uuid)
from public, anon;
grant execute
on function public.initiate_ach_payment(uuid)
to authenticated, service_role, postgres;
-- ---------------------------------------------------------------------------
-- 6. Processor/service-role ACH settlement.
-- Duplicate webhook delivery is idempotent.
-- ---------------------------------------------------------------------------
create or replace function public.complete_ach_payment(
  p_payment_id uuid,
  p_transfer_id text
)
returns public.payments
language plpgsql
security definer
set search_path = public, extensions
as $function$
declare
  v_payment public.payments%rowtype;
  v_request_role text;
begin
  v_request_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (
      nullif(current_setting('request.jwt.claims', true), '')::jsonb
      ->> 'role'
    ),
    ''
  );
  if v_request_role <> 'service_role'
     and session_user <> 'postgres' then
    raise exception 'Service-role settlement required'
      using errcode = '42501';
  end if;
  if nullif(btrim(p_transfer_id), '') is null then
    raise exception 'Processor transfer ID is required';
  end if;
  select pay.*
  into v_payment
  from public.payments pay
  where pay.id = p_payment_id
  for update;
  if not found then
    raise exception 'Payment not found: %', p_payment_id;
  end if;
  if v_payment.status = 'paid'
     and v_payment.payment_method = 'ach'
     and v_payment.paid_at is not null then
    return v_payment;
  end if;
  if v_payment.status <> 'processing'
     or v_payment.payment_method <> 'ach' then
    raise exception
      'ACH payment is not processing: status=%, method=%',
      v_payment.status,
      v_payment.payment_method;
  end if;
  return public.finalize_payment_internal(
    p_payment_id,
    null,
    p_transfer_id
  );
end;
$function$;
revoke all
on function public.complete_ach_payment(uuid, text)
from public, anon, authenticated;
grant execute
on function public.complete_ach_payment(uuid, text)
to service_role, postgres;
commit;
