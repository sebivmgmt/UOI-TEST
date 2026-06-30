-- Personal IOU borrower-state and APR policy regression.
--
-- Requires:
--   20260629020000_add_iou_state_apr_policy.sql
--
-- Every synthetic user and agreement is transactionally rolled back.
-- This file must never mutate LIVE.

begin;

do $test$
declare
  v_run_id text :=
    'state_apr_' || substr(gen_random_uuid()::text, 1, 8);

  v_lender_ga uuid := gen_random_uuid();
  v_lender_ma uuid := gen_random_uuid();

  v_borrower_ga uuid := gen_random_uuid();
  v_borrower_fl uuid := gen_random_uuid();
  v_borrower_ma uuid := gen_random_uuid();
  v_borrower_ny uuid := gen_random_uuid();
  v_borrower_null uuid := gen_random_uuid();
  v_borrower_lower_ma uuid := gen_random_uuid();

  v_iou_id uuid;
  v_snapshot_iou_id uuid;
  v_legacy_compliant_iou_id uuid;
  v_legacy_above_cap_iou_id uuid;
  v_state text;
  v_cap integer;
  v_version text;
  v_effective_at timestamptz;

  v_pass integer := 0;
  v_expected_failure boolean;
  v_error_message text;
  v_policy_count integer;
