-- Massachusetts / Georgia / Florida Personal IOU jurisdiction policy.
--
-- Product policy for the November 2026 launch:
--   GA: 16.00% maximum APR
--   FL: 16.00% maximum APR
--   MA: 12.00% maximum APR
--
-- The borrower's residence state controls the agreement policy. The lender's
-- state never overrides the borrower-state rule.
--
-- This migration:
--   * creates one canonical database policy source;
--   * snapshots the applied state policy on every new IOU;
--   * fails closed for missing and unsupported borrower states, including 0% IOUs;
--   * enforces the snapshotted cap on direct inserts, borrower changes, and
--     actual APR changes, including schedule finalization and amendments;
--   * prevents clients from forging or changing state-policy snapshots;
--   * grandfathers pre-migration agreements while borrower and APR remain
--     unchanged, so payment/status lifecycle updates cannot be blocked;
--   * requires any actual borrower or APR amendment to a legacy agreement to
--     comply with the current borrower-state policy;
--   * leaves historical agreement terms untouched, including any legacy row
--     whose APR exceeded a later product cap;
--   * does not change legal documents or profiles.state write permissions.
--
-- profiles.state remains identity-submitted rather than independently verified.
-- Its controlled write/freeze path is a separate frontend/onboarding stage.

begin;


-- ── 1. Canonical Personal IOU state policy ──────────────────────────────────

create table if not exists public.iou_state_apr_policy (
  state_code text primary key,
  personal_iou_enabled boolean not null default false,
  max_apr_bps integer not null,
  policy_version text not null,
  effective_at timestamptz not null,
  notes text null,

  constraint iou_state_apr_policy_state_code_check
    check (
      state_code = upper(state_code)
      and state_code ~ '^[A-Z]{2}$'
    ),

  constraint iou_state_apr_policy_max_apr_check
    check (
      max_apr_bps >= 0
      and max_apr_bps <= 10000
    ),

  constraint iou_state_apr_policy_version_check
    check (btrim(policy_version) <> '')
);

comment on table public.iou_state_apr_policy is
  'Canonical state availability and maximum APR policy for Personal IOUs. Existing agreements retain immutable policy snapshots.';

comment on column public.iou_state_apr_policy.state_code is
  'Two-letter uppercase borrower residence state code.';

comment on column public.iou_state_apr_policy.personal_iou_enabled is
  'Whether new Personal IOUs may be created for borrowers in this state.';

comment on column public.iou_state_apr_policy.max_apr_bps is
  'Maximum product APR in basis points for new Personal IOUs in this state.';

comment on column public.iou_state_apr_policy.policy_version is
  'Version identifier snapshotted onto each new Personal IOU.';

insert into public.iou_state_apr_policy (
  state_code,
  personal_iou_enabled,
  max_apr_bps,
  policy_version,
  effective_at,
  notes
)
values
  (
    'GA',
    true,
    1600,
    '2026-06-29-v1',
    timestamptz '2026-06-29 00:00:00+00',
    'November 2026 launch product configuration.'
  ),
  (
    'FL',
    true,
    1600,
    '2026-06-29-v1',
    timestamptz '2026-06-29 00:00:00+00',
    'November 2026 launch product configuration.'
  ),
  (
    'MA',
    true,
    1200,
    '2026-06-29-v1',
    timestamptz '2026-06-29 00:00:00+00',
    'November 2026 launch product configuration.'
  )
on conflict (state_code)
do update set
  personal_iou_enabled = excluded.personal_iou_enabled,
  max_apr_bps = excluded.max_apr_bps,
  policy_version = excluded.policy_version,
  effective_at = excluded.effective_at,
  notes = excluded.notes;

alter table public.iou_state_apr_policy enable row level security;

drop policy if exists iou_state_apr_policy_authenticated_read
  on public.iou_state_apr_policy;

create policy iou_state_apr_policy_authenticated_read
  on public.iou_state_apr_policy
  for select
  to authenticated
  using (personal_iou_enabled = true);

