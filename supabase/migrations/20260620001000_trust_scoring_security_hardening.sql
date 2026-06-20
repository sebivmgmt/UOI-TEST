begin;
-- ---------------------------------------------------------------------------
-- Migration 1: Trust Scoring Security Hardening
-- ---------------------------------------------------------------------------
-- A. Remove direct mutation privileges from public / anon / authenticated.
-- B. Enable RLS on tables that currently lack it; add own-row SELECT policies.
-- C. Lock down apply_score_event_once to service_role + postgres only.
-- D. Harden create_trust_score_snapshot: own-user enforcement, anon reject.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- A-1. Revoke ALL from anon on every score / trust table.
--      Revoke mutation from authenticated; leave SELECT for tables that get
--      explicit RLS policies below.
-- ---------------------------------------------------------------------------
revoke all
  on table public.score_agreements
  from anon;

revoke all
  on table public.score_events
  from anon;

revoke all
  on table public.trust_outcome_events
  from anon;

revoke all
  on table public.trust_score_snapshots
  from anon;

revoke all
  on table public.trust_model_versions
  from anon;

revoke insert, update, delete, truncate
  on table public.score_agreements
  from authenticated;

-- score_agreements: internal only — remove authenticated SELECT too
revoke select
  on table public.score_agreements
  from authenticated;

revoke insert, update, delete, truncate
  on table public.score_events
  from authenticated;

revoke insert, update, delete, truncate
  on table public.trust_outcome_events
  from authenticated;

revoke insert, update, delete, truncate
  on table public.trust_score_snapshots
  from authenticated;

revoke insert, update, delete, truncate
  on table public.trust_model_versions
  from authenticated;

-- Remove global public execute on apply_score_event_once proactively
-- (full revoke handled in section C; this removes the implicit public grant)
revoke execute
  on function public.apply_score_event_once(uuid, text, integer, text, uuid, uuid, text)
  from public;

-- ---------------------------------------------------------------------------
-- A-2. Enable RLS on tables that currently have it disabled.
--      score_agreements already has RLS ON; the rest do not.
-- ---------------------------------------------------------------------------
alter table public.score_events          enable row level security;
alter table public.trust_outcome_events  enable row level security;
alter table public.trust_score_snapshots enable row level security;
alter table public.trust_model_versions  enable row level security;

-- ---------------------------------------------------------------------------
-- B. Own-row SELECT policies for authenticated users.
--    score_agreements: no authenticated policy — internal only.
--    trust_model_versions: read-all policy (no user_id column).
-- ---------------------------------------------------------------------------
create policy "Users can view own score events"
  on public.score_events
  for select to authenticated
  using (user_id = auth.uid());

create policy "Users can view own outcome events"
  on public.trust_outcome_events
  for select to authenticated
  using (user_id = auth.uid());

create policy "Users can view own trust snapshots"
  on public.trust_score_snapshots
  for select to authenticated
  using (user_id = auth.uid());

create policy "Authenticated users can read model versions"
  on public.trust_model_versions
  for select to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- C. Protect apply_score_event_once.
--    Revoke from public/anon/authenticated; grant only to service_role and
--    postgres.  Body is unchanged.
-- ---------------------------------------------------------------------------
revoke execute
  on function public.apply_score_event_once(uuid, text, integer, text, uuid, uuid, text)
  from anon, authenticated;

grant execute
  on function public.apply_score_event_once(uuid, text, integer, text, uuid, uuid, text)
  to service_role, postgres;