begin
  -- ── Fixture users ─────────────────────────────────────────────────────────

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
      v_lender_ga,
      v_run_id || '_lender_ga@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"GA Test Lender"}'::jsonb,
      false
    ),
    (
      v_lender_ma,
      v_run_id || '_lender_ma@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"MA Test Lender"}'::jsonb,
      false
    ),
    (
      v_borrower_ga,
      v_run_id || '_borrower_ga@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"GA Test Borrower"}'::jsonb,
      false
    ),
    (
      v_borrower_fl,
      v_run_id || '_borrower_fl@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"FL Test Borrower"}'::jsonb,
      false
    ),
    (
      v_borrower_ma,
      v_run_id || '_borrower_ma@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"MA Test Borrower"}'::jsonb,
      false
    ),
    (
      v_borrower_ny,
      v_run_id || '_borrower_ny@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"NY Test Borrower"}'::jsonb,
      false
    ),
    (
      v_borrower_null,
      v_run_id || '_borrower_null@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Null-State Test Borrower"}'::jsonb,
      false
    ),
    (
      v_borrower_lower_ma,
      v_run_id || '_borrower_lower_ma@test.invalid',
      'authenticated',
      'authenticated',
      now(),
      now(),
      now(),
      '{"full_name":"Lowercase MA Test Borrower"}'::jsonb,
      false
    );

  update public.profiles
  set state =
    case id
      when v_lender_ga then 'GA'
      when v_lender_ma then 'MA'
      when v_borrower_ga then 'GA'
      when v_borrower_fl then 'FL'
      when v_borrower_ma then 'MA'
      when v_borrower_ny then 'NY'
      when v_borrower_lower_ma then ' ma '
      else null
    end
  where id in (
    v_lender_ga,
    v_lender_ma,
    v_borrower_ga,
    v_borrower_fl,
    v_borrower_ma,
    v_borrower_ny,
    v_borrower_null,
    v_borrower_lower_ma
  );

  if (
    select count(*)
    from public.profiles
    where id in (
      v_lender_ga,
      v_lender_ma,
      v_borrower_ga,
      v_borrower_fl,
      v_borrower_ma,
      v_borrower_ny,
      v_borrower_null,
      v_borrower_lower_ma
    )
  ) <> 8 then
    raise exception 'Fixture setup failed: expected 8 profiles.';
  end if;


  -- ── R1: Exact canonical policy rows ───────────────────────────────────────

  select count(*)
  into v_policy_count
  from public.iou_state_apr_policy
  where (
      state_code = 'GA'
      and personal_iou_enabled
      and max_apr_bps = 1600
      and policy_version = '2026-06-29-v1'
    )
    or (
      state_code = 'FL'
      and personal_iou_enabled
      and max_apr_bps = 1600
      and policy_version = '2026-06-29-v1'
    )
    or (
      state_code = 'MA'
      and personal_iou_enabled
      and max_apr_bps = 1200
      and policy_version = '2026-06-29-v1'
    );

  if v_policy_count <> 3 then
    raise exception
      'R1 failed: expected exact GA/FL/MA policy rows, found %.',
      v_policy_count;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R1: canonical GA/FL/MA policy rows';


  -- ── R2: GA borrower at 1600 bps succeeds ──────────────────────────────────

  v_iou_id := gen_random_uuid();

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values (
    v_iou_id,
    v_lender_ga,
    v_borrower_ga,
    50000,
    1600,
    current_date,
    1,
    'monthly',
    'draft'
  );

  select
    borrower_state_code,
    borrower_max_apr_bps,
    state_policy_version,
    state_policy_effective_at
  into
    v_state,
    v_cap,
    v_version,
    v_effective_at
  from public.ious
  where id = v_iou_id;

  if v_state <> 'GA'
     or v_cap <> 1600
     or v_version <> '2026-06-29-v1'
     or v_effective_at is null
  then
    raise exception
      'R2 failed: wrong GA snapshot state=%, cap=%, version=%, effective_at=%',
      v_state,
      v_cap,
      v_version,
      v_effective_at;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R2: GA 1600 bps accepted and snapshotted';


  -- ── R3: FL borrower at 1600 bps succeeds ──────────────────────────────────

  v_iou_id := gen_random_uuid();

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values (
    v_iou_id,
    v_lender_ga,
    v_borrower_fl,
    50000,
    1600,
    current_date,
    1,
    'monthly',
    'draft'
  );

  select borrower_state_code, borrower_max_apr_bps
  into v_state, v_cap
  from public.ious
  where id = v_iou_id;

  if v_state <> 'FL' or v_cap <> 1600 then
    raise exception
      'R3 failed: wrong FL snapshot state=%, cap=%',
      v_state,
      v_cap;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R3: FL 1600 bps accepted and snapshotted';


  -- ── R4: MA borrower at 1200 bps succeeds ──────────────────────────────────

  v_iou_id := gen_random_uuid();

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values (
    v_iou_id,
    v_lender_ga,
    v_borrower_ma,
    50000,
    1200,
    current_date,
    1,
    'monthly',
    'draft'
  );

  select borrower_state_code, borrower_max_apr_bps
  into v_state, v_cap
  from public.ious
  where id = v_iou_id;

  if v_state <> 'MA' or v_cap <> 1200 then
    raise exception
      'R4 failed: wrong MA snapshot state=%, cap=%',
      v_state,
      v_cap;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R4: MA 1200 bps accepted and snapshotted';


  -- ── R5: MA borrower at 1201 bps fails ─────────────────────────────────────

  v_expected_failure := false;
  v_error_message := null;

  begin
    insert into public.ious (
      id,
      lender_id,
      borrower_id,
      principal_cents,
      apr_bps,
      start_date,
      term_months,
      frequency,
      status
    )
    values (
      gen_random_uuid(),
      v_lender_ga,
      v_borrower_ma,
      50000,
      1201,
      current_date,
      1,
      'monthly',
      'draft'
    );
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure :=
        v_error_message like
          'APR 1201 bps exceeds the 1200 bps cap for borrower state MA.%';
  end;

  if not v_expected_failure then
    raise exception
      'R5 failed: MA 1201 bps was not rejected correctly. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R5: MA 1201 bps rejected';


  -- ── R6: GA borrower at 1601 bps fails ─────────────────────────────────────

  v_expected_failure := false;
  v_error_message := null;

  begin
    insert into public.ious (
      id,
      lender_id,
      borrower_id,
      principal_cents,
      apr_bps,
      start_date,
      term_months,
      frequency,
      status
    )
    values (
      gen_random_uuid(),
      v_lender_ga,
      v_borrower_ga,
      50000,
      1601,
      current_date,
      1,
      'monthly',
      'draft'
    );
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure :=
        v_error_message like
          'APR 1601 bps exceeds the 1600 bps cap for borrower state GA.%';
  end;

  if not v_expected_failure then
    raise exception
      'R6 failed: GA 1601 bps was not rejected correctly. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R6: GA 1601 bps rejected';


  -- ── R7: Unsupported state fails even at 0% ────────────────────────────────

  v_expected_failure := false;
  v_error_message := null;

  begin
    insert into public.ious (
      id,
      lender_id,
      borrower_id,
      principal_cents,
      apr_bps,
      start_date,
      term_months,
      frequency,
      status
    )
    values (
      gen_random_uuid(),
      v_lender_ga,
      v_borrower_ny,
      50000,
      0,
      current_date,
      1,
      'monthly',
      'draft'
    );
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure =
        v_error_message =
          'State NY is not supported for Personal IOUs.';
  end;

  if not v_expected_failure then
    raise exception
      'R7 failed: unsupported NY borrower was not rejected. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R7: unsupported state fails closed at 0%%';


  -- ── R8: Missing state fails even with NULL APR ────────────────────────────

  v_expected_failure := false;
  v_error_message := null;

  begin
    insert into public.ious (
      id,
      lender_id,
      borrower_id,
      principal_cents,
      apr_bps,
      start_date,
      term_months,
      frequency,
      status
    )
    values (
      gen_random_uuid(),
      v_lender_ga,
      v_borrower_null,
      50000,
      null,
      current_date,
      1,
      'monthly',
      'draft'
    );
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure =
        v_error_message =
          'Borrower residence state is not set.';
  end;

  if not v_expected_failure then
    raise exception
      'R8 failed: missing borrower state was not rejected. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R8: missing state fails closed with NULL APR';


  -- ── R9: Lender state cannot override MA borrower cap ──────────────────────

  v_expected_failure := false;
  v_error_message := null;

  begin
    insert into public.ious (
      id,
      lender_id,
      borrower_id,
      principal_cents,
      apr_bps,
      start_date,
      term_months,
      frequency,
      status
    )
    values (
      gen_random_uuid(),
      v_lender_ga,
      v_borrower_ma,
      50000,
      1300,
      current_date,
      1,
      'monthly',
      'draft'
    );
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure :=
        v_error_message like
          'APR 1300 bps exceeds the 1200 bps cap for borrower state MA.%';
  end;

  if not v_expected_failure then
    raise exception
      'R9 failed: GA lender overrode MA borrower cap. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R9: borrower state controls over lender state';


  -- ── R10: MA lender + FL borrower at 1300 bps succeeds ─────────────────────

  v_iou_id := gen_random_uuid();

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values (
    v_iou_id,
    v_lender_ma,
    v_borrower_fl,
    50000,
    1300,
    current_date,
    1,
    'monthly',
    'draft'
  );

  select borrower_state_code, borrower_max_apr_bps
  into v_state, v_cap
  from public.ious
  where id = v_iou_id;

  if v_state <> 'FL' or v_cap <> 1600 then
    raise exception
      'R10 failed: lender state affected FL borrower snapshot.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R10: MA lender does not impose MA cap on FL borrower';


  -- ── R11: Supported borrower with NULL APR still receives snapshot ─────────

  v_iou_id := gen_random_uuid();

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values (
    v_iou_id,
    v_lender_ga,
    v_borrower_ma,
    50000,
    null,
    current_date,
    1,
    'monthly',
    'draft'
  );

  select borrower_state_code, borrower_max_apr_bps
  into v_state, v_cap
  from public.ious
  where id = v_iou_id;

  if v_state <> 'MA' or v_cap <> 1200 then
    raise exception
      'R11 failed: NULL APR did not receive MA policy snapshot.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R11: supported NULL-APR IOU is snapshotted';


  -- ── R12: Incoming snapshot spoof is overwritten ───────────────────────────

  v_iou_id := gen_random_uuid();

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
    borrower_state_code,
    borrower_max_apr_bps,
    state_policy_version,
    state_policy_effective_at
  )
  values (
    v_iou_id,
    v_lender_ga,
    v_borrower_ma,
    50000,
    1200,
    current_date,
    1,
    'monthly',
    'draft',
    'FL',
    1600,
    'spoofed-version',
    now() - interval '20 years'
  );

  select
    borrower_state_code,
    borrower_max_apr_bps,
    state_policy_version,
    state_policy_effective_at
  into
    v_state,
    v_cap,
    v_version,
    v_effective_at
  from public.ious
  where id = v_iou_id;

  if v_state <> 'MA'
     or v_cap <> 1200
     or v_version <> '2026-06-29-v1'
     or v_effective_at <>
       timestamptz '2026-06-29 00:00:00+00'
  then
    raise exception
      'R12 failed: incoming snapshot spoof was not overwritten.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R12: insert snapshot spoof overwritten';


  -- ── R13: Existing snapshot cannot be edited directly ──────────────────────

  v_expected_failure := false;
  v_error_message := null;

  begin
    update public.ious
    set borrower_max_apr_bps = 1600
    where id = v_iou_id;
  exception
    when sqlstate '42501' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure =
        v_error_message =
          'IOU state-policy snapshots are system-managed and immutable.';
  end;

  if not v_expected_failure then
    raise exception
      'R13 failed: snapshot mutation was not rejected. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R13: direct snapshot mutation rejected';


  -- ── R14: APR update above snapshotted cap fails ───────────────────────────

  v_expected_failure := false;
  v_error_message := null;

  begin
    update public.ious
    set apr_bps = 1201
    where id = v_iou_id;
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure :=
        v_error_message like
          'APR 1201 bps exceeds the 1200 bps cap for borrower state MA.%';
  end;

  if not v_expected_failure then
    raise exception
      'R14 failed: direct APR update bypassed MA cap. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R14: direct APR update cannot bypass snapshot cap';


  -- ── R15: Later profile-state change does not alter agreement policy ───────

  v_snapshot_iou_id := gen_random_uuid();

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values (
    v_snapshot_iou_id,
    v_lender_ga,
    v_borrower_ma,
    50000,
    1200,
    current_date,
    1,
    'monthly',
    'draft'
  );

  update public.profiles
  set state = 'FL'
  where id = v_borrower_ma;

  v_expected_failure := false;
  v_error_message := null;

  begin
    update public.ious
    set apr_bps = 1300
    where id = v_snapshot_iou_id;
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure :=
        v_error_message like
          'APR 1300 bps exceeds the 1200 bps cap for borrower state MA.%';
  end;

  update public.profiles
  set state = 'MA'
  where id = v_borrower_ma;

  if not v_expected_failure then
    raise exception
      'R15 failed: later profile state changed governing agreement cap. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R15: agreement snapshot survives later profile change';


  -- ── R16: Borrower change before activation re-resolves policy ─────────────

  v_iou_id := gen_random_uuid();

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values (
    v_iou_id,
    v_lender_ga,
    v_borrower_ga,
    50000,
    1200,
    current_date,
    1,
    'monthly',
    'draft'
  );

  update public.ious
  set borrower_id = v_borrower_ma
  where id = v_iou_id;

  select borrower_state_code, borrower_max_apr_bps
  into v_state, v_cap
  from public.ious
  where id = v_iou_id;

  if v_state <> 'MA' or v_cap <> 1200 then
    raise exception
      'R16 failed: pre-activation borrower change did not re-snapshot MA.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R16: pre-activation borrower change re-snapshots policy';


  -- ── R17: Borrower change after activation is blocked ──────────────────────

  v_iou_id := gen_random_uuid();

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
    activated_at
  )
  values (
    v_iou_id,
    v_lender_ga,
    v_borrower_ga,
    50000,
    1200,
    current_date,
    1,
    'monthly',
    'open',
    now()
  );

  v_expected_failure := false;
  v_error_message := null;

  begin
    update public.ious
    set borrower_id = v_borrower_fl
    where id = v_iou_id;
  exception
    when sqlstate '23514' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure =
        v_error_message =
          'Borrower cannot be changed after IOU activation.';
  end;

  if not v_expected_failure then
    raise exception
      'R17 failed: activated IOU borrower was changeable. Error=%',
      v_error_message;
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R17: post-activation borrower change rejected';


  -- ── R18: State input is normalized before snapshot ────────────────────────

  v_iou_id := gen_random_uuid();

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values (
    v_iou_id,
    v_lender_ga,
    v_borrower_lower_ma,
    50000,
    1200,
    current_date,
    1,
    'monthly',
    'draft'
  );

  select borrower_state_code, borrower_max_apr_bps
  into v_state, v_cap
  from public.ious
  where id = v_iou_id;

  if v_state <> 'MA' or v_cap <> 1200 then
    raise exception
      'R18 failed: lowercase/whitespace MA state was not normalized.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R18: borrower state normalized to MA';


  -- ── R19: Authenticated may read policy but cannot mutate it ───────────────

  if not has_table_privilege(
    'authenticated',
    'public.iou_state_apr_policy',
    'SELECT'
  ) then
    raise exception
      'R19 failed: authenticated role lacks policy SELECT.';
  end if;

  if has_table_privilege(
       'authenticated',
       'public.iou_state_apr_policy',
       'INSERT'
     )
     or has_table_privilege(
       'authenticated',
       'public.iou_state_apr_policy',
       'UPDATE'
     )
     or has_table_privilege(
       'authenticated',
       'public.iou_state_apr_policy',
       'DELETE'
     )
  then
    raise exception
      'R19 failed: authenticated role can mutate state policy.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R19: policy is authenticated-readable and non-mutable';


  -- ── R20: Trigger function is not app-callable ─────────────────────────────

  if has_function_privilege(
    'authenticated',
    'public.enforce_iou_state_apr_policy()',
    'EXECUTE'
  ) then
    raise exception
      'R20 failed: authenticated can execute internal trigger function.';
  end if;

  if has_function_privilege(
    'anon',
    'public.enforce_iou_state_apr_policy()',
    'EXECUTE'
  ) then
    raise exception
      'R20 failed: anon can execute internal trigger function.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R20: enforcement function is internal only';


  -- ── R21: Enforcement trigger exists exactly once ─────────────────────────

  if (
    select count(*)
    from pg_trigger
    where tgrelid = 'public.ious'::regclass
      and tgname = 'ious_state_apr_policy_enforcement_trg'
      and not tgisinternal
  ) <> 1 then
    raise exception
      'R21 failed: enforcement trigger is missing or duplicated.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R21: enforcement trigger exists exactly once';


  -- ── Legacy fixture setup ──────────────────────────────────────────────────
  --
  -- Simulate rows created before this migration by temporarily disabling only
  -- the new enforcement trigger. All changes remain inside this transaction.

  v_legacy_compliant_iou_id := gen_random_uuid();
  v_legacy_above_cap_iou_id := gen_random_uuid();

  alter table public.ious
    disable trigger ious_state_apr_policy_enforcement_trg;

  insert into public.ious (
    id,
    lender_id,
    borrower_id,
    principal_cents,
    apr_bps,
    start_date,
    term_months,
    frequency,
    status
  )
  values
    (
      v_legacy_compliant_iou_id,
      v_lender_ga,
      v_borrower_ma,
      50000,
      1200,
      current_date,
      1,
      'monthly',
      'draft'
    ),
    (
      v_legacy_above_cap_iou_id,
      v_lender_ga,
      v_borrower_ma,
      50000,
      1300,
      current_date,
      1,
      'monthly',
      'draft'
    );

  alter table public.ious
    enable trigger ious_state_apr_policy_enforcement_trg;


  -- ── R22: Unrelated lifecycle update preserves legacy row ──────────────────

  update public.ious
  set status = 'open'
  where id = v_legacy_above_cap_iou_id;

  select borrower_state_code, borrower_max_apr_bps
  into v_state, v_cap
  from public.ious
  where id = v_legacy_above_cap_iou_id;

  if v_state is not null or v_cap is not null then
    raise exception
      'R22 failed: unrelated status update unexpectedly snapshotted legacy IOU.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R22: lifecycle update preserves legacy agreement';


  -- ── R23: Same-value APR assignment preserves legacy row ───────────────────

  update public.ious
  set apr_bps = apr_bps
  where id = v_legacy_above_cap_iou_id;

  select borrower_state_code, borrower_max_apr_bps
  into v_state, v_cap
  from public.ious
  where id = v_legacy_above_cap_iou_id;

  if v_state is not null or v_cap is not null then
    raise exception
      'R23 failed: same-value APR assignment snapshotted legacy IOU.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R23: same-value APR assignment preserves legacy IOU';


  -- ── R24: Real compliant APR amendment snapshots legacy row ────────────────

  update public.ious
  set apr_bps = 1100
  where id = v_legacy_compliant_iou_id;

  select
    borrower_state_code,
    borrower_max_apr_bps,
    state_policy_version
  into
    v_state,
    v_cap,
    v_version
  from public.ious
  where id = v_legacy_compliant_iou_id;

  if v_state <> 'MA'
     or v_cap <> 1200
     or v_version <> '2026-06-29-v1'
  then
    raise exception
      'R24 failed: compliant legacy amendment did not receive MA snapshot.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R24: compliant legacy amendment becomes policy-governed';


  -- ── R25: Above-cap legacy amendment is rejected ───────────────────────────

  v_expected_failure := false;
  v_error_message := null;

  begin
    update public.ious
    set apr_bps = 1250
    where id = v_legacy_above_cap_iou_id;
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_error_message = message_text;
      v_expected_failure :=
        v_error_message like
          'APR 1250 bps exceeds the 1200 bps cap for borrower state MA.%';
  end;

  if not v_expected_failure then
    raise exception
      'R25 failed: above-cap legacy amendment was accepted. Error=%',
      v_error_message;
  end if;

  if (
    select apr_bps
    from public.ious
    where id = v_legacy_above_cap_iou_id
  ) <> 1300 then
    raise exception
      'R25 failed: rejected amendment changed the legacy APR.';
  end if;

  v_pass := v_pass + 1;
  raise notice 'PASS R25: above-cap legacy amendment rejected';


  raise notice
    'IOU STATE APR POLICY REGRESSION PASSED: %/25 checks.',
    v_pass;

  if v_pass <> 25 then
    raise exception
      'Expected 25 passing checks, received %.',
      v_pass;
  end if;
end;
$test$;

rollback;
