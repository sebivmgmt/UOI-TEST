-- Schedule RPC privilege hardening regression.
-- Expected cleanup: transaction_rollback.
-- Verifies PUBLIC/anon cannot execute schedule lifecycle RPCs while authenticated/service_role can.
-- Uses pg_get_function_identity_arguments() strings as observed on DEV, including argument names.

begin;

do $$
declare
  expected_count integer;
  bad_public_count integer;
  bad_anon_acl_count integer;
  bad_anon_effective_count integer;
  bad_authenticated_count integer;
  bad_service_role_count integer;
begin
  with expected(proname, args) as (
    values
      (
        'finalize_iou_schedule',
        'p_iou_id uuid, p_payments jsonb, p_title text, p_lender_id uuid, p_borrower_id uuid, p_principal_cents bigint, p_apr_bps integer, p_start_date date, p_term_months integer, p_frequency text'
      ),
      (
        'propose_schedule_change',
        'p_iou_id uuid, p_payments jsonb'
      ),
      (
        'reject_schedule_change',
        'p_iou_id uuid'
      )
  ),
  matched as (
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join expected e
      on e.proname = p.proname
     and e.args = pg_get_function_identity_arguments(p.oid)
    where n.nspname = 'public'
  )
  select count(*) into expected_count from matched;

  if expected_count <> 3 then
    raise exception 'FAIL schedule_rpc_privilege_hardening: expected exactly 3 schedule RPC signatures, found %', expected_count;
  end if;

  with expected(proname, args) as (
    values
      (
        'finalize_iou_schedule',
        'p_iou_id uuid, p_payments jsonb, p_title text, p_lender_id uuid, p_borrower_id uuid, p_principal_cents bigint, p_apr_bps integer, p_start_date date, p_term_months integer, p_frequency text'
      ),
      (
        'propose_schedule_change',
        'p_iou_id uuid, p_payments jsonb'
      ),
      (
        'reject_schedule_change',
        'p_iou_id uuid'
      )
  ),
  matched as (
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join expected e
      on e.proname = p.proname
     and e.args = pg_get_function_identity_arguments(p.oid)
    where n.nspname = 'public'
  )
  select count(*) into bad_public_count
  from matched m
  join pg_proc p on p.oid = m.oid
  join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl on true
  where acl.grantee = 0
    and acl.privilege_type = 'EXECUTE';

  if bad_public_count <> 0 then
    raise exception 'FAIL schedule_rpc_privilege_hardening: PUBLIC EXECUTE ACL remains on % entries', bad_public_count;
  end if;

  with expected(proname, args) as (
    values
      (
        'finalize_iou_schedule',
        'p_iou_id uuid, p_payments jsonb, p_title text, p_lender_id uuid, p_borrower_id uuid, p_principal_cents bigint, p_apr_bps integer, p_start_date date, p_term_months integer, p_frequency text'
      ),
      (
        'propose_schedule_change',
        'p_iou_id uuid, p_payments jsonb'
      ),
      (
        'reject_schedule_change',
        'p_iou_id uuid'
      )
  ),
  matched as (
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join expected e
      on e.proname = p.proname
     and e.args = pg_get_function_identity_arguments(p.oid)
    where n.nspname = 'public'
  )
  select count(*) into bad_anon_acl_count
  from matched m
  join pg_proc p on p.oid = m.oid
  join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl on true
  join pg_roles r on r.oid = acl.grantee
  where r.rolname = 'anon'
    and acl.privilege_type = 'EXECUTE';

  if bad_anon_acl_count <> 0 then
    raise exception 'FAIL schedule_rpc_privilege_hardening: direct anon EXECUTE ACL remains on % entries', bad_anon_acl_count;
  end if;

  with expected(proname, args) as (
    values
      (
        'finalize_iou_schedule',
        'p_iou_id uuid, p_payments jsonb, p_title text, p_lender_id uuid, p_borrower_id uuid, p_principal_cents bigint, p_apr_bps integer, p_start_date date, p_term_months integer, p_frequency text'
      ),
      (
        'propose_schedule_change',
        'p_iou_id uuid, p_payments jsonb'
      ),
      (
        'reject_schedule_change',
        'p_iou_id uuid'
      )
  ),
  matched as (
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join expected e
      on e.proname = p.proname
     and e.args = pg_get_function_identity_arguments(p.oid)
    where n.nspname = 'public'
  )
  select count(*) into bad_anon_effective_count
  from matched
  where has_function_privilege('anon', oid, 'EXECUTE');

  if bad_anon_effective_count <> 0 then
    raise exception 'FAIL schedule_rpc_privilege_hardening: anon still has effective EXECUTE on % entries', bad_anon_effective_count;
  end if;

  with expected(proname, args) as (
    values
      (
        'finalize_iou_schedule',
        'p_iou_id uuid, p_payments jsonb, p_title text, p_lender_id uuid, p_borrower_id uuid, p_principal_cents bigint, p_apr_bps integer, p_start_date date, p_term_months integer, p_frequency text'
      ),
      (
        'propose_schedule_change',
        'p_iou_id uuid, p_payments jsonb'
      ),
      (
        'reject_schedule_change',
        'p_iou_id uuid'
      )
  ),
  matched as (
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join expected e
      on e.proname = p.proname
     and e.args = pg_get_function_identity_arguments(p.oid)
    where n.nspname = 'public'
  )
  select count(*) into bad_authenticated_count
  from matched
  where not has_function_privilege('authenticated', oid, 'EXECUTE');

  if bad_authenticated_count <> 0 then
    raise exception 'FAIL schedule_rpc_privilege_hardening: authenticated is missing EXECUTE on % entries', bad_authenticated_count;
  end if;

  with expected(proname, args) as (
    values
      (
        'finalize_iou_schedule',
        'p_iou_id uuid, p_payments jsonb, p_title text, p_lender_id uuid, p_borrower_id uuid, p_principal_cents bigint, p_apr_bps integer, p_start_date date, p_term_months integer, p_frequency text'
      ),
      (
        'propose_schedule_change',
        'p_iou_id uuid, p_payments jsonb'
      ),
      (
        'reject_schedule_change',
        'p_iou_id uuid'
      )
  ),
  matched as (
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join expected e
      on e.proname = p.proname
     and e.args = pg_get_function_identity_arguments(p.oid)
    where n.nspname = 'public'
  )
  select count(*) into bad_service_role_count
  from matched
  where not has_function_privilege('service_role', oid, 'EXECUTE');

  if bad_service_role_count <> 0 then
    raise exception 'FAIL schedule_rpc_privilege_hardening: service_role is missing EXECUTE on % entries', bad_service_role_count;
  end if;

  raise notice 'PASS schedule_rpc_privilege_hardening: signatures exact, PUBLIC false, anon false, authenticated true, service_role true';
end $$;

rollback;
