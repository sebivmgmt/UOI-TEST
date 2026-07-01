begin;

do $test$
declare
  v_run text := replace(gen_random_uuid()::text, '-', '');

  v_lender_1 uuid := gen_random_uuid();
  v_borrower_1 uuid := gen_random_uuid();
  v_lender_2 uuid := gen_random_uuid();
  v_borrower_2 uuid := gen_random_uuid();
  v_lender_3 uuid := gen_random_uuid();
  v_borrower_3 uuid := gen_random_uuid();
  v_lender_4 uuid := gen_random_uuid();
  v_borrower_4 uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();

  v_iou_1 uuid;
  v_iou_2 uuid;
  v_iou_3 uuid;
  v_iou_4 uuid;

  v_status text;
  v_activated_at timestamptz;
  v_accepted_by uuid;
  v_audit_id uuid;
  v_payment_count bigint;
  v_repayment_total bigint;
  v_fee bigint;
  v_total_cost bigint;
  v_count bigint;
  v_expected_failure boolean;
  v_pass integer := 0;
  v_start_date date := current_date + 7;
begin
  insert into auth.users (
    id,
    email,
    aud,
    role,
    email_confirmed_at,
    created_at,
    updated_at,
    raw_user_meta_data,
    is_anonymous
  )
  values
    (v_lender_1,   v_run || '_l1@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Lender One"}', false),
    (v_borrower_1, v_run || '_b1@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Borrower One"}', false),
    (v_lender_2,   v_run || '_l2@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Lender Two"}', false),
    (v_borrower_2, v_run || '_b2@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Borrower Two"}', false),
    (v_lender_3,   v_run || '_l3@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Lender Three"}', false),
    (v_borrower_3, v_run || '_b3@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Borrower Three"}', false),
    (v_lender_4,   v_run || '_l4@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Lender Four"}', false),
    (v_borrower_4, v_run || '_b4@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Borrower Four"}', false),
    (v_outsider,   v_run || '_out@test.invalid', 'authenticated', 'authenticated', now(), now(), now(), '{"full_name":"Secure Outsider"}', false);

  update public.profiles
  set
    state = 'GA',
    phone_verified = true,
    identity_status = 'verified',
    bank_linked = true,
    plaid_linked = true,
    ach_status = 'ready'
  where id in (
    v_lender_1, v_borrower_1,
    v_lender_2, v_borrower_2,
    v_lender_3, v_borrower_3,
    v_lender_4, v_borrower_4,
    v_outsider
  );

  insert into public.legal_acceptances (
    user_id,
    document_type,
    document_version,
    context,
    accepted_at
  )
  select
    creator.id,
    doc.document_type,
    '2026-05-03',
    'new_iou_flow',
    now()
  from (
    values
      (v_lender_1),
      (v_borrower_2),
      (v_lender_3),
      (v_lender_4)
  ) creator(id)
  cross join (
    values
      ('terms_of_service'::text),
      ('privacy_policy'::text)
  ) doc(document_type);

  -- R1: privilege contract.
  if not has_function_privilege(
    'authenticated',
    'public.accept_iou_with_legal(uuid,text,text,text,boolean,boolean,boolean,boolean,text,text,jsonb,jsonb)',
    'EXECUTE'
  ) then
    raise exception 'R1: authenticated lacks secure acceptance EXECUTE';
  end if;

  if has_function_privilege(
       'anon',
       'public.accept_iou_with_legal(uuid,text,text,text,boolean,boolean,boolean,boolean,text,text,jsonb,jsonb)',
       'EXECUTE'
     )
     or has_function_privilege('authenticated', 'public.accept_iou_request(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.accept_iou_request(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.activate_iou(uuid,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.activate_iou(uuid,text)', 'EXECUTE')
  then
    raise exception 'R1: unsafe activation privilege remains';
  end if;

  if has_table_privilege('authenticated', 'public.iou_acceptance_audit', 'INSERT')
     or has_table_privilege('anon', 'public.iou_acceptance_audit', 'INSERT')
     or has_table_privilege('authenticated', 'public.legal_acceptances', 'INSERT')
     or has_table_privilege('anon', 'public.legal_acceptances', 'INSERT')
  then
    raise exception 'R1: client direct acceptance INSERT remains';
  end if;

  if has_function_privilege(
       'anon',
       'public.record_legal_acceptance(text,text,text,uuid,text,text,jsonb,jsonb,text)',
       'EXECUTE'
     )
     or has_function_privilege(
       'anon',
       'public.has_current_legal_acceptance(text,text)',
       'EXECUTE'
     )
  then
    raise exception 'R1: legal-ledger RPC remains anonymous';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R1: privilege contract';

  -- R2: lender-created IOU is accepted atomically by requested borrower.
  perform set_config('request.jwt.claim.sub', v_lender_1::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_lender_1, 'role', 'authenticated')::text,
    true
  );

  select r.id
  into v_iou_1
  from public.create_iou_with_schedule(
    v_run || '_lender_created',
    v_lender_1,
    v_borrower_1,
    10000,
    0,
    v_start_date,
    3,
    'monthly',
    '2026-05-03',
    '2026-05-03'
  ) r;

  if (
    select i.requested_action_by
    from public.ious i
    where i.id = v_iou_1
  ) is distinct from v_borrower_1 then
    raise exception 'R2: lender-created IOU did not route to borrower';
  end if;

  perform set_config('request.jwt.claim.sub', v_borrower_1::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_1, 'role', 'authenticated')::text,
    true
  );

  select
    r.status,
    r.activated_at,
    r.accepted_by,
    r.acceptance_audit_id,
    r.payment_count,
    r.repayment_total_cents,
    r.platform_fee_cents,
    r.total_borrower_cost_cents
  into
    v_status,
    v_activated_at,
    v_accepted_by,
    v_audit_id,
    v_payment_count,
    v_repayment_total,
    v_fee,
    v_total_cost
  from public.accept_iou_with_legal(
    v_iou_1,
    'Secure Borrower One',
    '2026-05-03',
    '2026-05-03',
    true,
    true,
    true,
    true,
    'test',
    'secure-regression',
    '{"device":"test"}'::jsonb,
    '{"case":"borrower_accepts"}'::jsonb
  ) r;

  if v_status <> 'open'
     or v_activated_at is null
     or v_accepted_by is distinct from v_borrower_1
     or v_audit_id is null
     or v_payment_count <> 3
     or v_repayment_total <> 10000
     or v_fee <> 70
     or v_total_cost <> 10070
  then
    raise exception
      'R2: incomplete result status=%, actor=%, count=%, repayment=%, fee=%, total=%',
      v_status, v_accepted_by, v_payment_count, v_repayment_total, v_fee, v_total_cost;
  end if;

  if (
    select count(*)
    from public.legal_acceptances la
    where la.user_id = v_borrower_1
      and la.document_version = '2026-05-03'
      and la.context = 'new_iou_flow'
      and la.document_type in ('terms_of_service', 'privacy_policy')
  ) <> 2 then
    raise exception 'R2: borrower legal rows missing';
  end if;

  if not exists (
    select 1
    from public.iou_acceptance_audit a
    where a.id = v_audit_id
      and a.iou_id = v_iou_1
      and a.user_id = v_borrower_1
      and a.typed_signature = 'Secure Borrower One'
      and a.terms_version = '2026-05-03'
      and a.privacy_version = '2026-05-03'
      and a.platform_fee_bps = 70
      and a.repayment_total_cents = 10000
      and a.platform_fee_cents = 70
      and a.total_borrower_cost_cents = 10070
      and a.metadata->>'accepting_role' = 'borrower'
      and a.metadata->>'ack_contract' = 'true'
  ) then
    raise exception 'R2: acceptance audit is incomplete';
  end if;

  if not exists (
    select 1
    from public.ious i
    where i.id = v_iou_1
      and i.activated_at is not null
      and i.accepted_at is not null
      and i.requested_action_by is null
      and i.borrower_signature = 'Secure Borrower One'
      and i.borrower_signed_at is not null
  ) then
    raise exception 'R2: borrower signature or activation state missing';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R2: requested borrower accepted atomically';

  -- R3: borrower-created IOU is accepted atomically by requested lender.
  perform set_config('request.jwt.claim.sub', v_borrower_2::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_2, 'role', 'authenticated')::text,
    true
  );

  select r.id
  into v_iou_2
  from public.create_iou_with_schedule(
    v_run || '_borrower_created',
    v_lender_2,
    v_borrower_2,
    20000,
    500,
    v_start_date,
    2,
    'monthly',
    '2026-05-03',
    '2026-05-03'
  ) r;

  if (
    select i.requested_action_by
    from public.ious i
    where i.id = v_iou_2
  ) is distinct from v_lender_2 then
    raise exception 'R3: borrower-created IOU did not route to lender';
  end if;

  perform set_config('request.jwt.claim.sub', v_lender_2::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_lender_2, 'role', 'authenticated')::text,
    true
  );

  select
    r.status,
    r.activated_at,
    r.accepted_by,
    r.acceptance_audit_id
  into
    v_status,
    v_activated_at,
    v_accepted_by,
    v_audit_id
  from public.accept_iou_with_legal(
    v_iou_2,
    'Secure Lender Two',
    '2026-05-03',
    '2026-05-03',
    true,
    true,
    true,
    true,
    'test',
    'secure-regression',
    null,
    '{"case":"lender_accepts"}'::jsonb
  ) r;

  if v_status <> 'open'
     or v_activated_at is null
     or v_accepted_by is distinct from v_lender_2
     or v_audit_id is null
  then
    raise exception 'R3: lender acceptance result incomplete';
  end if;

  if not exists (
    select 1
    from public.ious i
    where i.id = v_iou_2
      and i.requested_action_by is null
      and i.lender_signature = 'Secure Lender Two'
      and i.lender_signed_at is not null
  ) then
    raise exception 'R3: lender signature or activation state missing';
  end if;

  if (
    select count(*)
    from public.legal_acceptances la
    where la.user_id = v_lender_2
      and la.document_version = '2026-05-03'
      and la.context = 'new_iou_flow'
      and la.document_type in ('terms_of_service', 'privacy_policy')
  ) <> 2 then
    raise exception 'R3: lender legal rows missing';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R3: requested lender accepted atomically';

  -- R4: outsider and non-requested creator are rejected without residue.
  perform set_config('request.jwt.claim.sub', v_lender_3::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_lender_3, 'role', 'authenticated')::text,
    true
  );

  select r.id
  into v_iou_3
  from public.create_iou_with_schedule(
    v_run || '_authorization',
    v_lender_3,
    v_borrower_3,
    15000,
    0,
    v_start_date,
    2,
    'monthly',
    '2026-05-03',
    '2026-05-03'
  ) r;

  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_outsider, 'role', 'authenticated')::text,
    true
  );

  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_3,
      'Secure Outsider',
      '2026-05-03',
      '2026-05-03',
      true,
      true,
      true,
      true
    );
  exception when sqlstate '42501' then
    v_expected_failure := true;
  end;

  if not v_expected_failure then
    raise exception 'R4: outsider acceptance succeeded';
  end if;

  perform set_config('request.jwt.claim.sub', v_lender_3::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_lender_3, 'role', 'authenticated')::text,
    true
  );

  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_3,
      'Secure Lender Three',
      '2026-05-03',
      '2026-05-03',
      true,
      true,
      true,
      true
    );
  exception when sqlstate '42501' then
    v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.iou_acceptance_audit a
       where a.iou_id = v_iou_3
     )
     or exists (
       select 1
       from public.ious i
       where i.id = v_iou_3
         and i.activated_at is not null
     )
  then
    raise exception 'R4: unauthorized acceptance left residue';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R4: only requested party may accept';

  -- R5: legal versions, signature, and acknowledgments fail closed.
  perform set_config('request.jwt.claim.sub', v_borrower_3::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_3, 'role', 'authenticated')::text,
    true
  );

  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_3,
      'Secure Borrower Three',
      '2025-01-01',
      '2026-05-03',
      true,
      true,
      true,
      true
    );
  exception when sqlstate '42501' then
    v_expected_failure := true;
  end;

  if not v_expected_failure then
    raise exception 'R5: obsolete legal version succeeded';
  end if;

  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_3,
      'borrower@example.com',
      '2026-05-03',
      '2026-05-03',
      true,
      true,
      true,
      true
    );
  exception when sqlstate '22023' then
    v_expected_failure := true;
  end;

  if not v_expected_failure then
    raise exception 'R5: invalid signature succeeded';
  end if;

  -- A structurally valid signature must still match the authenticated
  -- user's canonical profile name.
  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_3,
      'Different Borrower Name',
      '2026-05-03',
      '2026-05-03',
      true,
      true,
      true,
      true
    );
  exception when sqlstate '22023' then
    v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.iou_acceptance_audit a
       where a.iou_id = v_iou_3
     )
     or exists (
       select 1
       from public.ious i
       where i.id = v_iou_3
         and i.activated_at is not null
     )
  then
    raise exception 'R5: mismatched profile signature did not fail closed';
  end if;

  -- The counterparty must also be ACH ready. This verifies that client-side
  -- readiness checks cannot be bypassed by calling the RPC directly.
  update public.profiles
  set ach_status = 'not_ready'
  where id = v_lender_3;

  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_3,
      'Secure Borrower Three',
      '2026-05-03',
      '2026-05-03',
      true,
      true,
      true,
      true
    );
  exception when sqlstate '55000' then
    v_expected_failure := true;
  end;

  update public.profiles
  set ach_status = 'ready'
  where id = v_lender_3;

  if not v_expected_failure
     or exists (
       select 1
       from public.iou_acceptance_audit a
       where a.iou_id = v_iou_3
     )
     or exists (
       select 1
       from public.ious i
       where i.id = v_iou_3
         and i.activated_at is not null
     )
     or exists (
       select 1
       from public.legal_acceptances la
       where la.user_id = v_borrower_3
         and la.related_iou_id = v_iou_3
     )
  then
    raise exception 'R5: ACH-not-ready acceptance did not fail closed';
  end if;

  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_3,
      'Secure Borrower Three',
      '2026-05-03',
      '2026-05-03',
      true,
      true,
      false,
      true
    );
  exception when sqlstate '22023' then
    v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.iou_acceptance_audit a
       where a.iou_id = v_iou_3
     )
     or exists (
       select 1
       from public.ious i
       where i.id = v_iou_3
         and i.activated_at is not null
     )
  then
    raise exception 'R5: invalid legal input left residue';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R5: legal input validation fails closed';

  -- R6: schedule-count mismatch fails before any acceptance evidence is written.
  update public.ious
  set total_installments = total_installments + 1
  where id = v_iou_3;

  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_3,
      'Secure Borrower Three',
      '2026-05-03',
      '2026-05-03',
      true,
      true,
      true,
      true
    );
  exception when sqlstate '22023' then
    v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.iou_acceptance_audit a
       where a.iou_id = v_iou_3
     )
     or exists (
       select 1
       from public.ious i
       where i.id = v_iou_3
         and i.activated_at is not null
     )
  then
    raise exception 'R6: incomplete schedule did not fail atomically';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R6: incomplete schedule leaves no acceptance residue';

  -- R7: forced late-stage audit failure rolls back legal rows and activation.
  perform set_config('request.jwt.claim.sub', v_lender_4::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_lender_4, 'role', 'authenticated')::text,
    true
  );

  select r.id
  into v_iou_4
  from public.create_iou_with_schedule(
    v_run || '_forced_rollback',
    v_lender_4,
    v_borrower_4,
    12000,
    0,
    v_start_date,
    2,
    'monthly',
    '2026-05-03',
    '2026-05-03'
  ) r;

  create function public._test_fail_iou_acceptance_audit()
  returns trigger
  language plpgsql
  as $body$
  begin
    raise exception 'forced acceptance audit failure';
  end;
  $body$;

  create trigger _test_fail_iou_acceptance_audit_trg
  before insert on public.iou_acceptance_audit
  for each row
  execute function public._test_fail_iou_acceptance_audit();

  perform set_config('request.jwt.claim.sub', v_borrower_4::text, true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_borrower_4, 'role', 'authenticated')::text,
    true
  );

  v_expected_failure := false;
  begin
    perform public.accept_iou_with_legal(
      v_iou_4,
      'Secure Borrower Four',
      '2026-05-03',
      '2026-05-03',
      true,
      true,
      true,
      true
    );
  exception when others then
    if sqlerrm like '%forced acceptance audit failure%' then
      v_expected_failure := true;
    else
      raise;
    end if;
  end;

  drop trigger _test_fail_iou_acceptance_audit_trg
    on public.iou_acceptance_audit;
  drop function public._test_fail_iou_acceptance_audit();

  if not v_expected_failure then
    raise exception 'R7: forced audit failure did not surface';
  end if;

  if exists (
       select 1
       from public.legal_acceptances la
       where la.user_id = v_borrower_4
         and la.document_version = '2026-05-03'
         and la.context = 'new_iou_flow'
     )
     or exists (
       select 1
       from public.iou_acceptance_audit a
       where a.iou_id = v_iou_4
     )
     or exists (
       select 1
       from public.ious i
       where i.id = v_iou_4
         and (
           i.activated_at is not null
           or i.accepted_at is not null
           or i.requested_action_by is distinct from v_borrower_4
         )
     )
  then
    raise exception 'R7: forced audit failure left partial state';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R7: late-stage failure rolls back entire acceptance';

  if v_pass <> 7 then
    raise exception 'Expected 7 passes but recorded %', v_pass;
  end if;

  raise notice 'PASS: secure_iou_acceptance_regression completed %/7 checks', v_pass;
end;
$test$;

rollback;
