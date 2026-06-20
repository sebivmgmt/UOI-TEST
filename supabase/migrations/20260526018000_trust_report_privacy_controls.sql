-- IOU Score v2 — Trust Report Privacy Controls
-- Phone number can find a person. Only consent can reveal trust.
--
-- No profile score changes.
-- No score event changes.
-- No live scoring switch.

create table if not exists public.profile_visibility_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,

  allow_phone_discovery boolean not null default true,
  allow_email_discovery boolean not null default true,

  trust_report_default_visibility text not null default 'private' check (
    trust_report_default_visibility in ('private', 'connections_only', 'share_only')
  ),

  show_basic_verified_badge boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trust_report_shares (
  id uuid primary key default gen_random_uuid(),

  owner_user_id uuid not null references public.profiles(id) on delete cascade,
  viewer_user_id uuid not null references public.profiles(id) on delete cascade,

  trust_score_snapshot_id uuid null references public.trust_score_snapshots(id) on delete set null,

  scope text not null default 'summary' check (
    scope in ('summary', 'full_report', 'agreement_only')
  ),

  reason text null,

  expires_at timestamptz null,
  revoked_at timestamptz null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  metadata jsonb not null default '{}'::jsonb,

  constraint trust_report_shares_no_self_share
    check (owner_user_id <> viewer_user_id)
);

create index if not exists trust_report_shares_owner_idx
on public.trust_report_shares (owner_user_id);

create index if not exists trust_report_shares_viewer_idx
on public.trust_report_shares (viewer_user_id);

create index if not exists trust_report_shares_active_lookup_idx
on public.trust_report_shares (owner_user_id, viewer_user_id, revoked_at, expires_at);

create table if not exists public.trust_report_access_logs (
  id uuid primary key default gen_random_uuid(),

  owner_user_id uuid not null references public.profiles(id) on delete cascade,
  viewer_user_id uuid not null references public.profiles(id) on delete cascade,

  trust_report_share_id uuid null references public.trust_report_shares(id) on delete set null,

  access_type text not null default 'view' check (
    access_type in ('view', 'share_created', 'share_revoked', 'share_expired_denied', 'access_denied')
  ),

  scope text null,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);

create index if not exists trust_report_access_logs_owner_idx
on public.trust_report_access_logs (owner_user_id, created_at desc);

create index if not exists trust_report_access_logs_viewer_idx
on public.trust_report_access_logs (viewer_user_id, created_at desc);


create or replace function public.has_active_trust_report_share(
  p_owner_user_id uuid,
  p_viewer_user_id uuid,
  p_scope text default null
)
returns boolean
language plpgsql
stable
set search_path to 'public'
as $function$
begin
  if p_owner_user_id is null or p_viewer_user_id is null then
    return false;
  end if;

  if p_owner_user_id = p_viewer_user_id then
    return true;
  end if;

  return exists (
    select 1
    from public.trust_report_shares s
    where s.owner_user_id = p_owner_user_id
      and s.viewer_user_id = p_viewer_user_id
      and s.revoked_at is null
      and (s.expires_at is null or s.expires_at > now())
      and (
        p_scope is null
        or s.scope = p_scope
        or s.scope = 'full_report'
      )
  );
end;
$function$;


create or replace function public.create_trust_report_share(
  p_owner_user_id uuid,
  p_viewer_user_id uuid,
  p_scope text default 'summary',
  p_expires_at timestamptz default null,
  p_reason text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_share_id uuid;
  v_latest_snapshot_id uuid;
begin
  if p_owner_user_id is null or p_viewer_user_id is null then
    raise exception 'Missing owner or viewer user id';
  end if;

  if p_owner_user_id = p_viewer_user_id then
    raise exception 'Cannot create Trust Report share with self';
  end if;

  select id
  into v_latest_snapshot_id
  from public.trust_score_snapshots
  where user_id = p_owner_user_id
  order by created_at desc
  limit 1;

  insert into public.trust_report_shares (
    owner_user_id,
    viewer_user_id,
    trust_score_snapshot_id,
    scope,
    expires_at,
    reason,
    metadata
  )
  values (
    p_owner_user_id,
    p_viewer_user_id,
    v_latest_snapshot_id,
    coalesce(p_scope, 'summary'),
    p_expires_at,
    p_reason,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_share_id;

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
    'share_created',
    coalesce(p_scope, 'summary'),
    jsonb_build_object('reason', p_reason)
  );

  return v_share_id;
end;
$function$;


create or replace function public.revoke_trust_report_share(
  p_share_id uuid
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_share public.trust_report_shares%rowtype;
begin
  if p_share_id is null then
    raise exception 'Missing share id';
  end if;

  select *
  into v_share
  from public.trust_report_shares
  where id = p_share_id;

  if not found then
    return false;
  end if;

  update public.trust_report_shares
  set
    revoked_at = now(),
    updated_at = now()
  where id = p_share_id
    and revoked_at is null;

  insert into public.trust_report_access_logs (
    owner_user_id,
    viewer_user_id,
    trust_report_share_id,
    access_type,
    scope,
    metadata
  )
  values (
    v_share.owner_user_id,
    v_share.viewer_user_id,
    v_share.id,
    'share_revoked',
    v_share.scope,
    '{}'::jsonb
  );

  return true;
end;
$function$;


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
    tr.active_score_ceiling_total,
    tr.active_risk_flag_count,
    tr.private_risk_summary,
    tr.sylienn_private_note,
    tr.latest_snapshot_at
  from public.trust_report_shadow_v tr
  where tr.user_id = p_owner_user_id;
end;
$function$;