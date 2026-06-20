create or replace function public.apply_payment_score_event()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_iou public.ious%rowtype;
  v_due_date date;
  v_paid_date date;
  v_reward integer := 0;
  v_event_type text;
  v_desc text;
  v_unpaid_count integer := 0;
  v_default_already_applied boolean := false;
begin
  select *
  into v_iou
  from public.ious
  where id = new.iou_id;

  if not found or v_iou.borrower_id is null then
    return new;
  end if;

  if coalesce(new.failed_attempts, 0) >= 8
     and (
       tg_op = 'INSERT'
       or coalesce(old.failed_attempts, 0) < 8
     ) then

    select exists (
      select 1
      from public.score_events
      where iou_id = new.iou_id
        and event_type in ('strike_1', 'strike_2', 'strike_3')
    )
    into v_default_already_applied;

    if not coalesce(v_default_already_applied, false) then
      perform public.apply_default_strike(
        v_iou.borrower_id,
        v_iou.id,
        'Payment default: failed attempts reached 8'
      );
    end if;

    return new;
  end if;

  if new.paid_at is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.paid_at is not null then
    return new;
  end if;

  v_due_date :=
    coalesce(
      new.due_date,
      new.due_at::date,
      new.scheduled_at
    );

  if v_due_date is null then
    return new;
  end if;

  v_paid_date := new.paid_at::date;

  if v_paid_date < v_due_date then
    v_reward := public.iou_score_medium_early_reward();
    v_event_type := 'payment_early';
    v_desc := 'Early payment confirmed';

  elsif v_paid_date = v_due_date then
    v_reward := public.iou_score_small_on_time_reward();
    v_event_type := 'payment_on_time';
    v_desc := 'On-time payment confirmed';

  else
    v_reward := 0;
    v_event_type := 'payment_late';
    v_desc := 'Late payment confirmed';
  end if;

  if v_reward <> 0 then
    perform public.apply_score_event_once(
      v_iou.borrower_id,
      v_event_type,
      v_reward,
      v_desc,
      v_iou.id,
      new.id,
      'payment:' || new.id::text || ':' || v_event_type
    );
  end if;

  select count(*)
  into v_unpaid_count
  from public.payments
  where iou_id = new.iou_id
    and paid_at is null;

  if coalesce(v_unpaid_count, 0) = 0 then
    perform public.apply_score_event_once(
      v_iou.borrower_id,
      'loan_completed',
      public.iou_score_large_completion_reward(),
      'Loan completed',
      v_iou.id,
      new.id,
      'completion:' || v_iou.id::text
    );
  end if;

  return new;
end;
$function$;