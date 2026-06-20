-- IOU Score v2 — Relationship Modes
-- Adds relationship-level scoring behavior.
-- No profile score changes.
-- No score event changes.
-- No trigger switch.

create table if not exists public.user_relationship_modes (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null references public.profiles(id) on delete cascade,
  related_user_id uuid not null references public.profiles(id) on delete cascade,

  relationship_mode text not null default 'standard_score_affecting' check (
    relationship_mode in (
      'standard_score_affecting',
      'family_no_score',
      'close_circle_no_score',
      'private_record_only',
      'self_no_score',
      'business_score_affecting',
      'landlord_tenant_score_affecting'
    )
  ),

  label text null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  metadata jsonb not null default '{}'::jsonb,

  constraint user_relationship_modes_no_duplicate
    unique (user_id, related_user_id),

  constraint user_relationship_modes_no_null_pair
    check (user_id is not null and related_user_id is not null)
);

create index if not exists user_relationship_modes_user_idx
on public.user_relationship_modes (user_id);

create index if not exists user_relationship_modes_related_user_idx
on public.user_relationship_modes (related_user_id);

create index if not exists user_relationship_modes_mode_idx
on public.user_relationship_modes (relationship_mode);


create or replace function public.get_relationship_mode(
  p_user_id uuid,
  p_related_user_id uuid
)
returns text
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_mode text;
begin
  if p_user_id is null or p_related_user_id is null then
    return 'standard_score_affecting';
  end if;

  if p_user_id = p_related_user_id then
    return 'self_no_score';
  end if;

  select relationship_mode
  into v_mode
  from public.user_relationship_modes
  where user_id = p_user_id
    and related_user_id = p_related_user_id
  limit 1;

  if v_mode is not null then
    return v_mode;
  end if;

  -- Check reverse direction too.
  -- Family / close-circle should work even if one person created the relationship mode.
  select relationship_mode
  into v_mode
  from public.user_relationship_modes
  where user_id = p_related_user_id
    and related_user_id = p_user_id
  limit 1;

  return coalesce(v_mode, 'standard_score_affecting');
end;
$function$;


create or replace function public.score_v2_relationship_affects_score(
  p_user_id uuid,
  p_related_user_id uuid
)
returns boolean
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_mode text;
begin
  v_mode := public.get_relationship_mode(p_user_id, p_related_user_id);

  return v_mode in (
    'standard_score_affecting',
    'business_score_affecting',
    'landlord_tenant_score_affecting'
  );
end;
$function$;