-- IOU Score v2 — Trust Report Access Log RPC
-- Lets a user safely read their own Trust Report access log with viewer identity.
--
-- No profile score changes.
-- No score event changes.
-- No live scoring switch.
--
-- Privacy rule:
-- Only the owner of the Trust Report can read these access logs.

create or replace function public.get_my_trust_report_access_logs()
returns table (
  id uuid,
  owner_user_id uuid,
  viewer_user_id uuid,
  viewer_email text,
  viewer_full_name text,
  viewer_iou_hash text,
  access_type text,
  scope text,
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
    l.id,
    l.owner_user_id,
    l.viewer_user_id,
    viewer.email as viewer_email,
    viewer.full_name as viewer_full_name,
    viewer.iou_hash as viewer_iou_hash,
    l.access_type,
    l.scope,
    l.created_at,
    l.metadata
  from public.trust_report_access_logs l
  left join public.profiles viewer on viewer.id = l.viewer_user_id
  where l.owner_user_id = v_auth_user_id
  order by l.created_at desc;
end;
$function$;