-- ---------------------------------------------------------------------------
-- D. Harden create_trust_score_snapshot.
--    Authorization additions only; all existing calculations are verbatim.
--    - Rejects anon callers.
--    - Authenticated callers may only snapshot their own auth.uid().
--    - service_role and postgres may snapshot any user_id.
-- ---------------------------------------------------------------------------
create or replace function public.create_trust_score_snapshot(
  p_user_id uuid,
  p_snapshot_reason text default 'manual_snapshot'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller_role text;
  v_profile public.profiles%rowtype;
  v_snapshot_id uuid;

  v_score integer;
  v_exposure integer;
  v_freshness integer := 100;
  v_visible_trust integer;
  v_proof_depth integer := 0;
  v_confidence integer := 0;
  v_tier text;

  v_total_agreements integer := 0;
  v_active_agreements integer := 0;
  v_total_ceiling integer := 0;
  v_total_contributed integer := 0;
  v_risk_flags integer := 0;
begin
  -- ── Authorization ──────────────────────────────────────────────────────────
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  -- Reject anonymous callers
  if v_caller_role = 'anon' then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;

  -- Authenticated users may only snapshot their own account
  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'You may only create a snapshot for your own account'
      using errcode = '42501';
  end if;
  -- service_role and postgres: auth.uid() is null → unrestricted

  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  -- ── Existing calculations (verbatim) ───────────────────────────────────────
  select *
  into v_profile
  from public.profiles
  where id = p_user_id;

  if not found then
    raise exception 'Profile not found for user %', p_user_id;
  end if;

  v_score := greatest(300, coalesce(v_profile.iou_score, 700));
  v_exposure := greatest(0, coalesce(v_profile.active_exposure_points, 0));

  select
    count(*),
    count(*) filter (where status in ('active', 'completed')),
    coalesce(sum(score_ceiling), 0),
    coalesce(sum(score_contributed), 0)
  into
    v_total_agreements,
    v_active_agreements,
    v_total_ceiling,
    v_total_contributed
  from public.score_agreements
  where user_id = p_user_id;

  select count(*)
  into v_risk_flags
  from public.score_risk_flags
  where user_id = p_user_id
    and is_active = true;

  v_proof_depth := least(
    100,
    greatest(
      0,
      (v_active_agreements * 10)
      + least(40, floor(v_total_ceiling / 25)::integer)
    )
  );

  v_confidence := least(
    100,
    greatest(
      0,
      round((v_proof_depth * 0.70) + (v_freshness * 0.30))::integer
    )
  );

  v_visible_trust := public.score_v2_visible_trust(v_score, v_exposure, v_freshness);

  v_tier := public.score_v2_trust_tier(
    v_score,
    greatest(0, floor(extract(epoch from (now() - coalesce(v_profile.created_at, now()))) / 86400)::integer),
    v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  insert into public.trust_score_snapshots (
    user_id,
    model_key,
    model_version,
    public_score,
    visible_trust,
    active_exposure_points,
    trust_tier,
    proof_depth,
    proof_depth_label,
    confidence_score,
    confidence_label,
    freshness_score,
    trend_30d,
    score_agreement_count,
    active_score_agreement_count,
    score_ceiling_total,
    score_contributed_total,
    risk_flag_count,
    active_strike_count,
    snapshot_reason,
    summary
  )
  values (
    p_user_id,
    'iou_score',
    'v2.0-shadow',
    v_score,
    v_visible_trust,
    v_exposure,
    v_tier,
    v_proof_depth,
    public.score_v2_proof_depth_label(v_proof_depth),
    v_confidence,
    public.score_v2_confidence_label(v_confidence),
    v_freshness,
    'stable',
    v_total_agreements,
    v_active_agreements,
    v_total_ceiling,
    v_total_contributed,
    v_risk_flags,
    coalesce(v_profile.strike_count, 0),
    coalesce(p_snapshot_reason, 'manual_snapshot'),
    jsonb_build_object(
      'shadow_mode', true,
      'raw_score_decay', false,
      'note', 'Snapshot generated for Score v2 trust intelligence learning loop.'
    )
  )
  returning id into v_snapshot_id;

  return v_snapshot_id;
end;
$function$;

-- Revoke from public and anon at the grant level (body also guards, belt+suspenders)
revoke execute
  on function public.create_trust_score_snapshot(uuid, text)
  from public, anon;

grant execute
  on function public.create_trust_score_snapshot(uuid, text)
  to authenticated, service_role, postgres;

commit;
