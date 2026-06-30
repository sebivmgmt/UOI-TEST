-- Atomic Personal IOU creation regression and security contract.
--
-- Requires:
--   20260630023000_add_atomic_iou_creation_rpc.sql
--
-- Every fixture and created agreement is rolled back.

begin;

create temporary table atomic_iou_creation_test_result (
  passed_checks integer not null,
  expected_checks integer not null
) on commit drop;

do $test$
declare
  v_run_id text :=
    'atomic_iou_' ||
    substring(
      replace(gen_random_uuid()::text, '-', ''),
      1,
      10
    );

  v_lender_id uuid := gen_random_uuid();
  v_borrower_id uuid := gen_random_uuid();
  v_outsider_id uuid := gen_random_uuid();
  v_no_acceptance_id uuid := gen_random_uuid();
  v_ma_borrower_id uuid := gen_random_uuid();

  v_monthly_iou_id uuid;
  v_weekly_iou_id uuid;

  v_status text;
  v_total_installments integer;
  v_scheduled_count bigint;

  v_start_date date :=
    make_date(
      extract(year from current_date)::integer + 1,
      1,
      31
    );

  v_count integer;
  v_sum bigint;
  v_created_by uuid;
  v_requested_action_by uuid;
  v_state text;
  v_cap integer;
  v_pass integer := 0;
  v_expected_failure boolean;