revoke all
  on table public.iou_state_apr_policy
  from public, anon, authenticated;

grant select
  on table public.iou_state_apr_policy
  to authenticated;

grant all
  on table public.iou_state_apr_policy
  to service_role;


-- ── 2. Immutable policy snapshot on each IOU ────────────────────────────────
--
-- Existing rows remain NULL and are not backfilled. A pre-migration draft will
-- receive a snapshot when it is activated, its APR changes, or its borrower
-- changes before activation.

alter table public.ious
  add column if not exists borrower_state_code text null,
  add column if not exists borrower_max_apr_bps integer null,
  add column if not exists state_policy_version text null,
  add column if not exists state_policy_effective_at timestamptz null;

do $constraints$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.ious'::regclass
      and conname = 'ious_borrower_state_code_check'
  ) then
    alter table public.ious
      add constraint ious_borrower_state_code_check
      check (
        borrower_state_code is null
        or (
          borrower_state_code = upper(borrower_state_code)
          and borrower_state_code ~ '^[A-Z]{2}$'
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.ious'::regclass
      and conname = 'ious_borrower_max_apr_bps_check'
  ) then
    alter table public.ious
      add constraint ious_borrower_max_apr_bps_check
      check (
        borrower_max_apr_bps is null
        or (
          borrower_max_apr_bps >= 0
          and borrower_max_apr_bps <= 10000
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.ious'::regclass
      and conname = 'ious_state_policy_snapshot_completeness_check'
  ) then
    alter table public.ious
      add constraint ious_state_policy_snapshot_completeness_check
      check (
        (
          borrower_state_code is null
          and borrower_max_apr_bps is null
          and state_policy_version is null
          and state_policy_effective_at is null
        )
        or
        (
          borrower_state_code is not null
          and borrower_max_apr_bps is not null
          and state_policy_version is not null
          and state_policy_effective_at is not null
        )
      );
  end if;
end;
$constraints$;

comment on column public.ious.borrower_state_code is
  'Immutable borrower residence state applied to this agreement. System-managed from profiles.state.';

comment on column public.ious.borrower_max_apr_bps is
  'Immutable maximum APR applied to this agreement when its borrower-state policy was resolved.';

comment on column public.ious.state_policy_version is
  'Immutable state-policy version applied to this agreement.';

comment on column public.ious.state_policy_effective_at is
  'Effective timestamp of the state policy applied to this agreement.';


-- ── 3. Authoritative enforcement trigger ────────────────────────────────────

create or replace function public.enforce_iou_state_apr_policy()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_state_code text;
  v_enabled boolean;
  v_max_apr_bps integer;
  v_policy_version text;
  v_policy_effective_at timestamptz;
  v_apr_bps integer;
begin
  if new.borrower_id is null then
    raise exception using
      errcode = '22023',
      message = 'Personal IOU borrower is required.';
  end if;

  v_apr_bps := coalesce(new.apr_bps, 0);

  if v_apr_bps < 0 then
    raise exception using
      errcode = '22023',
      message = format(
        'APR %s bps is invalid. APR cannot be negative.',
        v_apr_bps
      );
  end if;

  if tg_op = 'UPDATE' then
    -- Snapshot fields are controlled only by this trigger. A legitimate
    -- pre-activation borrower change is allowed to replace the snapshot, but
    -- callers may not directly alter snapshot values for the same borrower.
    if new.borrower_id is not distinct from old.borrower_id
       and (
         new.borrower_state_code
           is distinct from old.borrower_state_code
         or new.borrower_max_apr_bps
           is distinct from old.borrower_max_apr_bps
         or new.state_policy_version
           is distinct from old.state_policy_version
         or new.state_policy_effective_at
           is distinct from old.state_policy_effective_at
       )
    then
      raise exception using
        errcode = '42501',
        message =
          'IOU state-policy snapshots are system-managed and immutable.';
    end if;

    if new.borrower_id is distinct from old.borrower_id
       and old.activated_at is not null
    then
      raise exception using
        errcode = '23514',
        message = 'Borrower cannot be changed after IOU activation.';
    end if;

    -- UPDATE OF triggers fire when a column is named in SET even when its
    -- value does not change. This early return preserves pre-migration rows
    -- during finalize_iou_schedule and other lifecycle operations that assign
    -- borrower_id/apr_bps back to their existing values.
    if new.borrower_id is not distinct from old.borrower_id
       and new.apr_bps is not distinct from old.apr_bps
    then
      new.borrower_state_code := old.borrower_state_code;
      new.borrower_max_apr_bps := old.borrower_max_apr_bps;
      new.state_policy_version := old.state_policy_version;
      new.state_policy_effective_at :=
        old.state_policy_effective_at;

      return new;
    end if;

    -- Agreements already carrying a complete snapshot retain that original
    -- governing policy for APR amendments. Later profile or policy-table
    -- changes do not rewrite an existing agreement's jurisdiction.
    if new.borrower_id is not distinct from old.borrower_id
       and old.borrower_state_code is not null
       and old.borrower_max_apr_bps is not null
       and old.state_policy_version is not null
       and old.state_policy_effective_at is not null
    then
      new.borrower_state_code := old.borrower_state_code;
      new.borrower_max_apr_bps := old.borrower_max_apr_bps;
      new.state_policy_version := old.state_policy_version;
      new.state_policy_effective_at :=
        old.state_policy_effective_at;

      if v_apr_bps > old.borrower_max_apr_bps then
        raise exception using
          errcode = '22023',
          message = format(
            'APR %s bps exceeds the %s bps cap for borrower state %s.',
            v_apr_bps,
            old.borrower_max_apr_bps,
            old.borrower_state_code
          );
      end if;

      return new;
    end if;
  end if;

  -- New IOUs, legitimate pre-activation borrower changes, and actual APR
  -- amendments to unsnapshotted legacy agreements resolve the current policy.
  select
    upper(nullif(btrim(profile.state), '')),
    policy.personal_iou_enabled,
    policy.max_apr_bps,
    policy.policy_version,
    policy.effective_at
  into
    v_state_code,
    v_enabled,
    v_max_apr_bps,
    v_policy_version,
    v_policy_effective_at
  from public.profiles as profile
  left join public.iou_state_apr_policy as policy
    on policy.state_code =
      upper(nullif(btrim(profile.state), ''))
  where profile.id = new.borrower_id;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'Borrower profile does not exist.';
  end if;

  if v_state_code is null then
    raise exception using
      errcode = '22023',
      message = 'Borrower residence state is not set.';
  end if;

  if v_enabled is distinct from true
     or v_max_apr_bps is null
     or v_policy_version is null
     or v_policy_effective_at is null
  then
    raise exception using
      errcode = '22023',
      message = format(
        'State %s is not supported for Personal IOUs.',
        v_state_code
      );
  end if;

  new.borrower_state_code := v_state_code;
  new.borrower_max_apr_bps := v_max_apr_bps;
  new.state_policy_version := v_policy_version;
  new.state_policy_effective_at := v_policy_effective_at;

  if v_apr_bps > v_max_apr_bps then
    raise exception using
      errcode = '22023',
      message = format(
        'APR %s bps exceeds the %s bps cap for borrower state %s.',
        v_apr_bps,
        v_max_apr_bps,
        v_state_code
      );
  end if;

  return new;
end;
$function$;

revoke execute
  on function public.enforce_iou_state_apr_policy()
  from public, anon, authenticated;

grant execute
  on function public.enforce_iou_state_apr_policy()
  to service_role;

drop trigger if exists ious_state_apr_policy_enforcement_trg
  on public.ious;

create trigger ious_state_apr_policy_enforcement_trg
  before insert
    or update of
      borrower_id,
      apr_bps,
      borrower_state_code,
      borrower_max_apr_bps,
      state_policy_version,
      state_policy_effective_at
  on public.ious
  for each row
  execute function public.enforce_iou_state_apr_policy();


commit;
