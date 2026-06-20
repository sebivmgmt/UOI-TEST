begin;
-- ---------------------------------------------------------------------------
-- Migration 2: Score v2 Shadow Engine
-- ---------------------------------------------------------------------------
-- A. Create score_v2_contributions append-only ledger.
-- B. Immutability trigger on the ledger.
-- C. RLS + grants for the ledger.
-- D. Add v2 shadow fields to trust_score_snapshots.
-- E. Register v2.0-shadow model version.
-- F. Create private agreement recalculation function.
-- G. Create controlled callable wrappers (service_role / postgres only).
-- H. AFTER INSERT trigger on trust_outcome_events for automatic shadow calc.
-- I. DB-level idempotency indexes on trust_outcome_events.
-- J. Replace create_trust_score_snapshot with correct v2 snapshot logic.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- A. Append-only contribution ledger
-- ---------------------------------------------------------------------------
create table if not exists public.score_v2_contributions (
  id                  uuid        primary key default gen_random_uuid(),
  user_id             uuid        not null references public.profiles(id),
  outcome_event_id    uuid        not null references public.trust_outcome_events(id),
  score_agreement_id  uuid        not null references public.score_agreements(id),
  contribution_type   text        not null,
  source_outcome_type text        not null,
  model_key           text        not null default 'iou_score',
  model_version       text        not null,
  points_awarded      integer     not null,
  points_cap          integer     not null,
  calculated_at       timestamptz not null default now(),
  metadata            jsonb       not null default '{}',

  constraint score_v2_contributions_type_check
    check (contribution_type in ('payment_performance', 'agreement_completion')),
  constraint score_v2_contributions_points_awarded_check
    check (points_awarded >= 0),
  constraint score_v2_contributions_points_cap_check
    check (points_cap >= 0),
  constraint score_v2_contributions_points_ceiling_check
    check (points_awarded <= points_cap)
);

-- DB-level idempotency: one contribution per outcome event per type per model
create unique index if not exists score_v2_contributions_event_type_version_unique
  on public.score_v2_contributions (outcome_event_id, contribution_type, model_version);

-- Critical: one contribution per agreement component per model version.
-- Multiple early/on-time payments must not refill the payment-performance slot.
create unique index if not exists score_v2_contributions_agreement_type_version_unique
  on public.score_v2_contributions (score_agreement_id, contribution_type, model_version);

-- Lookup indexes
create index if not exists score_v2_contributions_agreement_idx
  on public.score_v2_contributions (score_agreement_id);

create index if not exists score_v2_contributions_user_calculated_idx
  on public.score_v2_contributions (user_id, calculated_at desc);

create index if not exists score_v2_contributions_model_idx
  on public.score_v2_contributions (model_key, model_version);

-- ---------------------------------------------------------------------------
-- B. Immutability trigger — rejects UPDATE and DELETE on the ledger.
--    A changed algorithm must use a new model_version, not rewrite history.
-- ---------------------------------------------------------------------------
create or replace function public.score_v2_contributions_immutable()
returns trigger
language plpgsql
as $function$
begin
  raise exception
    'score_v2_contributions rows are immutable. Use a new model_version for algorithm changes.'
    using errcode = '55000';
end;
$function$;

create trigger trg_score_v2_contributions_immutable
  before update or delete on public.score_v2_contributions
  for each row execute function public.score_v2_contributions_immutable();

revoke all
  on function public.score_v2_contributions_immutable()
  from public, anon, authenticated, service_role;

grant execute
  on function public.score_v2_contributions_immutable()
  to postgres;

-- ---------------------------------------------------------------------------
-- C. RLS + grants for score_v2_contributions
-- ---------------------------------------------------------------------------
alter table public.score_v2_contributions enable row level security;

-- Authenticated: SELECT own rows only. No INSERT/UPDATE/DELETE policy.
grant select on table public.score_v2_contributions to authenticated;

create policy "Users can view own score contributions"
  on public.score_v2_contributions
  for select to authenticated
  using (user_id = auth.uid());

-- service_role and postgres: full access (bypass RLS)
grant all on table public.score_v2_contributions to service_role, postgres;

-- anon: no access
revoke all on table public.score_v2_contributions from anon;

-- ---------------------------------------------------------------------------
-- D. Add explicit Score v2 shadow fields to trust_score_snapshots.
--    public_score remains the legacy Score v1 field. Do not repurpose it.
-- ---------------------------------------------------------------------------
alter table public.trust_score_snapshots
  add column if not exists v2_shadow_score         integer not null default 700,
  add column if not exists v2_shadow_visible_trust  integer not null default 700,
  add column if not exists v2_shadow_trust_tier     text    not null default 'verified_user';

