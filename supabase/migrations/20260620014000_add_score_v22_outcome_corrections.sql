begin;

-- ============================================================================
-- Score v2.2 append-only payment outcome corrections
--
-- Corrections are new immutable outcome rows that supersede the currently
-- effective payment outcome. Original outcomes and contributions remain in the
-- audit ledger, while public/effective scoring follows the leaf of the
-- supersession chain.
-- ============================================================================

alter table public.trust_outcome_events
  add column if not exists supersedes_outcome_event_id uuid,
  add column if not exists correction_key text,
  add column if not exists correction_reason text;

do $constraints$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.trust_outcome_events'::regclass
      and conname = 'trust_outcome_events_supersedes_fkey'
  ) then
    alter table public.trust_outcome_events
      add constraint trust_outcome_events_supersedes_fkey
      foreign key (supersedes_outcome_event_id)
      references public.trust_outcome_events(id)
      on delete restrict;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.trust_outcome_events'::regclass
      and conname = 'trust_outcome_events_correction_fields_check'
  ) then
    alter table public.trust_outcome_events
      add constraint trust_outcome_events_correction_fields_check
      check (
        (
          supersedes_outcome_event_id is null
          and correction_key is null
          and correction_reason is null
        )
        or
        (
          supersedes_outcome_event_id is not null
          and nullif(btrim(correction_key), '') is not null
          and nullif(btrim(correction_reason), '') is not null
        )
      );
  end if;
end
$constraints$;

create unique index if not exists
  trust_outcome_events_one_successor_uidx
on public.trust_outcome_events (supersedes_outcome_event_id)
where supersedes_outcome_event_id is not null;

create unique index if not exists
  trust_outcome_events_correction_key_uidx
on public.trust_outcome_events (correction_key)
where correction_key is not null;

create index if not exists
  trust_outcome_events_supersedes_idx
on public.trust_outcome_events (supersedes_outcome_event_id, created_at);

-- Root payment outcomes remain unique per payment. Correction rows are allowed
-- to carry the same payment_id because they are linked through supersession.
drop index if exists
  public.trust_outcome_events_payment_per_agreement_unique;

create unique index
  trust_outcome_events_payment_per_agreement_unique
on public.trust_outcome_events (
  score_agreement_id,
  ((metadata ->> 'payment_id'))
)
where outcome_type in (
    'payment_paid_early',
    'payment_paid_on_time',
    'payment_paid_late'
  )
  and metadata ? 'payment_id'
  and supersedes_outcome_event_id is null;

-- Early bonus history may contain multiple immutable rows across correction
-- chains. Only the effective source outcome counts. Completion remains unique.
drop index if exists
  public.score_v2_contributions_v22_single_reward_uidx;

create unique index if not exists
  score_v2_contributions_v22_completion_uidx
on public.score_v2_contributions (
  score_agreement_id,
  contribution_type,
  model_version
)
where model_version = 'v2.2-shadow'
  and contribution_type = 'agreement_completion';

create or replace function public.score_v22_validate_outcome_supersession()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_previous public.trust_outcome_events%rowtype;
  v_previous_payment_id uuid;
  v_new_payment_id uuid;
