begin;

-- ============================================================================
-- Atomic Personal IOU creation
--
-- New agreements and their complete payment schedules are created by one
-- SECURITY DEFINER statement. Any exception rolls back the IOU, every payment,
-- trigger side effects, and state-policy snapshots together.
--
-- The database generates the canonical installment dates and amounts from the
-- agreement terms. The client does not supply authoritative payment rows.
-- ============================================================================

create or replace function public.create_iou_with_schedule(
  p_title text,
  p_lender_id uuid,
  p_borrower_id uuid,
  p_principal_cents bigint,
  p_apr_bps integer,
  p_start_date date,
  p_term_months integer,
  p_frequency text,
  p_terms_version text,
  p_privacy_version text
)
returns table (
  id uuid,
  status text,
  total_installments integer,
  scheduled_count bigint
)
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $function$
declare
  v_actor uuid;
  v_title text;
  v_frequency text;

  v_periods integer;
  v_periods_per_year integer;

  v_rate_per_period numeric;
  v_raw_payment_cents numeric;
  v_base_payment_cents bigint;
  v_target_total_cents bigint;
  v_last_payment_cents bigint;

  v_iou_id uuid;
  v_inserted_count bigint;
  v_inserted_total bigint;
begin
  v_actor := auth.uid();
  v_title := btrim(coalesce(p_title, ''));
  v_frequency := lower(btrim(coalesce(p_frequency, '')));

  if v_actor is null then
    raise exception 'Authentication required.'
      using errcode = '42501';
  end if;

  if p_lender_id is null or p_borrower_id is null then
    raise exception 'Lender and borrower are required.'
      using errcode = '22023';
  end if;

  if p_lender_id = p_borrower_id then
    raise exception 'Lender and borrower must be different accounts.'
      using errcode = '22023';
  end if;

  if v_actor not in (p_lender_id, p_borrower_id) then
    raise exception 'The authenticated user must be a party to the IOU.'
      using errcode = '42501';
  end if;

  if v_title = '' then
    raise exception 'An IOU title is required.'
      using errcode = '22023';
  end if;

  if p_principal_cents is null or p_principal_cents <= 0 then
    raise exception 'Principal must be greater than zero.'
      using errcode = '22023';
  end if;

  if p_apr_bps is null or p_apr_bps < 0 then
    raise exception 'APR must be a non-negative integer number of basis points.'
      using errcode = '22023';
  end if;

  if p_start_date is null then
    raise exception 'A first payment date is required.'
      using errcode = '22023';
  end if;

  if p_start_date < current_date then
    raise exception 'First payment date cannot be in the past.'
      using errcode = '22023';
  end if;

  if p_term_months is null or p_term_months < 1 then
    raise exception 'Term must be at least one month.'
      using errcode = '22023';
  end if;

  if v_frequency not in ('weekly', 'biweekly', 'monthly') then
    raise exception 'Frequency must be weekly, biweekly, or monthly.'
      using errcode = '22023';
  end if;

  -- The app and database must advance legal-document versions together.
  -- A version mismatch fails closed rather than accepting an obsolete document.
  if btrim(coalesce(p_terms_version, '')) <> '2026-05-03'
     or btrim(coalesce(p_privacy_version, '')) <> '2026-05-03'
  then
    raise exception 'The current Terms of Service and Privacy Policy are required.'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.legal_acceptances la
    where la.user_id = v_actor
      and la.document_type = 'terms_of_service'
      and la.document_version = '2026-05-03'
      and la.context = 'new_iou_flow'
  ) then
    raise exception 'Current Terms of Service acceptance is required.'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.legal_acceptances la
    where la.user_id = v_actor
      and la.document_type = 'privacy_policy'
      and la.document_version = '2026-05-03'
      and la.context = 'new_iou_flow'
  ) then
    raise exception 'Current Privacy Policy acceptance is required.'
      using errcode = '42501';
  end if;

  if v_frequency = 'monthly' then
    v_periods := p_term_months;
    v_periods_per_year := 12;
  elsif v_frequency = 'biweekly' then
    v_periods := round(p_term_months::numeric * 26 / 12)::integer;
    v_periods_per_year := 26;
  else
    v_periods := round(p_term_months::numeric * 52 / 12)::integer;
    v_periods_per_year := 52;
  end if;

  if v_periods < 1 then
    raise exception 'The agreement terms produced no payment periods.'
      using errcode = '22023';
  end if;

  if p_apr_bps = 0 then
    v_raw_payment_cents :=
      p_principal_cents::numeric / v_periods::numeric;

    v_base_payment_cents :=
      round(v_raw_payment_cents)::bigint;

    v_target_total_cents :=
      p_principal_cents;
  else
    v_rate_per_period :=
      p_apr_bps::numeric
      / 10000::numeric
      / v_periods_per_year::numeric;

    v_raw_payment_cents :=
      (
        p_principal_cents::numeric * v_rate_per_period
      )
      /
      (
        1
        - power(
            1 + v_rate_per_period,
            -v_periods::numeric
          )
      );

    v_base_payment_cents :=
      round(v_raw_payment_cents)::bigint;

    v_target_total_cents :=
      round(
        v_raw_payment_cents * v_periods::numeric
      )::bigint;
  end if;

  v_last_payment_cents :=
    v_base_payment_cents
    + (
        v_target_total_cents
        - v_base_payment_cents * v_periods::bigint
      );

  if v_base_payment_cents <= 0 or v_last_payment_cents <= 0 then
    raise exception 'The agreement terms produced an invalid payment amount.'
      using errcode = '22023';
  end if;

  v_iou_id := extensions.gen_random_uuid();

  insert into public.ious (
    id,
    title,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status,
    created_by,
    requested_action_by,
    total_installments,
    paid_installments
  )
  values (
    v_iou_id,
    v_title,
    p_lender_id,
    p_borrower_id,
    p_principal_cents,
    p_apr_bps,
    p_start_date,
    p_term_months,
    v_frequency,
    'open',
    v_actor,
    case
      when v_actor = p_lender_id then p_borrower_id
      else p_lender_id
    end,
    v_periods,
    0
  );

  insert into public.payments (
    iou_id,
    due_date,
    amount_cents,
    status
  )
  select
    v_iou_id,
    case
      when v_frequency = 'monthly' then
        (
          p_start_date
          + make_interval(months => period_index)
        )::date
      when v_frequency = 'biweekly' then
        p_start_date + period_index * 14
      else
        p_start_date + period_index * 7
    end,
    case
      when period_index = v_periods - 1
        then v_last_payment_cents
      else v_base_payment_cents
    end,
    'scheduled'
  from generate_series(
    0,
    v_periods - 1
  ) as generated_period(period_index);

  select
    count(*),
    coalesce(sum(p.amount_cents), 0)
  into
    v_inserted_count,
    v_inserted_total
  from public.payments p
  where p.iou_id = v_iou_id;

  if v_inserted_count <> v_periods then
    raise exception
      'Expected % scheduled payments but created %.',
      v_periods,
      v_inserted_count;
  end if;

  if v_inserted_total <> v_target_total_cents then
    raise exception
      'Expected payment total % cents but created % cents.',
      v_target_total_cents,
      v_inserted_total;
  end if;

  perform public.refresh_iou_status(v_iou_id);

  return query
  select
    i.id,
    i.status,
    i.total_installments,
    v_inserted_count
  from public.ious i
  where i.id = v_iou_id;
end;
$function$;

revoke all
on function public.create_iou_with_schedule(
  text,
  uuid,
  uuid,
  bigint,
  integer,
  date,
  integer,
  text,
  text,
  text
)
from public, anon, authenticated, service_role;

grant execute
on function public.create_iou_with_schedule(
  text,
  uuid,
  uuid,
  bigint,
  integer,
  date,
  integer,
  text,
  text,
  text
)
to authenticated;

comment on function public.create_iou_with_schedule(
  text,
  uuid,
  uuid,
  bigint,
  integer,
  date,
  integer,
  text,
  text,
  text
) is
  'Atomically creates one Personal IOU and its database-generated payment schedule for an authenticated lender or borrower.';

-- ============================================================================
-- Client mutation hardening
--
-- New agreements must use create_iou_with_schedule.
-- Existing schedule edits continue through propose_schedule_change and
-- finalize_iou_schedule, whose SECURITY DEFINER bodies retain table access.
-- ============================================================================

revoke insert
on table public.ious
from public, anon, authenticated;

revoke insert, delete
on table public.payments
from public, anon, authenticated;

commit;
