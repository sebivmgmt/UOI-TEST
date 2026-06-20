-- IOU Score v2 — pay_and_receipt shadow outcome logging
--
-- Backend-only shadow logging.
-- No live score mutation.
-- No profile score changes.
-- No frontend changes.
-- No claim_payment logging yet.
--
-- Purpose:
-- When a lender confirms a payment through pay_and_receipt(),
-- record the real payment outcome into trust_outcome_events/agreement_events.

create or replace function public.log_payment_score_outcome_shadow(
  p_payment_id uuid,
  p_actor_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_payment public.payments%rowtype;
  v_iou public.ious%rowtype;
  v_score_agreement_id uuid;
  v_due_date date;
  v_paid_date date;
  v_days_early integer := null;
  v_days_late integer := null;
  v_outcome_type text;
  v_payment_outcome jsonb := null;
  v_completion_outcome jsonb := null;
  v_unpaid_count integer := 0;
begin
  if p_payment_id is null then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'missing_payment_id'
    );
  end if;

  select *
  into v_payment
  from public.payments
  where id = p_payment_id;

  if not found then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'payment_not_found',
      'payment_id', p_payment_id
    );
  end if;

  if v_payment.paid_at is null or v_payment.status is distinct from 'paid' then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'payment_not_paid',
      'payment_id', v_payment.id,
      'status', v_payment.status
    );
  end if;

  select *
  into v_iou
  from public.ious
  where id = v_payment.iou_id;

  if not found then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'iou_not_found',
      'payment_id', v_payment.id,
      'iou_id', v_payment.iou_id
    );
  end if;

  select sa.id
  into v_score_agreement_id
  from public.score_agreements sa
  where sa.source_type = 'personal_iou'
    and sa.source_id = v_iou.id
  order by sa.created_at desc nulls last, sa.id
  limit 1;

  if v_score_agreement_id is null then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'score_agreement_not_found',
      'payment_id', v_payment.id,
      'iou_id', v_iou.id
    );
  end if;

  -- Idempotency: one payment outcome per payment id.
  if exists (
    select 1
    from public.trust_outcome_events toe
    where toe.score_agreement_id = v_score_agreement_id
      and toe.outcome_type in (
        'payment_paid_early',
        'payment_paid_on_time',
        'payment_paid_late'
      )
      and toe.metadata->>'payment_id' = v_payment.id::text
  ) then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'payment_outcome_already_logged',
      'payment_id', v_payment.id,
      'score_agreement_id', v_score_agreement_id
    );
  end if;

  v_due_date := v_payment.due_date;
  v_paid_date := (v_payment.paid_at at time zone 'UTC')::date;

  if v_paid_date < v_due_date then
    v_outcome_type := 'payment_paid_early';
    v_days_early := v_due_date - v_paid_date;
    v_days_late := null;
  elsif v_paid_date = v_due_date then
    v_outcome_type := 'payment_paid_on_time';
    v_days_early := 0;
    v_days_late := 0;
  else
    v_outcome_type := 'payment_paid_late';
    v_days_early := null;
    v_days_late := v_paid_date - v_due_date;
  end if;

  v_payment_outcome := public.log_score_agreement_outcome(
    v_score_agreement_id,
    v_outcome_type,
    p_actor_id,
    v_payment.amount_cents,
    v_days_early,
    v_days_late,
    jsonb_build_object(
      'payment_id', v_payment.id,
      'iou_id', v_iou.id,
      'due_date', v_payment.due_date,
      'paid_at', v_payment.paid_at,
      'payment_status', v_payment.status,
      'payment_method', coalesce(v_payment.payment_method, 'manual'),
      'trigger', 'pay_and_receipt',
      'shadow_mode', true
    )
  );

  select count(*)
  into v_unpaid_count
  from public.payments p
  where p.iou_id = v_iou.id
    and (
      p.status is distinct from 'paid'
      or p.paid_at is null
    );

  if v_unpaid_count = 0
    and not exists (
      select 1
      from public.trust_outcome_events toe
      where toe.score_agreement_id = v_score_agreement_id
        and toe.outcome_type = 'agreement_completed'
    )
  then
    v_completion_outcome := public.log_score_agreement_outcome(
      v_score_agreement_id,
      'agreement_completed',
      p_actor_id,
      v_iou.principal_cents,
      null,
      null,
      jsonb_build_object(
        'iou_id', v_iou.id,
        'completed_by_payment_id', v_payment.id,
        'trigger', 'pay_and_receipt',
        'shadow_mode', true
      )
    );
  end if;

  return jsonb_build_object(
    'recorded', true,
    'payment_outcome', v_payment_outcome,
    'completion_outcome', v_completion_outcome,
    'payment_id', v_payment.id,
    'iou_id', v_iou.id,
    'score_agreement_id', v_score_agreement_id,
    'outcome_type', v_outcome_type
  );
end;
$function$;


create or replace function public.pay_and_receipt(p_payment_id uuid)
returns payments
language plpgsql
security definer
set search_path to 'public', 'extensions'
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
    raise exception 'Linked IOU not found';
  end if;

  if auth.uid() is distinct from v_iou.lender_id then
    raise exception 'Only the lender may confirm this payment';
  end if;

  if v_payment.status is distinct from 'pending_confirmation' then
    raise exception 'Only pending confirmation payments can be confirmed';
  end if;

  update public.payments pay
  set
    status = 'paid',
    paid_at = now(),
    updated_at = now(),
    updated_by = auth.uid()
  where pay.id = p_payment_id
  returning pay.* into v_payment;

  v_payload := jsonb_build_object(
    'iou_id', v_payment.iou_id,
    'payment_id', v_payment.id,
    'amount_cents', v_payment.amount_cents,
    'payer_id', v_iou.borrower_id,
    'payee_id', v_iou.lender_id,
    'timestamp', v_payment.paid_at,
    'nonce', gen_random_uuid()
  );

  v_hash := encode(
    extensions.digest(convert_to(v_payload::text, 'UTF8'), 'sha256'),
    'hex'
  );

  insert into public.payment_receipts (
    payment_id,
    iou_id,
    amount_cents,
    currency,
    method,
    paid_at,
    payload_json,
    receipt_hash
  )
  values (
    v_payment.id,
    v_payment.iou_id,
    v_payment.amount_cents,
    'USD',
    coalesce(v_payment.payment_method, 'manual'),
    v_payment.paid_at,
    v_payload,
    v_hash
  )
  on conflict (payment_id) do nothing;

  perform public.refresh_iou_status(v_payment.iou_id);

  -- Shadow outcome logging must never block payment confirmation.
  begin
    perform public.log_payment_score_outcome_shadow(v_payment.id, auth.uid());
  exception when others then
    raise notice 'Shadow payment outcome logging failed for payment %: %', v_payment.id, sqlerrm;
  end;

  return v_payment;
end;
$function$;