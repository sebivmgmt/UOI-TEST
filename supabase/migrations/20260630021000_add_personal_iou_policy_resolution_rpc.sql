-- Resolve the canonical Personal IOU jurisdiction policy for a borrower
-- without exposing the borrower's residence state.
--
-- Authenticated callers receive only:
--   * policy_status
--   * supported
--   * max_apr_bps
--   * policy_version
--   * policy_effective_at
--
-- The database trigger remains the authoritative enforcement boundary.

begin;

create or replace function public.get_personal_iou_policy(
  p_borrower_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_state_code text;
  v_policy public.iou_state_apr_policy%rowtype;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'Authentication required.';
  end if;

  if p_borrower_id is null then
    raise exception using
      errcode = '22023',
      message = 'Borrower is required.';
  end if;

  select upper(nullif(btrim(profile.state), ''))
  into v_state_code
  from public.profiles as profile
  where profile.id = p_borrower_id;

  if not found then
    return jsonb_build_object(
      'policy_status', 'unavailable',
      'supported', false,
      'max_apr_bps', null,
      'policy_version', null,
      'policy_effective_at', null
    );
  end if;

  if v_state_code is null then
    return jsonb_build_object(
      'policy_status', 'missing_state',
      'supported', false,
      'max_apr_bps', null,
      'policy_version', null,
      'policy_effective_at', null
    );
  end if;

  select policy.*
  into v_policy
  from public.iou_state_apr_policy as policy
  where policy.state_code = v_state_code
    and policy.personal_iou_enabled is true;

  if not found
     or v_policy.max_apr_bps is null
     or v_policy.policy_version is null
     or v_policy.effective_at is null
  then
    return jsonb_build_object(
      'policy_status', 'unsupported_state',
      'supported', false,
      'max_apr_bps', null,
      'policy_version', null,
      'policy_effective_at', null
    );
  end if;

  return jsonb_build_object(
    'policy_status', 'supported',
    'supported', true,
    'max_apr_bps', v_policy.max_apr_bps,
    'policy_version', v_policy.policy_version,
    'policy_effective_at', v_policy.effective_at
  );
end;
$function$;

revoke all
  on function public.get_personal_iou_policy(uuid)
  from public, anon, authenticated, service_role;

grant execute
  on function public.get_personal_iou_policy(uuid)
  to authenticated, service_role;

comment on function public.get_personal_iou_policy(uuid) is
  'Returns the canonical Personal IOU policy for a borrower without exposing residence state. Authenticated only.';

commit;
