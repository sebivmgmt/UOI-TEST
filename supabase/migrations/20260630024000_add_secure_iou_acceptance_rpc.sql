-- Secure, atomic IOU acceptance.
--
-- This migration replaces the fail-open client acceptance path with one
-- authenticated SECURITY DEFINER RPC. The RPC records canonical legal consent,
-- records the typed-signature acceptance audit, and activates the IOU in one
-- transaction. Any failure rolls the entire call back.

begin;

-- Acceptance evidence must be written by controlled server functions.
revoke insert, update, delete
  on table public.iou_acceptance_audit
  from public, anon, authenticated;

revoke insert, update, delete
  on table public.legal_acceptances
  from public, anon, authenticated;

create or replace function public.accept_iou_with_legal(
  p_iou_id uuid,
  p_typed_signature text,
  p_terms_version text,
  p_privacy_version text,
  p_ack_contract boolean,
  p_ack_electronic boolean,
  p_ack_fee boolean,
  p_ack_not_lender boolean,
  p_platform text default null,
  p_app_version text default null,
  p_device_metadata jsonb default null,
  p_metadata jsonb default null
)
returns table(
  id uuid,
  status text,
  activated_at timestamptz,
  accepted_by uuid,
  acceptance_audit_id uuid,
  payment_count bigint,
  repayment_total_cents bigint,
  platform_fee_cents bigint,
  total_borrower_cost_cents bigint
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid;
  v_iou public.ious%rowtype;

  v_signature text;
  v_profile_name text;
  v_lender_ach_ready boolean := false;
  v_borrower_ach_ready boolean := false;

  v_payment_count bigint := 0;
  v_payment_total bigint := 0;

  v_platform_fee_bps integer := 70;
  v_platform_fee_cents bigint := 0;
  v_total_borrower_cost_cents bigint := 0;

  v_accepted_at timestamptz := clock_timestamp();
  v_audit_id uuid;

  v_platform text;
  v_app_version text;
  v_device_metadata jsonb;
  v_metadata jsonb;
begin
  v_actor := auth.uid();
  v_signature := btrim(coalesce(p_typed_signature, ''));
  v_platform := nullif(btrim(coalesce(p_platform, '')), '');
  v_app_version := nullif(btrim(coalesce(p_app_version, '')), '');

  if v_actor is null then
    raise exception 'Authentication required.'
      using errcode = '42501';
  end if;

  if p_iou_id is null then
    raise exception 'IOU id is required.'
      using errcode = '22023';
  end if;

  if btrim(coalesce(p_terms_version, '')) <> '2026-05-03'
     or btrim(coalesce(p_privacy_version, '')) <> '2026-05-03'
  then
    raise exception
      'The current Terms of Service and Privacy Policy are required.'
      using errcode = '42501';
  end if;

  if p_ack_contract is not true
     or p_ack_electronic is not true
     or p_ack_fee is not true
     or p_ack_not_lender is not true
  then
    raise exception 'All required acknowledgments must be accepted.'
      using errcode = '22023';
  end if;

  if char_length(v_signature) < 3
     or char_length(v_signature) > 200
     or position('@' in v_signature) > 0
     or coalesce(
          array_length(
            regexp_split_to_array(v_signature, E'\\s+'),
            1
          ),
          0
        ) < 2
  then
    raise exception
      'Typed signature must contain a valid first and last name.'
      using errcode = '22023';
  end if;

  if v_platform is not null and char_length(v_platform) > 50 then
    raise exception 'Platform value is too long.'
      using errcode = '22023';
  end if;

  if v_app_version is not null and char_length(v_app_version) > 100 then
    raise exception 'App version value is too long.'
      using errcode = '22023';
  end if;

  if p_device_metadata is null then
    v_device_metadata := null;
  elsif jsonb_typeof(p_device_metadata) = 'object'
        and octet_length(p_device_metadata::text) <= 16384
  then
    v_device_metadata := p_device_metadata;
  else
    raise exception
      'Device metadata must be a JSON object no larger than 16 KB.'
      using errcode = '22023';
  end if;

  if p_metadata is null then
    v_metadata := '{}'::jsonb;
  elsif jsonb_typeof(p_metadata) = 'object'
        and octet_length(p_metadata::text) <= 16384
  then
    v_metadata := p_metadata;
  else
    raise exception
      'Acceptance metadata must be a JSON object no larger than 16 KB.'
      using errcode = '22023';
  end if;

  select i.*
  into v_iou
  from public.ious i
  where i.id = p_iou_id
  for update;

  if not found then
    raise exception 'IOU not found.'
      using errcode = 'P0002';
  end if;

  if v_iou.activated_at is not null then
    raise exception 'IOU is already active.'
      using errcode = '55000';
  end if;

  if v_iou.deleted_at is not null
     or v_iou.status in ('paid', 'archived', 'canceled', 'denied')
  then
    raise exception 'This IOU cannot be accepted in its current state.'
      using errcode = '55000';
  end if;

  if v_iou.status not in (
    'open',
    'pending_acceptance',
    'pending_counterparty'
  ) then
    raise exception
      'IOU is not ready for acceptance (status: %).',
      v_iou.status
      using errcode = '55000';
  end if;

  if v_iou.requested_action_by is null
     or v_iou.requested_action_by is distinct from v_actor
  then
    raise exception
      'Only the user currently requested to act may accept this IOU.'
      using errcode = '42501';
  end if;

  if v_actor is distinct from v_iou.lender_id
     and v_actor is distinct from v_iou.borrower_id
  then
    raise exception 'The accepting user is not a party to this IOU.'
      using errcode = '42501';
  end if;

  -- The typed signature must match the same canonical profile name exposed
  -- through profile_directory: display_name, then name, then full_name.
  select coalesce(
    nullif(btrim(p.display_name), ''),
    nullif(btrim(p.name), ''),
    nullif(btrim(p.full_name), '')
  )
  into v_profile_name
  from public.profiles p
  where p.id = v_actor;

  if v_profile_name is null then
    raise exception
      'A profile name is required before accepting an IOU.'
      using errcode = '42501';
  end if;

  if lower(regexp_replace(v_signature, E'\\s+', ' ', 'g'))
     is distinct from
     lower(regexp_replace(v_profile_name, E'\\s+', ' ', 'g'))
  then
    raise exception
      'Typed signature must exactly match your profile name.'
      using errcode = '22023';
  end if;

  -- Activation fails closed unless both parties have completed the
  -- authoritative ACH setup represented by profiles.ach_status = 'ready'.
  select
    coalesce(
      bool_or(
        p.id = v_iou.lender_id
        and coalesce(p.ach_status = 'ready', false)
      ),
      false
    ),
    coalesce(
      bool_or(
        p.id = v_iou.borrower_id
        and coalesce(p.ach_status = 'ready', false)
      ),
      false
    )
  into
    v_lender_ach_ready,
    v_borrower_ach_ready
  from public.profiles p
  where p.id in (v_iou.lender_id, v_iou.borrower_id);

  if not v_lender_ach_ready or not v_borrower_ach_ready then
    raise exception
      'Both participants must complete bank setup before this IOU can be activated.'
      using errcode = '55000';
  end if;

  select
    count(*),
    coalesce(sum(p.amount_cents), 0)
  into
    v_payment_count,
    v_payment_total
  from public.payments p
  where p.iou_id = p_iou_id
    and p.status = 'scheduled'
    and p.paid_at is null;

  if v_payment_count = 0 then
    raise exception 'IOU has no scheduled payment plan.'
      using errcode = '22023';
  end if;

  if coalesce(v_iou.total_installments, 0) <> v_payment_count then
    raise exception
      'Payment schedule is incomplete: expected %, found %.',
      coalesce(v_iou.total_installments, 0),
      v_payment_count
      using errcode = '22023';
  end if;

  if v_payment_total < v_iou.principal_cents then
    raise exception
      'Payment schedule total (% cents) is less than principal (% cents).',
      v_payment_total,
      v_iou.principal_cents
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.iou_acceptance_audit a
    where a.iou_id = p_iou_id
      and a.user_id = v_actor
  ) then
    raise exception
      'An acceptance record already exists for this user and IOU.'
      using errcode = '23505';
  end if;

  v_platform_fee_cents :=
    round(
      v_iou.principal_cents::numeric
      * v_platform_fee_bps::numeric
      / 10000::numeric
    )::bigint;

  v_total_borrower_cost_cents :=
    v_payment_total + v_platform_fee_cents;

  -- legal_acceptances is the global, append-only current-document ledger.
  -- Its existing uniqueness rule makes these inserts idempotent.
  insert into public.legal_acceptances (
    user_id,
    document_type,
    document_version,
    accepted_at,
    context,
    related_iou_id,
    platform,
    app_version,
    device_metadata,
    metadata
  )
  values (
    v_actor,
    'terms_of_service',
    '2026-05-03',
    v_accepted_at,
    'new_iou_flow',
    p_iou_id,
    v_platform,
    v_app_version,
    v_device_metadata,
    jsonb_build_object(
      'source', 'accept_iou_with_legal',
      'iou_id', p_iou_id
    )
  )
  on conflict (
    user_id,
    document_type,
    document_version,
    context
  ) do nothing;

  insert into public.legal_acceptances (
    user_id,
    document_type,
    document_version,
    accepted_at,
    context,
    related_iou_id,
    platform,
    app_version,
    device_metadata,
    metadata
  )
  values (
    v_actor,
    'privacy_policy',
    '2026-05-03',
    v_accepted_at,
    'new_iou_flow',
    p_iou_id,
    v_platform,
    v_app_version,
    v_device_metadata,
    jsonb_build_object(
      'source', 'accept_iou_with_legal',
      'iou_id', p_iou_id
    )
  )
  on conflict (
    user_id,
    document_type,
    document_version,
    context
  ) do nothing;

  if not exists (
    select 1
    from public.legal_acceptances la
    where la.user_id = v_actor
      and la.document_type = 'terms_of_service'
      and la.document_version = '2026-05-03'
      and la.context = 'new_iou_flow'
  ) then
    raise exception 'Terms acceptance could not be recorded.'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from public.legal_acceptances la
    where la.user_id = v_actor
      and la.document_type = 'privacy_policy'
      and la.document_version = '2026-05-03'
      and la.context = 'new_iou_flow'
  ) then
    raise exception 'Privacy acceptance could not be recorded.'
      using errcode = '55000';
  end if;

  v_metadata :=
    v_metadata
    || jsonb_strip_nulls(
      jsonb_build_object(
        'source', 'accept_iou_with_legal',
        'requested_action_by', v_iou.requested_action_by,
        'created_by', v_iou.created_by,
        'accepting_role',
          case
            when v_actor = v_iou.lender_id then 'lender'
            else 'borrower'
          end,
        'platform', v_platform,
        'app_version', v_app_version,
        'ack_contract', p_ack_contract,
        'ack_electronic', p_ack_electronic,
        'ack_fee', p_ack_fee,
        'ack_not_lender', p_ack_not_lender
      )
    );

  insert into public.iou_acceptance_audit as a (
    iou_id,
    user_id,
    typed_signature,
    terms_version,
    privacy_version,
    platform_fee_bps,
    accepted_at,
    repayment_total_cents,
    platform_fee_cents,
    total_borrower_cost_cents,
    metadata
  )
  values (
    p_iou_id,
    v_actor,
    v_signature,
    '2026-05-03',
    '2026-05-03',
    v_platform_fee_bps,
    v_accepted_at,
    v_payment_total,
    v_platform_fee_cents,
    v_total_borrower_cost_cents,
    v_metadata
  )
  returning a.id
  into v_audit_id;

  update public.ious i
  set
    status = 'open',
    activated_at = v_accepted_at,
    accepted_at = v_accepted_at,
    requested_action_by = null,

    lender_signature =
      case
        when v_actor = i.lender_id then v_signature
        else i.lender_signature
      end,

    lender_signed_at =
      case
        when v_actor = i.lender_id then v_accepted_at
        else i.lender_signed_at
      end,

    borrower_signature =
      case
        when v_actor = i.borrower_id then v_signature
        else i.borrower_signature
      end,

    borrower_signed_at =
      case
        when v_actor = i.borrower_id then v_accepted_at
        else i.borrower_signed_at
      end
  where i.id = p_iou_id;

  perform public.recompute_iou_progress(p_iou_id);
  perform public.recompute_iou_exposure(p_iou_id);

  return query
  select
    i.id,
    i.status,
    i.activated_at,
    v_actor,
    v_audit_id,
    v_payment_count,
    v_payment_total,
    v_platform_fee_cents,
    v_total_borrower_cost_cents
  from public.ious i
  where i.id = p_iou_id;