begin
  if new.supersedes_outcome_event_id is null then
    return new;
  end if;

  select *
  into v_previous
  from public.trust_outcome_events
  where id = new.supersedes_outcome_event_id
  for key share;

  if not found then
    raise exception
      'Superseded trust outcome event not found: %',
      new.supersedes_outcome_event_id
      using errcode = '23503';
  end if;

  if v_previous.outcome_type not in (
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late'
    )
     or new.outcome_type not in (
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late'
    ) then
    raise exception
      'Score v2.2 corrections may only supersede canonical payment outcomes'
      using errcode = '23514';
  end if;

  if new.user_id is distinct from v_previous.user_id
     or new.score_agreement_id is distinct from v_previous.score_agreement_id
     or new.source_type is distinct from v_previous.source_type
     or new.source_id is distinct from v_previous.source_id then
    raise exception
      'A corrected outcome must preserve user, agreement, and source identity'
      using errcode = '23514';
  end if;

  v_previous_payment_id :=
    public.score_v22_event_payment_id(to_jsonb(v_previous));
  v_new_payment_id :=
    public.score_v22_event_payment_id(to_jsonb(new));

  if v_previous_payment_id is null
     or v_new_payment_id is distinct from v_previous_payment_id then
    raise exception
      'A corrected outcome must preserve the original payment_id'
      using errcode = '23514';
  end if;

  if new.outcome_at is distinct from v_previous.outcome_at then
    raise exception
      'A corrected outcome must preserve the original financial occurrence time'
      using errcode = '23514';
  end if;

  if new.amount_cents is distinct from v_previous.amount_cents then
    raise exception
      'A corrected outcome must preserve the original payment amount'
      using errcode = '23514';
  end if;

  if new.created_at < v_previous.created_at then
    raise exception
      'A correction cannot be recorded before the event it supersedes'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.trust_outcome_events as child
    where child.supersedes_outcome_event_id = v_previous.id
  ) then
    raise exception
      'Trust outcome event % has already been superseded',
      v_previous.id
      using errcode = '23505';
  end if;

  if new.outcome_type = 'payment_paid_early' then
    if coalesce(new.days_early, 0) <= 0
       or coalesce(new.days_late, 0) <> 0 then
      raise exception
        'An early correction requires positive days_early and zero days_late'
        using errcode = '23514';
    end if;
  elsif new.outcome_type = 'payment_paid_on_time' then
    if coalesce(new.days_early, 0) <> 0
       or coalesce(new.days_late, 0) <> 0 then
      raise exception
        'An on-time correction requires zero days_early and zero days_late'
        using errcode = '23514';
    end if;
  elsif new.outcome_type = 'payment_paid_late' then
    if coalesce(new.days_late, 0) <= 0
       or coalesce(new.days_early, 0) <> 0 then
      raise exception
        'A late correction requires positive days_late and zero days_early'
        using errcode = '23514';
    end if;
  end if;

  if new.outcome_type = v_previous.outcome_type
     and coalesce(new.days_early, 0) = coalesce(v_previous.days_early, 0)
     and coalesce(new.days_late, 0) = coalesce(v_previous.days_late, 0) then
    raise exception
      'A correction must change the effective payment outcome'
      using errcode = '23514';
  end if;

  return new;
end
$function$;

drop trigger if exists
  trg_score_v22_validate_outcome_supersession
on public.trust_outcome_events;

create trigger trg_score_v22_validate_outcome_supersession
before insert on public.trust_outcome_events
for each row
execute function public.score_v22_validate_outcome_supersession();

create or replace function public.score_v22_block_payment_outcome_mutation()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if old.score_agreement_id is not null
     and old.outcome_type in (
       'payment_paid_early',
       'payment_paid_on_time',
       'payment_paid_late'
     ) then
    if session_user = 'postgres'
       and current_setting(
         'iou.allow_trust_outcome_maintenance',
         true
       ) = 'on' then
      return case when tg_op = 'DELETE' then old else new end;
    end if;

    raise exception
      'Payment trust outcomes are append-only. Record a correction event instead of mutating history.';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end
$function$;

drop trigger if exists
  trg_score_v22_block_payment_outcome_mutation
on public.trust_outcome_events;

create trigger trg_score_v22_block_payment_outcome_mutation
before update or delete on public.trust_outcome_events
for each row
execute function public.score_v22_block_payment_outcome_mutation();

create or replace function public.score_v22_effective_outcome_events(
  p_score_agreement_id uuid,
  p_as_of timestamptz default now()
)
returns setof public.trust_outcome_events
language sql
stable
security definer
set search_path = ''
as $function$
  select e.*
  from public.trust_outcome_events as e
  where public.score_v22_event_score_agreement_id(to_jsonb(e))
        = p_score_agreement_id
    and e.created_at <= p_as_of
    and not exists (
      select 1
      from public.trust_outcome_events as child
      where child.supersedes_outcome_event_id = e.id
        and child.created_at <= p_as_of
    );
$function$;

revoke all
  on function public.score_v22_effective_outcome_events(uuid, timestamptz)
  from public, anon, authenticated;

grant execute
  on function public.score_v22_effective_outcome_events(uuid, timestamptz)
  to service_role, postgres;



