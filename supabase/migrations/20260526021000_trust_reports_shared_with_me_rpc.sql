-- IOU Score v2 — Trust Reports Shared With Me RPC
-- Lets a signed-in user safely list Trust Reports shared with them.
--
-- No profile score changes.
-- No score event changes.
-- No live scoring switch.
--
-- Privacy rule:
-- A viewer can only list active Trust Report shares where viewer_user_id = auth.uid().

create or replace function public.get_trust_reports_shared_with_me()
returns table (
  share_id uuid,
  owner_user_id uuid,
  owner_email text,
  owner_full_name text,
  owner_iou_hash text,
  scope text,
  reason text,
  expires_at timestamptz,
  created_at timestamptz,
  metadata jsonb
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_auth_user_id uuid := auth.uid();
begin
  if v_auth_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return query
  select
    s.id as share_id,
    s.owner_user_id,
    owner.email as owner_email,
    owner.full_name as owner_full_name,
    owner.iou_hash as owner_iou_hash,
    s.scope,
    s.reason,
    s.expires_at,
    s.created_at,
    s.metadata
  from public.trust_report_shares s
  join public.profiles owner on owner.id = s.owner_user_id
  where s.viewer_user_id = v_auth_user_id
    and s.revoked_at is null
    and (s.expires_at is null or s.expires_at > now())
  order by s.created_at desc;
end;
$function$;