begin
  -- -------------------------------------------------------------------------
  -- Fixture users and profiles
  -- -------------------------------------------------------------------------

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
    (
      v_lender_id,
      v_run_id || '_lender@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Atomic Test Lender"}'::jsonb,
      false
    ),
    (
      v_borrower_id,
      v_run_id || '_borrower@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Atomic Test Borrower"}'::jsonb,
      false
    ),
    (
      v_outsider_id,
      v_run_id || '_outsider@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Atomic Test Outsider"}'::jsonb,
      false
    ),
    (
      v_no_acceptance_id,
      v_run_id || '_no_acceptance@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Atomic Test No Acceptance"}'::jsonb,
      false
    ),
    (
      v_ma_borrower_id,
      v_run_id || '_ma_borrower@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Atomic Test MA Borrower"}'::jsonb,
      false
    );

  update public.profiles
  set state =
    case
      when id = v_ma_borrower_id then 'MA'
      else 'GA'
    end
  where id in (
    v_lender_id,
    v_borrower_id,
    v_outsider_id,
    v_no_acceptance_id,
    v_ma_borrower_id
  );

  insert into public.legal_acceptances (
    user_id,
    document_type,
    document_version,
    context,
    accepted_at
  )
  select
    accepted_user.id,
    document.document_type,
    '2026-05-03',
    'new_iou_flow',
    now()
  from (
    values
      (v_lender_id),
      (v_borrower_id),
      (v_outsider_id)
  ) as accepted_user(id)
  cross join (
    values
      ('terms_of_service'::text),
      ('privacy_policy'::text)
  ) as document(document_type);

  -- -------------------------------------------------------------------------
  -- R1: Function and direct-mutation privilege contract
  -- -------------------------------------------------------------------------

  if not has_function_privilege(
    'authenticated',
    'public.create_iou_with_schedule(text,uuid,uuid,bigint,integer,date,integer,text,text,text)',
    'EXECUTE'
  ) then
    raise exception
      'R1 failed: authenticated lacks create_iou_with_schedule EXECUTE.';
  end if;

  if has_function_privilege(
    'anon',
    'public.create_iou_with_schedule(text,uuid,uuid,bigint,integer,date,integer,text,text,text)',
    'EXECUTE'
  ) then
    raise exception
      'R1 failed: anon can execute create_iou_with_schedule.';
  end if;

  if has_table_privilege(
       'authenticated',
       'public.ious',
       'INSERT'
     )
     or has_table_privilege(
       'anon',
       'public.ious',
       'INSERT'
     )
  then
    raise exception
      'R1 failed: a client role retains direct IOU INSERT.';
  end if;

  if has_table_privilege(
       'authenticated',
       'public.payments',
       'INSERT'
     )
     or has_table_privilege(
       'anon',
       'public.payments',
       'INSERT'
     )
     or has_table_privilege(
       'authenticated',
       'public.payments',
       'DELETE'
     )
     or has_table_privilege(
       'anon',
       'public.payments',
       'DELETE'
     )
  then
    raise exception
      'R1 failed: a client role retains direct payment INSERT or DELETE.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R1: RPC and direct-mutation privilege contract';

  -- -------------------------------------------------------------------------
  -- R2: Lender-created monthly IOU is atomic and canonical
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claim.sub',
    v_lender_id::text,
    true
  );
  perform set_config(
    'request.jwt.claim.role',
    'authenticated',
    true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_lender_id,
      'role', 'authenticated'
    )::text,
    true
  );

  select
    result.id,
    result.status,
    result.total_installments,
    result.scheduled_count
  into
    v_monthly_iou_id,
    v_status,
    v_total_installments,
    v_scheduled_count
  from public.create_iou_with_schedule(
    v_run_id || '_monthly',
    v_lender_id,
    v_borrower_id,
    10000,
    0,
    v_start_date,
    3,
    'monthly',
    '2026-05-03',
    '2026-05-03'
  ) result;

  if v_monthly_iou_id is null
     or v_status <> 'open'
     or v_total_installments <> 3
     or v_scheduled_count <> 3
  then
    raise exception
      'R2 failed: wrong monthly creation result id=%, status=%, total=%, scheduled=%',
      v_monthly_iou_id,
      v_status,
      v_total_installments,
      v_scheduled_count;
  end if;

  select
    i.created_by,
    i.requested_action_by,
    i.borrower_state_code,
    i.borrower_max_apr_bps
  into
    v_created_by,
    v_requested_action_by,
    v_state,
    v_cap
  from public.ious i
  where i.id = v_monthly_iou_id;

  if v_created_by <> v_lender_id
     or v_requested_action_by <> v_borrower_id
     or v_state <> 'GA'
     or v_cap <> 1600
  then
    raise exception
      'R2 failed: incorrect creator/action/policy snapshot.';
  end if;

  select
    count(*),
    sum(p.amount_cents)
  into
    v_count,
    v_sum
  from public.payments p
  where p.iou_id = v_monthly_iou_id;

  if v_count <> 3 or v_sum <> 10000 then
    raise exception
      'R2 failed: expected 3 payments totaling 10000, received count=% total=%',
      v_count,
      v_sum;
  end if;

  if not exists (
    select 1
    from public.payments p
    where p.iou_id = v_monthly_iou_id
      and p.due_date = v_start_date
      and p.amount_cents = 3333
  )
     or not exists (
       select 1
       from public.payments p
       where p.iou_id = v_monthly_iou_id
         and p.due_date =
           (v_start_date + interval '1 month')::date
         and p.amount_cents = 3333
     )
     or not exists (
       select 1
       from public.payments p
       where p.iou_id = v_monthly_iou_id
         and p.due_date =
           (v_start_date + interval '2 months')::date
         and p.amount_cents = 3334
     )
  then
    raise exception
      'R2 failed: monthly dates or rounding remainder are incorrect.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R2: lender-created monthly schedule';

  -- -------------------------------------------------------------------------
  -- R3: Borrower may initiate; action routes to lender
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claim.sub',
    v_borrower_id::text,
    true
  );
  perform set_config(
    'request.jwt.claim.role',
    'authenticated',
    true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_borrower_id,
      'role', 'authenticated'
    )::text,
    true
  );

  select
    result.id,
    result.status,
    result.total_installments,
    result.scheduled_count
  into
    v_weekly_iou_id,
    v_status,
    v_total_installments,
    v_scheduled_count
  from public.create_iou_with_schedule(
    v_run_id || '_weekly',
    v_lender_id,
    v_borrower_id,
    10000,
    0,
    v_start_date,
    1,
    'weekly',
    '2026-05-03',
    '2026-05-03'
  ) result;

  if v_weekly_iou_id is null
     or v_status <> 'open'
     or v_total_installments <> 4
     or v_scheduled_count <> 4
  then
    raise exception
      'R3 failed: wrong borrower-created weekly result.';
  end if;

  select
    i.created_by,
    i.requested_action_by
  into
    v_created_by,
    v_requested_action_by
  from public.ious i
  where i.id = v_weekly_iou_id;

  if v_created_by <> v_borrower_id
     or v_requested_action_by <> v_lender_id
  then
    raise exception
      'R3 failed: borrower-created routing is incorrect.';
  end if;

  select
    count(*),
    sum(p.amount_cents)
  into
    v_count,
    v_sum
  from public.payments p
  where p.iou_id = v_weekly_iou_id
    and p.due_date in (
      v_start_date,
      v_start_date + 7,
      v_start_date + 14,
      v_start_date + 21
    )
    and p.amount_cents = 2500;

  if v_count <> 4 or v_sum <> 10000 then
    raise exception
      'R3 failed: weekly schedule dates or amounts are incorrect.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R3: borrower-created weekly schedule';

  -- -------------------------------------------------------------------------
  -- R4: Outsider cannot create an agreement between other users
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claim.sub',
    v_outsider_id::text,
    true
  );
  perform set_config(
    'request.jwt.claim.role',
    'authenticated',
    true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_outsider_id,
      'role', 'authenticated'
    )::text,
    true
  );

  v_expected_failure := false;

  begin
    perform public.create_iou_with_schedule(
      v_run_id || '_outsider',
      v_lender_id,
      v_borrower_id,
      10000,
      0,
      v_start_date,
      1,
      'monthly',
      '2026-05-03',
      '2026-05-03'
    );
  exception
    when sqlstate '42501' then
      v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.ious
       where title = v_run_id || '_outsider'
     )
  then
    raise exception
      'R4 failed: outsider creation was accepted or left a row.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R4: outsider rejected';

  -- -------------------------------------------------------------------------
  -- R5: Self-IOUs are rejected without residue
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claim.sub',
    v_lender_id::text,
    true
  );
  perform set_config(
    'request.jwt.claim.role',
    'authenticated',
    true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_lender_id,
      'role', 'authenticated'
    )::text,
    true
  );

  v_expected_failure := false;

  begin
    perform public.create_iou_with_schedule(
      v_run_id || '_self',
      v_lender_id,
      v_lender_id,
      10000,
      0,
      v_start_date,
      1,
      'monthly',
      '2026-05-03',
      '2026-05-03'
    );
  exception
    when sqlstate '22023' then
      v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.ious
       where title = v_run_id || '_self'
     )
  then
    raise exception
      'R5 failed: self-IOU was accepted or left a row.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R5: self-IOU rejected';

  -- -------------------------------------------------------------------------
  -- R6: Legal acceptance is enforced by the database
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claim.sub',
    v_no_acceptance_id::text,
    true
  );
  perform set_config(
    'request.jwt.claim.role',
    'authenticated',
    true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_no_acceptance_id,
      'role', 'authenticated'
    )::text,
    true
  );

  v_expected_failure := false;

  begin
    perform public.create_iou_with_schedule(
      v_run_id || '_no_acceptance',
      v_no_acceptance_id,
      v_borrower_id,
      10000,
      0,
      v_start_date,
      1,
      'monthly',
      '2026-05-03',
      '2026-05-03'
    );
  exception
    when sqlstate '42501' then
      v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.ious
       where title = v_run_id || '_no_acceptance'
     )
  then
    raise exception
      'R6 failed: missing legal acceptance was accepted or left a row.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R6: legal acceptance required';

  -- -------------------------------------------------------------------------
  -- R7: Obsolete legal versions fail closed
  -- -------------------------------------------------------------------------

  perform set_config(
    'request.jwt.claim.sub',
    v_lender_id::text,
    true
  );
  perform set_config(
    'request.jwt.claim.role',
    'authenticated',
    true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_lender_id,
      'role', 'authenticated'
    )::text,
    true
  );

  v_expected_failure := false;

  begin
    perform public.create_iou_with_schedule(
      v_run_id || '_old_legal',
      v_lender_id,
      v_borrower_id,
      10000,
      0,
      v_start_date,
      1,
      'monthly',
      '2025-01-01',
      '2026-05-03'
    );
  exception
    when sqlstate '42501' then
      v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.ious
       where title = v_run_id || '_old_legal'
     )
  then
    raise exception
      'R7 failed: obsolete legal version was accepted or left a row.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R7: obsolete legal version rejected';

  -- -------------------------------------------------------------------------
  -- R8: State APR trigger remains authoritative and atomic
  -- -------------------------------------------------------------------------

  v_expected_failure := false;

  begin
    perform public.create_iou_with_schedule(
      v_run_id || '_ma_over_cap',
      v_lender_id,
      v_ma_borrower_id,
      10000,
      1201,
      v_start_date,
      1,
      'monthly',
      '2026-05-03',
      '2026-05-03'
    );
  exception
    when sqlstate '22023' then
      v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.ious
       where title = v_run_id || '_ma_over_cap'
     )
  then
    raise exception
      'R8 failed: MA over-cap IOU was accepted or left a row.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R8: state APR enforcement remains atomic';

  -- -------------------------------------------------------------------------
  -- R9: Invalid terms cannot create partial data
  -- -------------------------------------------------------------------------

  v_expected_failure := false;

  begin
    perform public.create_iou_with_schedule(
      v_run_id || '_invalid_term',
      v_lender_id,
      v_borrower_id,
      10000,
      0,
      v_start_date,
      0,
      'monthly',
      '2026-05-03',
      '2026-05-03'
    );
  exception
    when sqlstate '22023' then
      v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.ious
       where title = v_run_id || '_invalid_term'
     )
  then
    raise exception
      'R9 failed: invalid terms created partial data.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R9: invalid terms leave no partial IOU';

  -- -------------------------------------------------------------------------
  -- R10: Past first-payment dates fail closed without residue
  -- -------------------------------------------------------------------------

  v_expected_failure := false;

  begin
    perform public.create_iou_with_schedule(
      v_run_id || '_past_date',
      v_lender_id,
      v_borrower_id,
      10000,
      0,
      current_date - 1,
      1,
      'monthly',
      '2026-05-03',
      '2026-05-03'
    );
  exception
    when sqlstate '22023' then
      v_expected_failure := true;
  end;

  if not v_expected_failure
     or exists (
       select 1
       from public.ious
       where title = v_run_id || '_past_date'
     )
  then
    raise exception
      'R10 failed: past payment date was accepted or left an IOU row.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R10: past first-payment date rejected';

  -- -------------------------------------------------------------------------
  -- R11: Every successful created IOU has its complete schedule
  -- -------------------------------------------------------------------------

  select count(*)
  into v_count
  from public.ious i
  where i.title in (
    v_run_id || '_monthly',
    v_run_id || '_weekly'
  )
    and (
      select count(*)
      from public.payments p
      where p.iou_id = i.id
    ) = i.total_installments;

  if v_count <> 2 then
    raise exception
      'R11 failed: a successful IOU is missing schedule rows.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R11: successful IOUs have complete schedules';

  if v_pass <> 11 then
    raise exception
      'Expected 11 passing checks, received %.',
      v_pass;
  end if;

  insert into atomic_iou_creation_test_result (
    passed_checks,
    expected_checks
  )
  values (
    v_pass,
    11
  );
end;
$test$;

select jsonb_build_object(
  'suite',
    'Atomic Personal IOU creation',
  'passed',
    passed_checks = expected_checks,
  'passed_checks',
    passed_checks,
  'expected_checks',
    expected_checks,
  'cleanup',
    'transaction_rollback',
  'direct_client_iou_insert',
    false,
  'direct_client_payment_insert_delete',
    false
) as atomic_iou_creation_regression_summary
from atomic_iou_creation_test_result;

rollback;
