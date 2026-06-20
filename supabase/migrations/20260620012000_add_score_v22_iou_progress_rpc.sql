begin;

-- ============================================================================
-- Score v2.2 IOU-facing progress RPC
--
-- The app knows ious.id, not the internal score_agreements.id. This wrapper
-- resolves the borrower's score agreement internally and returns the already
-- curated Score v2.2 progress payload.
--
-- score_agreements remains internal-only. No table SELECT grant is added.
-- ============================================================================

create or replace function public.get_my_iou_score_v22_progress(
  p_iou_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_caller_id uuid;
  v_caller_role text;
  v_score_agreement_id uuid;
begin
  v_caller_id := auth.uid();

  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (
      nullif(
        current_setting('request.jwt.claims', true),
        ''
      )::jsonb ->> 'role'
    ),
    ''
  );

  if v_caller_id is null then
    -- App-role claims must carry an authenticated user id. This intentionally
    -- wins over the postgres session bypass used by Management API tests.
    if v_caller_role in ('anon', 'authenticated') then
      raise exception 'Authentication required'
        using errcode = '42501';
    elsif v_caller_role = 'service_role' then
      null;
    elsif session_user = 'postgres' then
      null;
    else
      raise exception 'Authentication required'
        using errcode = '42501';
    end if;
  end if;

  begin
    select sa.id
    into strict v_score_agreement_id
    from public.score_agreements as sa
    where sa.source_type = 'personal_iou'
      and sa.source_id = p_iou_id
      and (
        v_caller_id is null
        or sa.user_id = v_caller_id
      );
  exception
    when no_data_found or too_many_rows then
      -- Missing, unauthorized, unsupported, and ambiguous records all use the
      -- same denial so callers cannot probe internal score-agreement state.
      raise exception 'IOU score progress not found or not accessible'
        using errcode = '42501';
  end;

  return public.get_my_score_v22_progress(v_score_agreement_id);
end
$function$;

revoke all
  on function public.get_my_iou_score_v22_progress(uuid)
  from public, anon, authenticated, service_role;

grant execute
  on function public.get_my_iou_score_v22_progress(uuid)
  to authenticated, service_role, postgres;

comment on function public.get_my_iou_score_v22_progress(uuid)
is
  'Authenticated borrower-facing Score v2.2 progress RPC. Accepts ious.id, resolves the internal personal-IOU score agreement where score_agreements.user_id = auth.uid(), and returns the curated get_my_score_v22_progress payload.';

-- score_agreements must remain internal-only.
revoke select
  on table public.score_agreements
  from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Fail-closed deployment invariants.
-- --------------------------------------------------------------------------
do $invariants$
declare
  v_count integer;
  v_security_definer boolean;
begin
  select p.prosecdef
  into v_security_definer
  from pg_proc as p
  join pg_namespace as n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_my_iou_score_v22_progress'
    and pg_get_function_identity_arguments(p.oid) = 'p_iou_id uuid';

  if v_security_definer is distinct from true then
    raise exception
      'get_my_iou_score_v22_progress must remain SECURITY DEFINER';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_progress'
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_count <> 1 then
    raise exception
      'authenticated must have exactly one EXECUTE grant on get_my_iou_score_v22_progress; found %',
      v_count;
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_progress'
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'PUBLIC/anon must not execute get_my_iou_score_v22_progress';
  end if;

  select count(*)
  into v_count
  from information_schema.table_privileges
  where table_schema = 'public'
    and table_name = 'score_agreements'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'SELECT';

  if v_count <> 0 then
    raise exception
      'score_agreements SELECT was exposed to an app role';
  end if;
end
$invariants$;

commit;
