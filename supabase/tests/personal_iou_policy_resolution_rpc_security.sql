begin;

create temporary table personal_iou_policy_rpc_test_result (
  passed_checks integer not null,
  expected_checks integer not null
) on commit drop;

do $test$
declare
  v_caller_id uuid;
  v_borrower_id uuid;
  v_missing_id uuid := gen_random_uuid();
  v_result jsonb;
  v_pass integer := 0;
  v_expected_failure boolean;
begin
  select
    selected_profile_ids[1],
    selected_profile_ids[2]
  into
    v_caller_id,
    v_borrower_id
  from (
    select array_agg(id order by id) as selected_profile_ids
    from (
      select id
      from public.profiles
      order by id
      limit 2
    ) first_two_profiles
  ) selected_profiles;

  if v_caller_id is null
     or v_borrower_id is null
     or v_caller_id = v_borrower_id
  then
    raise exception
      'RPC regression requires at least two distinct DEV profiles.';
  end if;

  perform set_config(
    'request.jwt.claim.sub',
    v_caller_id::text,
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
      'sub', v_caller_id,
      'role', 'authenticated'
    )::text,
    true
  );

  -- R1: GA resolves to the canonical 1600 bps policy.

  update public.profiles
  set state = 'GA'
  where id = v_borrower_id;

  v_result :=
    public.get_personal_iou_policy(v_borrower_id);

  if v_result ->> 'policy_status' <> 'supported'
     or (v_result ->> 'supported')::boolean is not true
     or (v_result ->> 'max_apr_bps')::integer <> 1600
     or v_result ->> 'policy_version' <> '2026-06-29-v1'
     or v_result ->> 'policy_effective_at' is null
  then
    raise exception
      'R1 failed: incorrect GA policy result: %',
      v_result;
  end if;

  v_pass := v_pass + 1;


  -- R2: MA resolves to the canonical 1200 bps policy.

  update public.profiles
  set state = ' ma '
  where id = v_borrower_id;

  v_result :=
    public.get_personal_iou_policy(v_borrower_id);

  if v_result ->> 'policy_status' <> 'supported'
     or (v_result ->> 'supported')::boolean is not true
     or (v_result ->> 'max_apr_bps')::integer <> 1200
  then
    raise exception
      'R2 failed: incorrect MA policy result: %',
      v_result;
  end if;

  v_pass := v_pass + 1;


  -- R3: Missing state is distinguishable without revealing a state.

  update public.profiles
  set state = null
  where id = v_borrower_id;

  v_result :=
    public.get_personal_iou_policy(v_borrower_id);

  if v_result ->> 'policy_status' <> 'missing_state'
     or (v_result ->> 'supported')::boolean is not false
     or v_result ->> 'max_apr_bps' is not null
  then
    raise exception
      'R3 failed: incorrect missing-state result: %',
      v_result;
  end if;

  v_pass := v_pass + 1;


  -- R4: A state without an enabled policy is unsupported.

  update public.profiles
  set state = 'NY'
  where id = v_borrower_id;

  v_result :=
    public.get_personal_iou_policy(v_borrower_id);

  if v_result ->> 'policy_status' <> 'unsupported_state'
     or (v_result ->> 'supported')::boolean is not false
     or v_result ->> 'max_apr_bps' is not null
  then
    raise exception
      'R4 failed: incorrect unsupported-state result: %',
      v_result;
  end if;

  v_pass := v_pass + 1;


  -- R5: Unknown profile IDs return a generic unavailable result.

  v_result :=
    public.get_personal_iou_policy(v_missing_id);

  if v_result ->> 'policy_status' <> 'unavailable'
     or (v_result ->> 'supported')::boolean is not false
     or v_result ->> 'max_apr_bps' is not null
  then
    raise exception
      'R5 failed: incorrect unavailable result: %',
      v_result;
  end if;

  v_pass := v_pass + 1;


  -- R6: The response never exposes the residence-state field.

  update public.profiles
  set state = 'GA'
  where id = v_borrower_id;

  v_result :=
    public.get_personal_iou_policy(v_borrower_id);

  if v_result ? 'state'
     or v_result ? 'state_code'
     or v_result ? 'borrower_state'
     or v_result ? 'borrower_state_code'
  then
    raise exception
      'R6 failed: policy response exposed residence state: %',
      v_result;
  end if;

  v_pass := v_pass + 1;


  -- R7: Anonymous execution fails closed inside the function.

  perform set_config(
    'request.jwt.claim.sub',
    '',
    true
  );

  perform set_config(
    'request.jwt.claim.role',
    'anon',
    true
  );

  perform set_config(
    'request.jwt.claims',
    '{"role":"anon"}',
    true
  );

  v_expected_failure := false;

  begin
    perform public.get_personal_iou_policy(v_borrower_id);
  exception
    when sqlstate '42501' then
      v_expected_failure := true;
  end;

  if not v_expected_failure then
    raise exception
      'R7 failed: anonymous policy resolution was accepted.';
  end if;

  v_pass := v_pass + 1;


  -- Restore authenticated claims for remaining checks.

  perform set_config(
    'request.jwt.claim.sub',
    v_caller_id::text,
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
      'sub', v_caller_id,
      'role', 'authenticated'
    )::text,
    true
  );


  -- R8: Null borrower IDs are rejected.

  v_expected_failure := false;

  begin
    perform public.get_personal_iou_policy(null);
  exception
    when sqlstate '22023' then
      v_expected_failure := true;
  end;

  if not v_expected_failure then
    raise exception
      'R8 failed: null borrower ID was accepted.';
  end if;

  v_pass := v_pass + 1;


  -- R9: Function ACLs allow authenticated and deny anon.

  if not has_function_privilege(
    'authenticated',
    'public.get_personal_iou_policy(uuid)',
    'EXECUTE'
  ) then
    raise exception
      'R9 failed: authenticated lacks EXECUTE.';
  end if;

  if has_function_privilege(
    'anon',
    'public.get_personal_iou_policy(uuid)',
    'EXECUTE'
  ) then
    raise exception
      'R9 failed: anon unexpectedly has EXECUTE.';
  end if;

  v_pass := v_pass + 1;


  -- R10: Response shape is exact and contains no extra fields.

  v_result :=
    public.get_personal_iou_policy(v_borrower_id);

  if (
    select array_agg(key order by key)
    from jsonb_object_keys(v_result) as keys(key)
  ) <> array[
    'max_apr_bps',
    'policy_effective_at',
    'policy_status',
    'policy_version',
    'supported'
  ]::text[]
  then
    raise exception
      'R10 failed: unexpected response shape: %',
      v_result;
  end if;

  v_pass := v_pass + 1;

  if v_pass <> 10 then
    raise exception
      'Expected 10 passing checks, received %.',
      v_pass;
  end if;

  insert into personal_iou_policy_rpc_test_result (
    passed_checks,
    expected_checks
  )
  values (
    v_pass,
    10
  );
end;
$test$;

select jsonb_build_object(
  'suite',
    'Personal IOU policy resolution RPC security',
  'passed',
    passed_checks = expected_checks,
  'passed_checks',
    passed_checks,
  'expected_checks',
    expected_checks,
  'cleanup',
    'transaction_rollback',
  'raw_state_exposed',
    false
) as personal_iou_policy_rpc_security_summary
from personal_iou_policy_rpc_test_result;

rollback;