-- ---------------------------------------------------------------------------
-- E. Register the first frozen shadow model version.
--    ON CONFLICT DO NOTHING: safe to re-run; does not overwrite existing row.
-- ---------------------------------------------------------------------------
insert into public.trust_model_versions (
  model_key,
  version,
  status,
  description,
  config,
  activated_at
)
values (
  'iou_score',
  'v2.0-shadow',
  'shadow',
  'First calibration shadow model for Score v2 trust scoring.',
  jsonb_build_object(
    'base_score', 700,
    'personal_iou', jsonb_build_object(
      'payment_performance_share',       0.20,
      'early_fraction',                  1.00,
      'on_time_fraction',                1.00,
      'late_fraction',                   0.00,
      'completion_uses_remaining_ceiling', true
    ),
    'negative_outcomes_enabled', false,
    'shadow_mode', true
  ),
  now()
)
on conflict (model_key, version) do nothing;

-- ---------------------------------------------------------------------------
-- F. Private agreement recalculation — postgres only.
--    Processes personal_iou agreements against a specific model version.
--    Uses ON CONFLICT DO NOTHING for full idempotency.
-- ---------------------------------------------------------------------------
create or replace function public.score_v2_recalculate_agreement_internal(
  p_score_agreement_id uuid,
  p_model_version      text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_agreement     public.score_agreements%rowtype;
  v_model         public.trust_model_versions%rowtype;
  v_config        jsonb;
  v_ceiling       integer;
  v_pp_cap        integer;
  v_comp_cap      integer;
  v_pp_event      public.trust_outcome_events%rowtype;
  v_comp_event    public.trust_outcome_events%rowtype;
  v_pp_found      boolean := false;
  v_comp_found    boolean := false;
  v_pp_points     integer := 0;
  v_comp_points   integer := 0;
  v_sum           integer := 0;
  v_capped_total  integer := 0;
begin
  -- 1. Lock the score agreement
  select * into v_agreement
  from public.score_agreements
  where id = p_score_agreement_id
  for update;

  if not found then
    raise exception 'Score agreement not found: %', p_score_agreement_id;
  end if;

  -- 3. Only personal_iou in this first engine version
  if v_agreement.source_type <> 'personal_iou' then
    return jsonb_build_object(
      'ok',         false,
      'reason',     'source_type not supported by this engine version',
      'source_type', v_agreement.source_type
    );
  end if;

  -- 2. Load the exact requested model version
  select * into v_model
  from public.trust_model_versions
  where model_key = 'iou_score'
    and version = p_model_version;

  if not found then
    raise exception 'Model version not found: iou_score/%', p_model_version;
  end if;

  v_config  := v_model.config;
  v_ceiling := v_agreement.score_ceiling;

  -- payment_performance_cap = min(ceiling, max(1, floor(ceiling × share)))
  -- When ceiling = 0, cap is 0.
  if v_ceiling = 0 then
    v_pp_cap := 0;
  else
    v_pp_cap := least(
      v_ceiling,
      greatest(
        1,
        floor(
          v_ceiling
          * (v_config -> 'personal_iou' ->> 'payment_performance_share')::numeric
        )::integer
      )
    );
  end if;

  v_comp_cap := v_ceiling - v_pp_cap;

  -- 4. Earliest payment outcome for this agreement
  select * into v_pp_event
  from public.trust_outcome_events
  where score_agreement_id = p_score_agreement_id
    and outcome_type in (
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late'
    )
  order by outcome_at asc
  limit 1;
  v_pp_found := FOUND;

  -- 5. Insert exactly one payment_performance contribution
  if v_pp_found then
    v_pp_points :=
      case
        when v_pp_event.outcome_type in ('payment_paid_early', 'payment_paid_on_time')
          then v_pp_cap
        else 0  -- late: forfeits the component
      end;

    -- 8. ON CONFLICT DO NOTHING — idempotent across both unique constraints
    insert into public.score_v2_contributions (
      user_id,
      outcome_event_id,
      score_agreement_id,
      contribution_type,
      source_outcome_type,
      model_key,
      model_version,
      points_awarded,
      points_cap,
      metadata
    ) values (
      v_agreement.user_id,
      v_pp_event.id,
      p_score_agreement_id,
      'payment_performance',
      v_pp_event.outcome_type,
      v_model.model_key,
      p_model_version,
      v_pp_points,
      v_pp_cap,
      jsonb_build_object('ceiling_at_calculation', v_ceiling)
    )
    on conflict do nothing;
  end if;

  -- 6. Earliest agreement_completed event for this agreement
  select * into v_comp_event
  from public.trust_outcome_events
  where score_agreement_id = p_score_agreement_id
    and outcome_type = 'agreement_completed'
  order by outcome_at asc
  limit 1;
  v_comp_found := FOUND;

  -- 7. Insert exactly one agreement_completion contribution
  if v_comp_found then
    v_comp_points := v_comp_cap;

    insert into public.score_v2_contributions (
      user_id,
      outcome_event_id,
      score_agreement_id,
      contribution_type,
      source_outcome_type,
      model_key,
      model_version,
      points_awarded,
      points_cap,
      metadata
    ) values (
      v_agreement.user_id,
      v_comp_event.id,
      p_score_agreement_id,
      'agreement_completion',
      v_comp_event.outcome_type,
      v_model.model_key,
      p_model_version,
      v_comp_points,
      v_comp_cap,
      jsonb_build_object('ceiling_at_calculation', v_ceiling)
    )
    on conflict do nothing;
  end if;

  -- 9. Sum all contributions for this agreement + model version
  select coalesce(sum(points_awarded), 0)
  into v_sum
  from public.score_v2_contributions
  where score_agreement_id = p_score_agreement_id
    and model_version = p_model_version;

  -- 10. Cap at score_ceiling
  v_capped_total := least(v_ceiling, v_sum);

  -- 11. Update score_agreements summary
  update public.score_agreements
  set
    score_contributed = v_capped_total,
    metadata = metadata || jsonb_build_object(
      'score_contributed_model_version',  p_model_version,
      'score_contributed_calculated_at',  now()
    )
  where id = p_score_agreement_id;

  -- 12. Return structured result
  return jsonb_build_object(
    'ok',                        true,
    'score_agreement_id',        p_score_agreement_id,
    'model_version',             p_model_version,
    'source_type',               v_agreement.source_type,
    'score_ceiling',             v_ceiling,
    'payment_performance_cap',   v_pp_cap,
    'completion_cap',            v_comp_cap,
    'payment_performance_points', v_pp_points,
    'completion_points',         v_comp_points,
    'total_contributed',         v_capped_total,
    'payment_event_type',
      case when v_pp_found then v_pp_event.outcome_type else null end,
    'completion_event_found',    v_comp_found
  );
end;
$function$;

revoke all
  on function public.score_v2_recalculate_agreement_internal(uuid, text)
  from public, anon, authenticated, service_role;

grant execute
  on function public.score_v2_recalculate_agreement_internal(uuid, text)
  to postgres;

-- ---------------------------------------------------------------------------
-- G. Controlled callable wrappers — service_role and postgres only.
-- ---------------------------------------------------------------------------

-- Agreement-level wrapper
create or replace function public.recalculate_score_v2_agreement(
  p_score_agreement_id uuid,
  p_model_version      text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller_role text;
begin
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  if v_caller_role <> 'service_role' and session_user <> 'postgres' then
    raise exception 'Service-role or postgres required'
      using errcode = '42501';
  end if;

  return public.score_v2_recalculate_agreement_internal(
    p_score_agreement_id,
    p_model_version
  );
end;
$function$;

revoke all
  on function public.recalculate_score_v2_agreement(uuid, text)
  from public, anon, authenticated;

grant execute
  on function public.recalculate_score_v2_agreement(uuid, text)
  to service_role, postgres;

-- User-level wrapper: loops through personal_iou agreements for a user
create or replace function public.recalculate_score_v2_user(
  p_user_id       uuid,
  p_model_version text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller_role text;
  v_agr_id      uuid;
  v_result      jsonb;
  v_results     jsonb := '[]'::jsonb;
begin
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  if v_caller_role <> 'service_role' and session_user <> 'postgres' then
    raise exception 'Service-role or postgres required'
      using errcode = '42501';
  end if;

  for v_agr_id in
    select id
    from public.score_agreements
    where user_id = p_user_id
      and source_type = 'personal_iou'
    order by created_at
  loop
    v_result := public.score_v2_recalculate_agreement_internal(v_agr_id, p_model_version);
    v_results := v_results || jsonb_build_array(v_result);
  end loop;

  return jsonb_build_object(
    'ok',                   true,
    'user_id',              p_user_id,
    'model_version',        p_model_version,
    'agreements_processed', jsonb_array_length(v_results),
    'results',              v_results
  );
end;
$function$;

revoke all
  on function public.recalculate_score_v2_user(uuid, text)
  from public, anon, authenticated;

grant execute
  on function public.recalculate_score_v2_user(uuid, text)
  to service_role, postgres;

-- ---------------------------------------------------------------------------
-- H. AFTER INSERT trigger on trust_outcome_events.
--    Automatically processes shadow contributions as verified outcomes arrive.
--    Errors are swallowed with a WARNING — outcome evidence is never lost.
-- ---------------------------------------------------------------------------
create or replace function public.trg_score_v2_shadow_on_outcome()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_shadow_version text;
begin
  -- 1. Resolve the current iou_score shadow model
  select version into v_shadow_version
  from public.trust_model_versions
  where model_key = 'iou_score'
    and status = 'shadow'
  order by activated_at desc nulls last
  limit 1;

  -- No shadow model registered yet — skip silently
  if v_shadow_version is null then
    return new;
  end if;

  -- 2. Only process events that belong to a score agreement
  if new.score_agreement_id is null then
    return new;
  end if;

  -- 3 + 4. Recalculate; catch all errors so the INSERT always succeeds
  begin
    perform public.score_v2_recalculate_agreement_internal(
      new.score_agreement_id,
      v_shadow_version
    );
  exception
    when others then
      raise warning
        'Score v2 shadow calculation failed for outcome event %: %',
        new.id, sqlerrm;
  end;

  return new;
end;
$function$;

create trigger trg_score_v2_shadow_on_outcome
  after insert on public.trust_outcome_events
  for each row execute function public.trg_score_v2_shadow_on_outcome();

revoke all
  on function public.trg_score_v2_shadow_on_outcome()
  from public, anon, authenticated, service_role;

grant execute
  on function public.trg_score_v2_shadow_on_outcome()
  to postgres;

-- ---------------------------------------------------------------------------
-- I. DB-level idempotency indexes on trust_outcome_events.
--    Preflight: abort migration if duplicates already exist.
-- ---------------------------------------------------------------------------
do $$
declare
  v_dup_payment    integer;
  v_dup_completion integer;
begin
  select count(*) into v_dup_payment from (
    select score_agreement_id, metadata ->> 'payment_id'
    from public.trust_outcome_events
    where outcome_type in (
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late'
    )
      and metadata ? 'payment_id'
    group by score_agreement_id, metadata ->> 'payment_id'
    having count(*) > 1
  ) dups;

  if v_dup_payment > 0 then
    raise exception
      'Preflight failed: % duplicate payment outcome(s) per agreement+payment_id detected. Resolve before applying this migration.',
      v_dup_payment;
  end if;

  select count(*) into v_dup_completion from (
    select score_agreement_id
    from public.trust_outcome_events
    where outcome_type = 'agreement_completed'
    group by score_agreement_id
    having count(*) > 1
  ) dups;

  if v_dup_completion > 0 then
    raise exception
      'Preflight failed: % agreement(s) with duplicate agreement_completed events detected. Resolve before applying this migration.',
      v_dup_completion;
  end if;
end;
$$;

-- One successful payment outcome per (agreement, payment_id in metadata)
create unique index if not exists trust_outcome_events_payment_per_agreement_unique
  on public.trust_outcome_events (score_agreement_id, (metadata ->> 'payment_id'))
  where outcome_type in (
    'payment_paid_early',
    'payment_paid_on_time',
    'payment_paid_late'
  )
  and metadata ? 'payment_id';

-- One agreement_completed event per agreement
create unique index if not exists trust_outcome_events_completion_per_agreement_unique
  on public.trust_outcome_events (score_agreement_id, outcome_type)
  where outcome_type = 'agreement_completed';

-- ---------------------------------------------------------------------------
-- J. Replace create_trust_score_snapshot with correct Score v2 logic.
--    Auth checks from Migration 1 are preserved verbatim.
--    All existing proof-depth, confidence, freshness, risk, exposure, and
--    legacy calculations are preserved verbatim.
--    Additions:
--      - Resolve shadow model version from trust_model_versions.
--      - Aggregate Score v2 contributions from the ledger for that model.
--      - Compute v2_shadow_score, v2_shadow_visible_trust, v2_shadow_trust_tier.
--      - Set score_contributed_total from the ledger, not stale summary fields.
--      - Set model_version to the resolved shadow model version.
--      - Emit clearly labelled summary fields.
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
  v_profile     public.profiles%rowtype;
  v_snapshot_id uuid;

  -- Legacy Score v1 fields
  v_score               integer;
  v_exposure            integer;
  v_freshness           integer := 100;
  v_visible_trust       integer;
  v_proof_depth         integer := 0;
  v_confidence          integer := 0;
  v_tier                text;

  v_total_agreements        integer := 0;
  v_active_agreements       integer := 0;
  v_total_ceiling           integer := 0;
  v_total_contributed       integer := 0;  -- from score_agreements (kept for proof-depth calc)
  v_risk_flags              integer := 0;

  -- Score v2 shadow fields
  v_shadow_model_version    text;
  v_shadow_base_score       integer := 700;
  v2_contribution_total     integer := 0;
  v2_shadow_score           integer;
  v2_shadow_visible_trust   integer;
  v2_shadow_trust_tier      text;
  v_days_on_platform        integer;
begin
  -- ── Authorization (from Migration 1, preserved verbatim) ──────────────────
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    ''
  );

  if v_caller_role = 'anon' then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;

  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'You may only create a snapshot for your own account'
      using errcode = '42501';
  end if;

  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  -- ── Profile + legacy aggregates (existing logic, verbatim) ────────────────
  select * into v_profile
  from public.profiles
  where id = p_user_id;

  if not found then
    raise exception 'Profile not found for user %', p_user_id;
  end if;

  v_score    := greatest(300, coalesce(v_profile.iou_score, 700));
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

  -- Proof depth, confidence, visible trust, tier (existing formulas, verbatim)
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

  v_days_on_platform := greatest(
    0,
    floor(extract(epoch from (now() - coalesce(v_profile.created_at, now()))) / 86400)::integer
  );

  v_tier := public.score_v2_trust_tier(
    v_score,
    v_days_on_platform,
    v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  -- ── Score v2 shadow calculations (new) ────────────────────────────────────

  -- 1. Resolve the current shadow model version
  select
    version,
    greatest(700, coalesce((config ->> 'base_score')::integer, 700))
  into v_shadow_model_version, v_shadow_base_score
  from public.trust_model_versions
  where model_key = 'iou_score'
    and status = 'shadow'
  order by activated_at desc nulls last
  limit 1;

  v_shadow_base_score := coalesce(v_shadow_base_score, 700);

  -- 2. Aggregate Score v2 contributions from the ledger
  --    If no shadow model is found v_shadow_model_version is NULL;
  --    the WHERE becomes false and COALESCE returns 0.
  select coalesce(sum(c.points_awarded), 0)
  into v2_contribution_total
  from public.score_v2_contributions c
  where c.user_id     = p_user_id
    and c.model_key   = 'iou_score'
    and c.model_version = v_shadow_model_version;

  -- 3. v2_shadow_score = clamp(base + contributions, 300, 1400)
  v2_shadow_score := greatest(300, least(1400,
    v_shadow_base_score + v2_contribution_total
  ));

  -- 4. v2_shadow_visible_trust
  v2_shadow_visible_trust := public.score_v2_visible_trust(
    v2_shadow_score,
    v_exposure,
    v_freshness
  );

  -- 5. v2_shadow_trust_tier uses Score v2 shadow score
  v2_shadow_trust_tier := public.score_v2_trust_tier(
    v2_shadow_score,
    v_days_on_platform,
    v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  -- ── Insert snapshot ────────────────────────────────────────────────────────
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
    v2_shadow_score,
    v2_shadow_visible_trust,
    v2_shadow_trust_tier,
    summary
  )
  values (
    p_user_id,
    'iou_score',
    -- 6. Use the resolved shadow model version; fall back to 'v2.0-shadow'
    coalesce(v_shadow_model_version, 'v2.0-shadow'),
    -- Legacy Score v1 score
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
    -- 7. score_contributed_total from the ledger, not stale summary fields
    v2_contribution_total,
    v_risk_flags,
    coalesce(v_profile.strike_count, 0),
    coalesce(p_snapshot_reason, 'manual_snapshot'),
    v2_shadow_score,
    v2_shadow_visible_trust,
    v2_shadow_trust_tier,
    -- 8. Clearly labelled summary
    jsonb_build_object(
      'shadow_mode',          true,
      'legacy_public_score',  v_score,
      'v2_shadow_score',      v2_shadow_score,
      'v2_contribution_total', v2_contribution_total
    )
  )
  returning id into v_snapshot_id;

  return v_snapshot_id;
end;
$function$;

-- Grant permissions (same as Migration 1; CREATE OR REPLACE resets nothing,
-- but we re-state grants for clarity and idempotency)
revoke execute
  on function public.create_trust_score_snapshot(uuid, text)
  from public, anon;

grant execute
  on function public.create_trust_score_snapshot(uuid, text)
  to authenticated, service_role, postgres;

commit;