CREATE OR REPLACE FUNCTION public.score_v22_recalculate_agreement(p_score_agreement_id uuid, p_as_of timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_context jsonb;
  v_subject_user_id uuid;
  v_principal_cents bigint;
  v_pair_index integer;
  v_ceiling integer;
  v_early_pool integer;
  v_base_reward integer;

  v_event record;
  v_event_json jsonb;
  v_event_type text;
  v_event_at timestamptz;
  v_payment_id uuid;
  v_payment_json jsonb;
  v_installment_cents bigint;
  v_days_late integer;
  v_penalty_points integer;

  v_completion_event_id uuid;
  v_completion_at timestamptz;
  v_completion_event_type text;
  v_qualifying_early_event_id uuid;
  v_qualifying_early_at timestamptz;
  v_qualifying_early_event_type text;

  v_inserted_penalties integer := 0;
  v_inserted_completion integer := 0;
  v_inserted_early integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('score-v2.2:' || p_score_agreement_id::text, 0)
  );

  v_context := public.score_v22_agreement_context(p_score_agreement_id);

  IF NOT public.score_v22_is_personal_iou_domain(
    public.score_v22_context_domain(v_context)
  ) THEN
    RETURN jsonb_build_object(
      'score_agreement_id', p_score_agreement_id,
      'model_version', 'v2.2-shadow',
      'skipped', true,
      'reason', 'non_personal_iou_domain',
      'domain', public.score_v22_context_domain(v_context)
    );
  END IF;

  v_subject_user_id := public.score_v22_context_borrower_id(v_context);
  v_principal_cents := public.score_v22_context_principal_cents(v_context);
  v_pair_index := public.score_v22_same_pair_index(p_score_agreement_id);
  v_ceiling := public.score_v22_ceiling_for_pair_index(
    v_principal_cents,
    v_pair_index
  );
  v_early_pool := round(v_ceiling * 0.20)::integer;
  v_base_reward := v_ceiling - v_early_pool;

  IF v_subject_user_id IS NULL THEN
    RAISE EXCEPTION
      'Cannot recalculate score agreement % without borrower/subject user',
      p_score_agreement_id;
  END IF;

  IF v_principal_cents <= 0 THEN
    RAISE EXCEPTION
      'Cannot recalculate score agreement % without positive principal cents',
      p_score_agreement_id;
  END IF;

  FOR v_event IN
    SELECT e.id, to_jsonb(e) AS event_json
    FROM public.score_v22_effective_outcome_events(
      p_score_agreement_id,
      p_as_of
    ) AS e
    WHERE public.score_v22_event_at(to_jsonb(e)) <= p_as_of
    ORDER BY public.score_v22_event_at(to_jsonb(e)), e.id
  LOOP
    v_event_json := v_event.event_json;
    v_event_type := public.score_v22_event_type(v_event_json);
    v_event_at := public.score_v22_event_at(v_event_json);

    IF v_event_at = 'epoch'::timestamptz THEN
      RAISE EXCEPTION
        'Score v2.2 cannot process outcome event % without a valid evidence timestamp',
        v_event.id;
    END IF;

    IF v_event_type IN (
      'agreement_completed',
      'iou_completed',
      'loan_completed',
      'agreement_completion'
    ) THEN
      IF v_completion_at IS NULL THEN
        v_completion_event_id := v_event.id;
        v_completion_at := v_event_at;
        v_completion_event_type := v_event_type;
      END IF;

    ELSIF v_event_type IN (
      'payment_paid_early',
      'payment_early'
    ) THEN
      IF v_qualifying_early_at IS NULL THEN
        v_qualifying_early_event_id := v_event.id;
        v_qualifying_early_at := v_event_at;
        v_qualifying_early_event_type := v_event_type;
      END IF;

    ELSIF v_event_type IN (
      'payment_paid_late',
      'payment_late'
    ) THEN
      v_payment_id := public.score_v22_event_payment_id(v_event_json);
      v_payment_json := public.score_v22_payment_json(v_payment_id);
      v_installment_cents := public.score_v22_payment_amount_cents(
        v_payment_json,
        v_event_json
      );
      v_days_late := public.score_v22_days_late(
        v_payment_json,
        v_event_json
      );

      IF v_installment_cents <= 0 THEN
        RAISE EXCEPTION
          'Late outcome event % has no positive installment amount',
          v_event.id;
      END IF;

      IF v_days_late <= 0 THEN
        RAISE EXCEPTION
          'Late outcome event % has no positive days-late evidence',
          v_event.id;
      END IF;

      v_penalty_points := public.score_v22_late_penalty_points(
        v_ceiling,
        v_principal_cents,
        v_installment_cents,
        v_days_late
      );

      IF v_penalty_points > 0 AND public.score_v22_insert_contribution(
        p_score_agreement_id,
        v_event.id,
        v_subject_user_id,
        'payment_late_penalty',
        'penalty',
        v_penalty_points,
        v_event_at,
        v_ceiling,
        v_pair_index,
        jsonb_build_object(
          'model_version', 'v2.2-shadow',
          'rule', 'agreement_ceiling_x_installment_share_x_lateness_severity',
          'agreement_ceiling', v_ceiling,
          'principal_cents', v_principal_cents,
          'installment_cents', v_installment_cents,
          'installment_share',
            round(v_installment_cents::numeric / v_principal_cents::numeric, 8),
          'days_late', v_days_late,
          'severity_rate', public.score_v22_late_penalty_rate(v_days_late),
          'points', v_penalty_points,
          'payment_id', v_payment_id,
          'outcome_event_id', v_event.id
        ),
        v_event_type,
        GREATEST(
          round(
            v_ceiling::numeric
            * LEAST(
                v_installment_cents::numeric
                / v_principal_cents::numeric,
                1.00::numeric
              )
          )::integer,
          1
        )
      ) THEN
        v_inserted_penalties := v_inserted_penalties + 1;
      END IF;
    END IF;
  END LOOP;

  IF v_completion_event_id IS NOT NULL THEN
    IF public.score_v22_insert_contribution(
      p_score_agreement_id,
      v_completion_event_id,
      v_subject_user_id,
      'agreement_completion',
      'reward',
      v_base_reward,
      v_completion_at,
      v_ceiling,
      v_pair_index,
      jsonb_build_object(
        'model_version', 'v2.2-shadow',
        'rule', 'completion_unlocks_base_reward',
        'agreement_ceiling', v_ceiling,
        'base_completion_reward', v_base_reward,
        'early_bonus_pool', v_early_pool,
        'pair_index', v_pair_index,
        'principal_cents', v_principal_cents,
        'outcome_event_id', v_completion_event_id
      ),
      v_completion_event_type,
      v_base_reward
    ) THEN
      v_inserted_completion := 1;
    END IF;

    -- The bonus is linked to the qualifying early event, not the completion
    -- event. Therefore the bonus expires exactly two years after its own
    -- evidence timestamp.
    IF v_qualifying_early_event_id IS NOT NULL
       AND v_qualifying_early_at <= v_completion_at
       AND v_early_pool > 0
       AND public.score_v22_insert_contribution(
         p_score_agreement_id,
         v_qualifying_early_event_id,
         v_subject_user_id,
         'early_payment_bonus',
         'reward',
         v_early_pool,
         v_qualifying_early_at,
         v_ceiling,
         v_pair_index,
         jsonb_build_object(
           'model_version', 'v2.2-shadow',
           'rule', 'any_qualifying_early_installment_earns_capped_bonus_unlocked_at_completion',
           'agreement_ceiling', v_ceiling,
           'early_bonus_pool', v_early_pool,
           'qualifying_early_outcome_event_id', v_qualifying_early_event_id,
           'qualifying_early_outcome_at', v_qualifying_early_at,
           'completion_outcome_event_id', v_completion_event_id,
           'completion_outcome_at', v_completion_at
         ),
         v_qualifying_early_event_type,
         v_early_pool
       ) THEN
      v_inserted_early := 1;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'score_agreement_id', p_score_agreement_id,
    'model_version', 'v2.2-shadow',
    'pair_index', v_pair_index,
    'agreement_ceiling', v_ceiling,
    'base_completion_reward', v_base_reward,
    'early_bonus_pool', v_early_pool,
    'completion_event_id', v_completion_event_id,
    'qualifying_early_event_id', v_qualifying_early_event_id,
    'inserted_penalties', v_inserted_penalties,
    'inserted_completion', v_inserted_completion,
    'inserted_early_bonus', v_inserted_early
  );
