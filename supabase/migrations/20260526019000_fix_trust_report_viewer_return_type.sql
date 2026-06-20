-- IOU Score v2 — Fix Trust Report Viewer Return Type
-- Fixes active_score_ceiling_total bigint/numeric mismatch.
-- No score changes.
-- No privacy model changes.

create or replace function public.get_trust_report_for_viewer(
  p_owner_user_id uuid,
  p_viewer_user_id uuid,
  p_scope text default 'summary'
)
returns table (
  user_id uuid,
  email text,
  public_score integer,
  visible_trust integer,
  trust_tier text,
  proof_depth integer,
  proof_depth_label text,
  confidence_score integer,
  confidence_label text,
  active_score_affecting_agreements bigint,
  active_score_affecting_counterparties bigint,
  active_score_ceiling_total numeric,
  active_risk_flag_count bigint,
  private_risk_summary text,
  sylienn_private_note text,
  latest_snapshot_at timestamptz
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_share_id uuid;
begin
  if p_owner_user_id is null or p_viewer_user_id is null then
    raise exception 'Missing owner or viewer user id';
  end if;

  if not public.has_active_trust_report_share(p_owner_user_id, p_viewer_user_id, p_scope) then
    insert into public.trust_report_access_logs (
      owner_user_id,
      viewer_user_id,
      trust_report_share_id,
      access_type,
      scope,
      metadata
    )
    values (
      p_owner_user_id,
      p_viewer_user_id,
      null,
      'access_denied',
      p_scope,
      jsonb_build_object('reason', 'no_active_share')
    );

    return;
  end if;

  select id
  into v_share_id
  from public.trust_report_shares
  where owner_user_id = p_owner_user_id
    and viewer_user_id = p_viewer_user_id
    and revoked_at is null
    and (expires_at is null or expires_at > now())
  order by created_at desc
  limit 1;

  insert into public.trust_report_access_logs (
    owner_user_id,
    viewer_user_id,
    trust_report_share_id,
    access_type,
    scope,
    metadata
  )
  values (
    p_owner_user_id,
    p_viewer_user_id,
    v_share_id,
    'view',
    p_scope,
    '{}'::jsonb
  );

  return query
  select
    tr.user_id,
    tr.email,
    tr.public_score,
    tr.visible_trust,
    tr.trust_tier,
    tr.proof_depth,
    tr.proof_depth_label,
    tr.confidence_score,
    tr.confidence_label,
    tr.active_score_affecting_agreements,
    tr.active_score_affecting_counterparties,
    tr.active_score_ceiling_total::numeric,
    tr.active_risk_flag_count,
    tr.private_risk_summary,
    tr.sylienn_private_note,
    tr.latest_snapshot_at
  from public.trust_report_shadow_v tr
  where tr.user_id = p_owner_user_id;
end;
$function$;