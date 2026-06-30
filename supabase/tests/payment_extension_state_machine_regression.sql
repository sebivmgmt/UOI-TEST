begin;

do $test$
declare
  v_lender_id uuid;
  v_borrower_id uuid;
  v_outsider_id uuid := gen_random_uuid();

  v_iou_id uuid := gen_random_uuid();
  v_payment_approve_id uuid := gen_random_uuid();
  v_payment_deny_id uuid := gen_random_uuid();
  v_payment_validation_id uuid := gen_random_uuid();
  v_payment_late_id uuid := gen_random_uuid();

  v_approve_due date := current_date + 5;
  v_approve_until date := current_date + 10;

  v_deny_due date := current_date + 7;
  v_deny_until_one date := current_date + 11;
  v_deny_until_two date := current_date + 12;

  v_validation_due date := current_date + 8;
  v_late_due date := current_date - 1;

  v_payment public.payments%rowtype;
  v_first_request_id uuid;
  v_second_request_id uuid;
  v_event_id uuid;
  v_count integer;
begin
  select i.lender_id, i.borrower_id
  into v_lender_id, v_borrower_id
  from public.ious i
  join auth.users lender_user
    on lender_user.id = i.lender_id
  join auth.users borrower_user
    on borrower_user.id = i.borrower_id
  where i.lender_id is not null
    and i.borrower_id is not null
    and i.lender_id is distinct from i.borrower_id
  order by i.created_at nulls last, i.id
  limit 1;

  if v_lender_id is null or v_borrower_id is null then
    raise exception
      'FAIL SETUP: DEV requires an existing IOU with distinct lender and borrower users.';
  end if;

  -- -------------------------------------------------------------------------
  -- Privilege and structural contract
  -- -------------------------------------------------------------------------

  if has_function_privilege(
    'anon',
    'public.request_payment_extension(uuid,date,text)',
    'EXECUTE'
  ) then
    raise exception 'FAIL PRIV-1: anon can execute request_payment_extension.';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.request_payment_extension(uuid,date,text)',
    'EXECUTE'
  ) then
    raise exception 'FAIL PRIV-2: authenticated cannot execute request_payment_extension.';
  end if;

  if has_function_privilege(
    'anon',
    'public.decide_payment_extension(uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'FAIL PRIV-3: anon can execute decide_payment_extension.';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.decide_payment_extension(uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'FAIL PRIV-4: authenticated cannot execute decide_payment_extension.';
  end if;

  if has_table_privilege('anon', 'public.payments', 'UPDATE')
     or has_table_privilege('authenticated', 'public.payments', 'UPDATE')
  then
    raise exception 'FAIL PRIV-5: client roles retain direct payments UPDATE.';
  end if;

  if has_table_privilege('anon', 'public.payment_receipts', 'INSERT')
     or has_table_privilege('anon', 'public.payment_receipts', 'UPDATE')
     or has_table_privilege('anon', 'public.payment_receipts', 'DELETE')
     or has_table_privilege('authenticated', 'public.payment_receipts', 'INSERT')
     or has_table_privilege('authenticated', 'public.payment_receipts', 'UPDATE')
     or has_table_privilege('authenticated', 'public.payment_receipts', 'DELETE')
  then
    raise exception 'FAIL PRIV-6: client roles retain payment_receipts mutation privileges.';
  end if;

  if not has_table_privilege(
    'authenticated',
    'public.payment_extension_events',
    'SELECT'
  ) then
    raise exception 'FAIL PRIV-7: authenticated cannot read extension events.';
  end if;

  if has_table_privilege('authenticated', 'public.payment_extension_events', 'INSERT')
     or has_table_privilege('authenticated', 'public.payment_extension_events', 'UPDATE')
     or has_table_privilege('authenticated', 'public.payment_extension_events', 'DELETE')
     or has_table_privilege('service_role', 'public.payment_extension_events', 'INSERT')
     or has_table_privilege('service_role', 'public.payment_extension_events', 'UPDATE')
     or has_table_privilege('service_role', 'public.payment_extension_events', 'DELETE')
  then
    raise exception 'FAIL PRIV-8: extension ledger has a direct mutation grant.';
  end if;

  if has_function_privilege(
    'anon',
    'public.claim_payment(uuid,uuid)',
    'EXECUTE'
  ) then
    raise exception 'FAIL PRIV-9: anon can execute claim_payment.';
  end if;

  if has_function_privilege(
    'anon',
    'public.reject_payment(uuid)',
    'EXECUTE'
  ) then
    raise exception 'FAIL PRIV-10: anon can execute reject_payment.';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.refresh_iou_status(uuid)',
    'EXECUTE'
  ) or has_function_privilege(
    'anon',
    'public.refresh_iou_status(uuid)',
    'EXECUTE'
  ) then
    raise exception 'FAIL PRIV-11: client role can execute refresh_iou_status.';
  end if;

  select count(*)
  into v_count
  from pg_constraint c
  join pg_class t
    on t.oid = c.conrelid
  join pg_namespace n
    on n.oid = t.relnamespace
  where n.nspname = 'public'
    and t.relname = 'payment_extension_events'
    and c.contype = 'f'
    and c.confdeltype = 'r';

  if v_count <> 3 then
    raise exception
      'FAIL STRUCT-1: expected 3 ON DELETE RESTRICT ledger foreign keys, found %.',
      v_count;
  end if;

  raise notice 'PASS: privilege and structural contract';

  -- -------------------------------------------------------------------------
  -- Isolated active IOU and payments
  -- -------------------------------------------------------------------------

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status,
    activated_at,
    created_by
  )
  values (
    v_iou_id,
    v_lender_id,
    v_borrower_id,
    40000,
    0,
    current_date,
    4,
    'monthly',
    'open',
    now(),
    v_lender_id
  );

  insert into public.payments (
    id,
    iou_id,
    due_date,
    amount_cents,
    status
  )
  values
    (
      v_payment_approve_id,
      v_iou_id,
      v_approve_due,
      10000,
      'scheduled'
    ),
    (
      v_payment_deny_id,
      v_iou_id,
      v_deny_due,
      10000,
      'scheduled'
    ),
    (
      v_payment_validation_id,
      v_iou_id,
      v_validation_due,
      10000,
      'scheduled'
    ),
    (
      v_payment_late_id,
      v_iou_id,
      v_late_due,
      10000,
      'late'
    );

  -- -------------------------------------------------------------------------
  -- Approval flow
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  select *
  into v_payment
  from public.request_payment_extension(
    v_payment_approve_id,
    v_approve_until,
    '  Need several more days.  '
  );

  v_first_request_id := v_payment.extension_request_id;

  if v_payment.due_date is distinct from v_approve_due
     or v_payment.extension_original_due_date is distinct from v_approve_due
     or v_payment.extension_requested_until is distinct from v_approve_until
     or v_payment.extension_status is distinct from 'requested'
     or v_payment.extension_requested_by is distinct from v_borrower_id
     or v_payment.extension_reason is distinct from 'Need several more days.'
     or v_first_request_id is null
  then
    raise exception 'FAIL REQUEST-1: request transition stored incorrect state.';
  end if;

  select id
  into v_event_id
  from public.payment_extension_events
  where request_id = v_first_request_id
    and event_type = 'requested'
    and actor_id = v_borrower_id
    and original_due_date = v_approve_due
    and requested_until = v_approve_until;

  if v_event_id is null then
    raise exception 'FAIL REQUEST-2: requested audit event missing.';
  end if;

  begin
    perform public.request_payment_extension(
      v_payment_approve_id,
      v_approve_until + 1,
      null
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%pending extension request%' then
        raise exception
          'FAIL REQUEST-3: duplicate request produced wrong error: %',
          sqlerrm;
      end if;
  end;

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  begin
    perform public.decide_payment_extension(
      v_payment_approve_id,
      'approved'
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%only the lender%' then
        raise exception
          'FAIL DECISION-1: borrower decision produced wrong error: %',
          sqlerrm;
      end if;
  end;

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_lender_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  select *
  into v_payment
  from public.decide_payment_extension(
    v_payment_approve_id,
    'approved'
  );

  if v_payment.due_date is distinct from v_approve_until
     or v_payment.due_at::date is distinct from v_approve_until
     or v_payment.extension_original_due_date is distinct from v_approve_due
     or v_payment.extension_status is distinct from 'approved'
     or v_payment.extension_decided_by is distinct from v_lender_id
     or v_payment.extension_decision_at is null
     or v_payment.status is distinct from 'scheduled'
  then
    raise exception 'FAIL DECISION-2: approval did not atomically establish the canonical deadline.';
  end if;

  select count(*)
  into v_count
  from public.payment_extension_events
  where request_id = v_first_request_id;

  if v_count <> 2 then
    raise exception
      'FAIL DECISION-3: approved request should have 2 ledger events, found %.',
      v_count;
  end if;

  begin
    perform public.decide_payment_extension(
      v_payment_approve_id,
      'denied'
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%pending extension request%' then
        raise exception
          'FAIL DECISION-4: repeat decision produced wrong error: %',
          sqlerrm;
      end if;
  end;

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  begin
    perform public.request_payment_extension(
      v_payment_approve_id,
      v_approve_until + 1,
      null
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%already received an approved extension%' then
        raise exception
          'FAIL REQUEST-4: approved payment produced wrong repeat-request error: %',
          sqlerrm;
      end if;
  end;

  raise notice 'PASS: approval flow and canonical due-date transition';

  -- -------------------------------------------------------------------------
  -- Append-only ledger enforcement
  -- -------------------------------------------------------------------------

  begin
    update public.payment_extension_events
    set reason = 'tampered'
    where id = v_event_id;

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;
  end;

  begin
    delete from public.payment_extension_events
    where id = v_event_id;

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;
  end;

  raise notice 'PASS: ledger UPDATE and DELETE are blocked';

  -- -------------------------------------------------------------------------
  -- Denial and re-request flow
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  select *
  into v_payment
  from public.request_payment_extension(
    v_payment_deny_id,
    v_deny_until_one,
    'First request'
  );

  v_first_request_id := v_payment.extension_request_id;

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_lender_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  select *
  into v_payment
  from public.decide_payment_extension(
    v_payment_deny_id,
    'denied'
  );

  if v_payment.due_date is distinct from v_deny_due
     or v_payment.extension_status is distinct from 'denied'
     or v_payment.extension_decided_by is distinct from v_lender_id
  then
    raise exception 'FAIL DENY-1: denial incorrectly changed the canonical deadline.';
  end if;

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  select *
  into v_payment
  from public.request_payment_extension(
    v_payment_deny_id,
    v_deny_until_two,
    'Second request'
  );

  v_second_request_id := v_payment.extension_request_id;

  if v_second_request_id is null
     or v_second_request_id = v_first_request_id
     or v_payment.extension_status is distinct from 'requested'
     or v_payment.extension_original_due_date is distinct from v_deny_due
  then
    raise exception 'FAIL DENY-2: re-request after denial did not create a new request identity.';
  end if;

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_lender_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  perform public.decide_payment_extension(
    v_payment_deny_id,
    'denied'
  );

  select count(*)
  into v_count
  from public.payment_extension_events
  where payment_id = v_payment_deny_id;

  if v_count <> 4 then
    raise exception
      'FAIL DENY-3: expected 4 append-only events across two denied requests, found %.',
      v_count;
  end if;

  raise notice 'PASS: denial preserves due_date and permits a new audited request';

  -- -------------------------------------------------------------------------
  -- Authorization and date validation
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_lender_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  begin
    perform public.request_payment_extension(
      v_payment_validation_id,
      v_validation_due + 1,
      null
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%only the borrower%' then
        raise exception
          'FAIL VALIDATION-1: lender request produced wrong error: %',
          sqlerrm;
      end if;
  end;

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_outsider_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  begin
    perform public.request_payment_extension(
      v_payment_validation_id,
      v_validation_due + 1,
      null
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%only the borrower%' then
        raise exception
          'FAIL VALIDATION-2: outsider request produced wrong error: %',
          sqlerrm;
      end if;
  end;

  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_borrower_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  begin
    perform public.request_payment_extension(
      v_payment_validation_id,
      v_validation_due + 15,
      null
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%no more than 14 days%' then
        raise exception
          'FAIL VALIDATION-3: over-limit request produced wrong error: %',
          sqlerrm;
      end if;
  end;

  begin
    perform public.request_payment_extension(
      v_payment_validation_id,
      v_validation_due,
      null
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%later than the current due date%' then
        raise exception
          'FAIL VALIDATION-4: unchanged date produced wrong error: %',
          sqlerrm;
      end if;
  end;

  begin
    perform public.request_payment_extension(
      v_payment_late_id,
      current_date,
      null
    );

    raise exception 'TEST_EXPECTED_FAILURE_NOT_RAISED';
  exception
    when others then
      if sqlerrm = 'TEST_EXPECTED_FAILURE_NOT_RAISED' then
        raise;
      end if;

      if sqlerrm not ilike '%must be in the future%' then
        raise exception
          'FAIL VALIDATION-5: non-future late-payment extension produced wrong error: %',
          sqlerrm;
      end if;
  end;

  raise notice 'PASS: authorization and date validation';
  raise notice 'PASS: PAYMENT EXTENSION STATE MACHINE REGRESSION COMPLETE';
end;
$test$;

rollback;