end;
$function$;

revoke all
  on function public.accept_iou_with_legal(
    uuid,
    text,
    text,
    text,
    boolean,
    boolean,
    boolean,
    boolean,
    text,
    text,
    jsonb,
    jsonb
  )
  from public, anon;

grant execute
  on function public.accept_iou_with_legal(
    uuid,
    text,
    text,
    text,
    boolean,
    boolean,
    boolean,
    boolean,
    text,
    text,
    jsonb,
    jsonb
  )
  to authenticated, service_role;

-- Retire the two legacy activation entry points. They remain installed for
-- rollback/history but are no longer callable by app roles.
revoke execute
  on function public.accept_iou_request(uuid)
  from public, anon, authenticated;

revoke execute
  on function public.activate_iou(uuid, text)
  from public, anon, authenticated;

grant execute
  on function public.accept_iou_request(uuid)
  to service_role;

grant execute
  on function public.activate_iou(uuid, text)
  to service_role;

-- Legal-ledger RPCs remain available only to authenticated clients.
revoke execute
  on function public.record_legal_acceptance(
    text,
    text,
    text,
    uuid,
    text,
    text,
    jsonb,
    jsonb,
    text
  )
  from public, anon;

grant execute
  on function public.record_legal_acceptance(
    text,
    text,
    text,
    uuid,
    text,
    text,
    jsonb,
    jsonb,
    text
  )
  to authenticated, service_role;

revoke execute
  on function public.has_current_legal_acceptance(text, text)
  from public, anon;

grant execute
  on function public.has_current_legal_acceptance(text, text)
  to authenticated, service_role;

commit;
