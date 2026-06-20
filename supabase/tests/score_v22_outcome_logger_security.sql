-- ============================================================================
-- Raw trust-outcome logger permission regression
-- Read-only privilege checks; transaction rolled back for consistency.
-- ============================================================================

begin;

do $tests$
declare
  v_trust_signature text :=
    'public.log_trust_outcome_event(uuid,uuid,text,uuid,text,bigint,integer,integer,integer,integer,uuid,jsonb)';
  v_score_signature text :=
    'public.log_score_agreement_outcome(uuid,text,uuid,bigint,integer,integer,jsonb)';
  v_trust_public_execute boolean;
  v_score_public_execute boolean;
begin
  select exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) as acl
    where p.oid = to_regprocedure(v_trust_signature)
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  )
  into v_trust_public_execute;

  select exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) as acl
    where p.oid = to_regprocedure(v_score_signature)
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  )
  into v_score_public_execute;

  if v_trust_public_execute
     or has_function_privilege('anon', v_trust_signature, 'EXECUTE')
     or has_function_privilege('authenticated', v_trust_signature, 'EXECUTE') then
    raise exception
      'Permission regression: raw trust outcome logger is exposed to an app role';
  end if;

  if v_score_public_execute
     or has_function_privilege('anon', v_score_signature, 'EXECUTE')
     or has_function_privilege('authenticated', v_score_signature, 'EXECUTE') then
    raise exception
      'Permission regression: score agreement outcome logger is exposed to an app role';
  end if;

  if not has_function_privilege('service_role', v_trust_signature, 'EXECUTE')
     or not has_function_privilege('postgres', v_trust_signature, 'EXECUTE')
     or not has_function_privilege('service_role', v_score_signature, 'EXECUTE')
     or not has_function_privilege('postgres', v_score_signature, 'EXECUTE') then
    raise exception
      'Permission regression: a required backend role lost logger execution';
  end if;
end
$tests$;

select jsonb_build_object(
  'suite', 'Score v2.2 raw outcome logger security',
  'passed', true,
  'public_denied', true,
  'anon_denied', true,
  'authenticated_denied', true,
  'service_role_allowed', true,
  'postgres_allowed', true,
  'cleanup', 'transaction_rollback'
) as score_v22_outcome_logger_security_summary;

rollback;
