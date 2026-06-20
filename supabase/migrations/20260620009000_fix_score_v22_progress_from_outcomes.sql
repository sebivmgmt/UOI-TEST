begin;

-- ============================================================================
-- Fix: Score v2.2 pending repayment progress must derive paid installments
-- from immutable outcome evidence, not mutable payment status text.
--
-- Why:
--   The ACH payment row for the approved DEV fixture has a valid immutable
--   payment_paid_late outcome and a resolvable $250 amount, but does not expose
--   paid_at/settled_at/completed_at or status='paid' in the shape assumed by
--   the original progress query.
--
-- Doctrine:
--   * Financial repayment progress uses all immutable paid installment outcomes.
--   * Score-active rewards/penalties still use the strict two-year boundary.
--   * Duplicate events for the same payment are counted once.
--   * No existing contribution row is updated or deleted.
-- ============================================================================

create or replace function public.score_v22_pending_agreement_progress(
  p_score_agreement_id uuid,
  p_as_of timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
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
    from public.trust_outcome_events as e
    where public.score_v22_event_score_agreement_id(to_jsonb(e))
          = p_score_agreement_id
      and public.score_v22_event_type(to_jsonb(e)) in (
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
  from public.trust_outcome_events as e
  where public.score_v22_event_score_agreement_id(to_jsonb(e))
        = p_score_agreement_id
    and public.score_v22_event_type(to_jsonb(e)) in (
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
    from public.trust_outcome_events as e
    where public.score_v22_event_score_agreement_id(to_jsonb(e))
          = p_score_agreement_id
      and public.score_v22_event_type(to_jsonb(e)) in (
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
  join public.trust_outcome_events as e
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
$function$;

revoke all
  on function public.score_v22_pending_agreement_progress(uuid, timestamptz)
  from public, anon, authenticated;

grant execute
  on function public.score_v22_pending_agreement_progress(uuid, timestamptz)
  to postgres, service_role;

comment on function public.score_v22_pending_agreement_progress(uuid, timestamptz)
is
  'Score v2.2 personal-IOU progress. Repayment progress derives from immutable paid outcome events; score-active evidence remains strictly newer than two years.';

commit;