END
$function$
;

CREATE OR REPLACE FUNCTION public.score_v22_pending_agreement_progress(p_score_agreement_id uuid, p_as_of timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_context jsonb;
  v_principal_cents bigint;
  v_pair_index integer;
  v_ceiling integer;
  v_early_pool integer;
  v_base_reward integer;
  v_paid_cents bigint := 0;
  v_paid_installment_count integer := 0;
  v_pending_completion integer := 0;
  v_early_earned integer := 0;
  v_active_penalties integer := 0;
  v_completion_at timestamptz;
  v_completed_active boolean := false;
  v_cutoff timestamptz := p_as_of - interval '2 years';
begin
  v_context := public.score_v22_agreement_context(p_score_agreement_id);
  v_principal_cents := public.score_v22_context_principal_cents(v_context);
  v_pair_index := public.score_v22_same_pair_index(p_score_agreement_id);
  v_ceiling := public.score_v22_ceiling_for_pair_index(
    v_principal_cents,
    v_pair_index
  );
  v_early_pool := round(v_ceiling * 0.20)::integer;
  v_base_reward := v_ceiling - v_early_pool;

  -- Repayment progress is financial truth, so it is derived from immutable
  -- payment outcomes rather than a mutable payment status string.
  --
  -- DISTINCT ON(payment key) prevents duplicate outcomes for the same payment
  -- from double-counting principal. The latest event wins only for selecting
  -- one immutable record; the amount comes from the payment row when available,
  -- with immutable event metadata as the fallback.
  with paid_outcomes as (
    select distinct on (
      coalesce(
        public.score_v22_event_payment_id(to_jsonb(e)),
        e.id
      )
    )
      coalesce(
        public.score_v22_event_payment_id(to_jsonb(e)),
        e.id
      ) as payment_key,
      public.score_v22_event_payment_id(to_jsonb(e)) as payment_id,
      to_jsonb(e) as event_json,
      public.score_v22_event_at(to_jsonb(e)) as outcome_at
    from public.score_v22_effective_outcome_events(
      p_score_agreement_id,
      p_as_of
    ) as e
    where public.score_v22_event_type(to_jsonb(e)) in (
        'payment_paid_early',
        'payment_early',
        'payment_paid_on_time',
        'payment_on_time',
        'payment_paid_late',
        'payment_late'
      )
      and public.score_v22_event_at(to_jsonb(e)) <= p_as_of
    order by
      coalesce(
        public.score_v22_event_payment_id(to_jsonb(e)),
        e.id
      ),
      public.score_v22_event_at(to_jsonb(e)) desc,
      e.id desc
  ),
  paid_amounts as (
    select
      payment_key,
      public.score_v22_payment_amount_cents(
        public.score_v22_payment_json(payment_id),
        event_json
      ) as amount_cents
    from paid_outcomes
  )
  select
    coalesce(sum(amount_cents), 0)::bigint,
    count(*) filter (where amount_cents > 0)::integer
  into
    v_paid_cents,
    v_paid_installment_count
  from paid_amounts;

  if v_principal_cents > 0 then
    v_pending_completion := round(
      v_base_reward::numeric
      * least(
          v_paid_cents::numeric / v_principal_cents::numeric,
          1.00::numeric
        )
    )::integer;
  end if;

  select max(public.score_v22_event_at(to_jsonb(e)))
  into v_completion_at
  from public.score_v22_effective_outcome_events(
    p_score_agreement_id,
    p_as_of
  ) as e
  where public.score_v22_event_type(to_jsonb(e)) in (
      'agreement_completed',
      'iou_completed',
      'loan_completed',
      'agreement_completion'
    )
    and public.score_v22_event_at(to_jsonb(e)) <= p_as_of;

  v_completed_active :=
    v_completion_at is not null
    and v_completion_at > v_cutoff;

  if exists (
    select 1
    from public.score_v22_effective_outcome_events(
      p_score_agreement_id,
      p_as_of
    ) as e
    where public.score_v22_event_type(to_jsonb(e)) in (
        'payment_paid_early',
        'payment_early'
      )
      and public.score_v22_event_at(to_jsonb(e)) > v_cutoff
      and public.score_v22_event_at(to_jsonb(e)) <= p_as_of
  ) then
    v_early_earned := v_early_pool;
  end if;

  select coalesce(sum(c.points_awarded), 0)::integer
  into v_active_penalties
  from public.score_v2_contributions as c
  join public.score_v22_effective_outcome_events(
    p_score_agreement_id,
    p_as_of
  ) as e
    on e.id = c.outcome_event_id
  where c.score_agreement_id = p_score_agreement_id
    and c.model_version = 'v2.2-shadow'
    and c.impact_direction = 'penalty'
    and public.score_v22_event_at(to_jsonb(e)) > v_cutoff
    and public.score_v22_event_at(to_jsonb(e)) <= p_as_of;

  return jsonb_build_object(
    'score_agreement_id', p_score_agreement_id,
    'model_version', 'v2.2-shadow',
    'pair_index', v_pair_index,
    'agreement_ceiling', v_ceiling,
    'principal_cents', v_principal_cents,
    'paid_cents', least(v_paid_cents, v_principal_cents),
    'paid_installment_count', v_paid_installment_count,
    'repayment_fraction',
      case
        when v_principal_cents > 0
        then round(
          least(
            v_paid_cents::numeric / v_principal_cents::numeric,
            1.00::numeric
          ),
          8
        )
        else 0
      end,
    'completion_progress_points', v_pending_completion,
    'completion_reward_max', v_base_reward,
    'early_bonus_earned', v_early_earned,
    'early_bonus_max', v_early_pool,
    'active_penalties', v_active_penalties,
    'gross_points_earned', v_pending_completion + v_early_earned,
    'projected_net_contribution',
      v_pending_completion + v_early_earned - v_active_penalties,
    'current_public_score_effect',
      (
        case
          when v_completed_active
          then v_base_reward + v_early_earned
          else 0
        end
      ) - v_active_penalties,
    'agreement_completed', v_completion_at is not null,
    'positive_points_unlocked', v_completed_active,
    'positive_points_unlock_condition',
      case
        when v_completed_active
        then 'unlocked'
        else 'Positive points unlock when the IOU is completed'
      end,
    'completion_outcome_at', v_completion_at,
    'evidence_cutoff', v_cutoff,
    'as_of', p_as_of
  );
end
$function$
;

CREATE OR REPLACE FUNCTION public.score_v2_effective_contributions_internal(
  p_user_id uuid,
  p_model_version text,
  p_at timestamptz
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT COALESCE(SUM(
    CASE
      WHEN sc.impact_direction = 'penalty' THEN -sc.points_awarded
      ELSE sc.points_awarded
    END
  ), 0)::integer
  FROM public.score_v2_contributions AS sc
  JOIN public.trust_outcome_events AS toe
    ON toe.id = sc.outcome_event_id
  WHERE sc.user_id = p_user_id
    AND sc.model_key = 'iou_score'
    AND sc.model_version = p_model_version
    AND toe.outcome_at > p_at - interval '2 years'
    AND (
      p_model_version <> 'v2.2-shadow'
      OR (
        toe.created_at <= p_at
        AND sc.calculated_at <= p_at
        AND NOT EXISTS (
          SELECT 1
          FROM public.trust_outcome_events AS child
          WHERE child.supersedes_outcome_event_id = toe.id
            AND child.created_at <= p_at
        )
      )
    );
$function$
;


create or replace view public.score_v22_effective_contributions as
select
  c.id,
  c.user_id,
  c.outcome_event_id,
  c.score_agreement_id,
  c.contribution_type,
  c.source_outcome_type,
  c.model_key,
  c.model_version,
  c.points_awarded,
  c.points_cap,
  c.calculated_at,
  c.metadata,
  c.impact_direction,
  c.calculation_details,
  c.source_outcome_at,
  c.agreement_ceiling,
  c.pair_index,
  case
    when c.impact_direction = 'penalty'
      then -c.points_awarded
    else c.points_awarded
  end as signed_points
from public.score_v2_contributions as c
join public.trust_outcome_events as e
  on e.id = c.outcome_event_id
where c.model_version = 'v2.2-shadow'
  and e.created_at <= now()
  and public.score_v22_event_at(to_jsonb(e))
      > now() - interval '2 years'
  and not exists (
    select 1
    from public.trust_outcome_events as child
    where child.supersedes_outcome_event_id = e.id
      and child.created_at <= now()
  );

CREATE OR REPLACE FUNCTION public.score_v22_dispatch_outcome_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_event jsonb := to_jsonb(NEW);
  v_type text;
  v_score_agreement_id uuid;
  v_recalculate_as_of timestamptz;
BEGIN
  v_type := public.score_v22_event_type(v_event);

  IF v_type NOT IN (
    'payment_paid_early',
    'payment_early',
    'payment_paid_on_time',
    'payment_on_time',
    'payment_paid_late',
    'payment_late',
    'agreement_completed',
    'iou_completed',
    'loan_completed',
    'agreement_completion'
  ) THEN
    RETURN NEW;
  END IF;

  v_score_agreement_id :=
    public.score_v22_event_score_agreement_id(v_event);

  IF v_score_agreement_id IS NULL THEN
    RAISE EXCEPTION
      'Score v2.2 could not resolve score agreement for outcome event %',
      NEW.id;
  END IF;

  v_recalculate_as_of := public.score_v22_event_at(v_event);

  if NEW.supersedes_outcome_event_id is not null then
    v_recalculate_as_of :=
      greatest(v_recalculate_as_of, NEW.created_at);
  end if;

  PERFORM public.score_v22_recalculate_agreement(
    v_score_agreement_id,
    v_recalculate_as_of
  );

  RETURN NEW;
END
$function$
;

create or replace function public.record_score_v22_payment_outcome_correction(
  p_superseded_outcome_event_id uuid,
  p_corrected_outcome_type text,
  p_correction_reason text,
  p_idempotency_key text,
  p_days_early integer default null,
  p_days_late integer default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_caller_role text;
  v_previous public.trust_outcome_events%rowtype;
  v_existing public.trust_outcome_events%rowtype;
  v_corrected_type text;
  v_payment_id uuid;
  v_new_event_id uuid;
  v_request_metadata jsonb := coalesce(p_metadata, '{}'::jsonb);
begin
  v_caller_role := coalesce(
    current_setting('request.jwt.claim.role', true),
    (
      nullif(
        current_setting('request.jwt.claims', true),
        ''
      )::jsonb ->> 'role'
    ),
    ''
  );

  if v_caller_role in ('anon', 'authenticated') then
    raise exception 'Service-role or postgres required'
      using errcode = '42501';
  elsif v_caller_role <> 'service_role'
        and session_user <> 'postgres' then
    raise exception 'Service-role or postgres required'
      using errcode = '42501';
  end if;

  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'Correction idempotency key is required';
  end if;

  if length(p_idempotency_key) > 200 then
    raise exception 'Correction idempotency key is too long';
  end if;

  if nullif(btrim(p_correction_reason), '') is null then
    raise exception 'Correction reason is required';
  end if;

  v_corrected_type := lower(btrim(p_corrected_outcome_type));

  if v_corrected_type not in (
    'payment_paid_early',
    'payment_paid_on_time',
    'payment_paid_late'
  ) then
    raise exception
      'Unsupported corrected payment outcome type: %',
      p_corrected_outcome_type;
  end if;

  select *
  into v_existing
  from public.trust_outcome_events
  where correction_key = p_idempotency_key;

  if found then
    if v_existing.supersedes_outcome_event_id
         is distinct from p_superseded_outcome_event_id
       or v_existing.outcome_type is distinct from v_corrected_type
       or v_existing.correction_reason
         is distinct from p_correction_reason
       or coalesce(v_existing.days_early, 0)
         <> coalesce(p_days_early, 0)
       or coalesce(v_existing.days_late, 0)
         <> coalesce(p_days_late, 0)
       or coalesce(
            v_existing.metadata
              -> 'correction'
              -> 'request_metadata',
            '{}'::jsonb
          ) is distinct from v_request_metadata then
      raise exception
        'Correction idempotency key conflicts with an existing request'
        using errcode = '23505';
    end if;

    return jsonb_build_object(
      'ok', true,
      'replayed', true,
      'correction_outcome_event_id', v_existing.id,
      'superseded_outcome_event_id',
        v_existing.supersedes_outcome_event_id,
      'corrected_outcome_type', v_existing.outcome_type
    );
  end if;

  select *
  into v_previous
  from public.trust_outcome_events
  where id = p_superseded_outcome_event_id
  for update;

  if not found then
    raise exception
      'Payment outcome event not found: %',
      p_superseded_outcome_event_id;
  end if;

  if exists (
    select 1
    from public.trust_outcome_events as child
    where child.supersedes_outcome_event_id = v_previous.id
  ) then
    raise exception
      'Payment outcome event % is no longer the effective event',
      v_previous.id
      using errcode = '23505';
  end if;

  v_payment_id :=
    public.score_v22_event_payment_id(to_jsonb(v_previous));

  if v_payment_id is null then
    raise exception
      'Payment outcome event % has no payment_id',
      v_previous.id;
  end if;

  insert into public.trust_outcome_events (
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    outcome_at,
    amount_cents,
    days_early,
    days_late,
    proof_tier,
    verification_tier,
    related_snapshot_id,
    metadata,
    supersedes_outcome_event_id,
    correction_key,
    correction_reason
  )
  values (
    v_previous.user_id,
    v_previous.score_agreement_id,
    v_previous.source_type,
    v_previous.source_id,
    v_corrected_type,
    v_previous.outcome_at,
    v_previous.amount_cents,
    p_days_early,
    p_days_late,
    v_previous.proof_tier,
    v_previous.verification_tier,
    v_previous.related_snapshot_id,
    coalesce(v_previous.metadata, '{}'::jsonb)
      || v_request_metadata
      || jsonb_build_object(
           'payment_id', v_payment_id,
           'correction', jsonb_build_object(
             'superseded_outcome_event_id', v_previous.id,
             'previous_outcome_type', v_previous.outcome_type,
             'corrected_outcome_type', v_corrected_type,
             'reason', p_correction_reason,
             'idempotency_key', p_idempotency_key,
             'recorded_at', now(),
             'request_metadata', v_request_metadata
           )
         ),
    v_previous.id,
    p_idempotency_key,
    p_correction_reason
  )
  returning id into v_new_event_id;

  return jsonb_build_object(
    'ok', true,
    'replayed', false,
    'correction_outcome_event_id', v_new_event_id,
    'superseded_outcome_event_id', v_previous.id,
    'corrected_outcome_type', v_corrected_type
  );
end
$function$;

revoke all
  on function public.record_score_v22_payment_outcome_correction(
    uuid,
    text,
    text,
    text,
    integer,
    integer,
    jsonb
  )
  from public, anon, authenticated, service_role;

grant execute
  on function public.record_score_v22_payment_outcome_correction(
    uuid,
    text,
    text,
    text,
    integer,
    integer,
    jsonb
  )
  to service_role, postgres;

comment on function public.record_score_v22_payment_outcome_correction(
  uuid,
  text,
  text,
  text,
  integer,
  integer,
  jsonb
)
is
  'Internal append-only Score v2.2 payment outcome correction writer. Creates a canonical replacement outcome that supersedes the current effective event. Restricted to service_role and postgres.';

-- --------------------------------------------------------------------------
-- Fail-closed invariants.
-- --------------------------------------------------------------------------
do $invariants$
declare
  v_count integer;
begin
  select count(*)
  into v_count
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'trust_outcome_events'
    and column_name in (
      'supersedes_outcome_event_id',
      'correction_key',
      'correction_reason'
    );

  if v_count <> 3 then
    raise exception
      'Score v2.2 correction columns are incomplete';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'record_score_v22_payment_outcome_correction'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'App roles must not execute the Score v2.2 correction writer';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'record_score_v22_payment_outcome_correction'
    and grantee in ('postgres', 'service_role')
    and privilege_type = 'EXECUTE';

  if v_count <> 2 then
    raise exception
      'Correction writer must be executable by postgres and service_role';
  end if;

  if exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname =
        'score_v2_contributions_v22_single_reward_uidx'
  ) then
    raise exception
      'Legacy single-reward index blocks append-only early-bonus corrections';
  end if;

  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname =
        'score_v2_contributions_v22_completion_uidx'
  ) then
    raise exception
      'Completion uniqueness index is missing';
  end if;
end
$invariants$;

commit;
