begin;

-- ============================================================================
-- Restrict raw trust-outcome logging functions to trusted backend roles.
--
-- These functions are SECURITY DEFINER and can create scoring evidence.
-- They are backend primitives used by trusted functions such as
-- pay_and_receipt(); app clients must not execute them directly.
-- ============================================================================

revoke all
  on function public.log_trust_outcome_event(
    uuid,
    uuid,
    text,
    uuid,
    text,
    bigint,
    integer,
    integer,
    integer,
    integer,
    uuid,
    jsonb
  )
  from public, anon, authenticated;

revoke all
  on function public.log_score_agreement_outcome(
    uuid,
    text,
    uuid,
    bigint,
    integer,
    integer,
    jsonb
  )
  from public, anon, authenticated;

grant execute
  on function public.log_trust_outcome_event(
    uuid,
    uuid,
    text,
    uuid,
    text,
    bigint,
    integer,
    integer,
    integer,
    integer,
    uuid,
    jsonb
  )
  to service_role, postgres;

grant execute
  on function public.log_score_agreement_outcome(
    uuid,
    text,
    uuid,
    bigint,
    integer,
    integer,
    jsonb
  )
  to service_role, postgres;

comment on function public.log_trust_outcome_event(
  uuid,
  uuid,
  text,
  uuid,
  text,
  bigint,
  integer,
  integer,
  integer,
  integer,
  uuid,
  jsonb
)
is
  'Internal append-only trust evidence logger. Direct execution is restricted to postgres and service_role. App-facing workflows must use authorized domain RPCs.';

comment on function public.log_score_agreement_outcome(
  uuid,
  text,
  uuid,
  bigint,
  integer,
  integer,
  jsonb
)
is
  'Internal score-agreement outcome bridge. Direct execution is restricted to postgres and service_role. Trusted SECURITY DEFINER workflows may call it internally.';

-- --------------------------------------------------------------------------
-- Fail-closed deployment invariants.
-- --------------------------------------------------------------------------
do $invariants$
declare
  v_signature text;
  v_public_execute boolean;
begin
  v_signature :=
    'public.log_trust_outcome_event(uuid,uuid,text,uuid,text,bigint,integer,integer,integer,integer,uuid,jsonb)';

  select exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) as acl
    where p.oid = to_regprocedure(v_signature)
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  )
  into v_public_execute;

  if v_public_execute
     or has_function_privilege('anon', v_signature, 'EXECUTE')
     or has_function_privilege('authenticated', v_signature, 'EXECUTE') then
    raise exception
      'Raw trust outcome logger remains executable by an app role';
  end if;

  if not has_function_privilege('service_role', v_signature, 'EXECUTE')
     or not has_function_privilege('postgres', v_signature, 'EXECUTE') then
    raise exception
      'Raw trust outcome logger is not executable by required backend roles';
  end if;

  v_signature :=
    'public.log_score_agreement_outcome(uuid,text,uuid,bigint,integer,integer,jsonb)';

  select exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) as acl
    where p.oid = to_regprocedure(v_signature)
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  )
  into v_public_execute;

  if v_public_execute
     or has_function_privilege('anon', v_signature, 'EXECUTE')
     or has_function_privilege('authenticated', v_signature, 'EXECUTE') then
    raise exception
      'Score agreement outcome logger remains executable by an app role';
  end if;

  if not has_function_privilege('service_role', v_signature, 'EXECUTE')
     or not has_function_privilege('postgres', v_signature, 'EXECUTE') then
    raise exception
      'Score agreement outcome logger is not executable by required backend roles';
  end if;
end
$invariants$;

commit;
