-- IOU Trust Education Acceptances
-- Product education acknowledgment ledger.
--
-- This is NOT legal acceptance.
-- This does NOT replace Terms of Service or Privacy Policy acceptance.
-- This does NOT change score logic.
-- This does NOT change profile scores.
-- This does NOT create a required gate yet.
--
-- Purpose:
-- Record when a user completes the IOU Trust education intro.

create table if not exists public.trust_education_acceptances (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null references public.profiles(id) on delete cascade,

  education_key text not null default 'iou_trust_intro',
  education_version text not null,

  context text not null default 'manual_review',
  platform text null,

  accepted_statements jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  completed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  unique (user_id, education_key, education_version, context)
);

create index if not exists trust_education_acceptances_user_idx
on public.trust_education_acceptances (user_id, completed_at desc);

create index if not exists trust_education_acceptances_key_version_idx
on public.trust_education_acceptances (education_key, education_version);


alter table public.trust_education_acceptances enable row level security;

drop policy if exists trust_education_acceptances_own_select
on public.trust_education_acceptances;

create policy trust_education_acceptances_own_select
on public.trust_education_acceptances
for select
to authenticated
using (user_id = auth.uid());


create or replace function public.record_trust_education_acceptance(
  p_user_id uuid,
  p_education_key text default 'iou_trust_intro',
  p_education_version text default '2026-05-30',
  p_context text default 'manual_review',
  p_platform text default null,
  p_accepted_statements jsonb default '[]'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_acceptance_id uuid;
  v_inserted boolean := false;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'Cannot record trust education acceptance for another user';
  end if;

  insert into public.trust_education_acceptances (
    user_id,
    education_key,
    education_version,
    context,
    platform,
    accepted_statements,
    metadata
  )
  values (
    p_user_id,
    coalesce(p_education_key, 'iou_trust_intro'),
    coalesce(p_education_version, '2026-05-30'),
    coalesce(p_context, 'manual_review'),
    p_platform,
    coalesce(p_accepted_statements, '[]'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (user_id, education_key, education_version, context)
  do update set
    platform = excluded.platform,
    accepted_statements = excluded.accepted_statements,
    metadata = public.trust_education_acceptances.metadata || excluded.metadata
  returning id into v_acceptance_id;

  return jsonb_build_object(
    'acceptance_id', v_acceptance_id,
    'education_key', coalesce(p_education_key, 'iou_trust_intro'),
    'education_version', coalesce(p_education_version, '2026-05-30'),
    'context', coalesce(p_context, 'manual_review'),
    'recorded', true
  );
end;
$function$;


create or replace function public.has_trust_education_acceptance(
  p_user_id uuid,
  p_education_key text default 'iou_trust_intro',
  p_education_version text default '2026-05-30',
  p_context text default null
)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if p_user_id is null then
    return false;
  end if;

  return exists (
    select 1
    from public.trust_education_acceptances tea
    where tea.user_id = p_user_id
      and tea.education_key = coalesce(p_education_key, 'iou_trust_intro')
      and tea.education_version = coalesce(p_education_version, '2026-05-30')
      and (
        p_context is null
        or tea.context = p_context
      )
  );
end;
$function$;


grant execute on function public.record_trust_education_acceptance(
  uuid,
  text,
  text,
  text,
  text,
  jsonb,
  jsonb
) to authenticated;

grant execute on function public.has_trust_education_acceptance(
  uuid,
  text,
  text,
  text
) to authenticated;