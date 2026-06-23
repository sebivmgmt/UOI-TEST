begin;

-- ============================================================================
-- Score v2.2 borrower-facing IOU scenario projection
--
-- Purpose:
--   Return a read-only estimate of how the authenticated borrower's current
--   Score v2.2 shadow score and Visible Trust would change under one supported
--   payment scenario for a personal IOU.
--
-- Security / integrity:
--   * No payment, outcome, contribution, score, exposure, or snapshot row is
--     inserted, updated, or deleted.
--   * The app-facing wrapper only exposes the authenticated borrower's own IOU.
--   * Internal score_agreements identifiers and raw evidence are not returned.
--   * The internal helper is service-role/postgres only.
--   * Projection arithmetic reuses the active v2.2 contribution engine,
--     late-penalty function, exposure formula, and visible-trust function.
-- ============================================================================

create or replace function public.score_v22_iou_scenario_projection_internal(
  p_iou_id uuid,
  p_subject_user_id uuid,
  p_scenario text,
  p_as_of timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_scenario text := lower(btrim(coalesce(p_scenario, '')));
  v_as_of timestamptz := coalesce(p_as_of, now());
  v_today date;

  v_iou public.ious%rowtype;
  v_profile public.profiles%rowtype;
  v_score_agreement_id uuid;
  v_progress jsonb;

  v_model_version text;
  v_base_score integer := 700;
  v_current_contribution_total integer := 0;
  v_current_score integer := 700;
  v_projected_score integer := 700;
  v_score_delta integer := 0;

  v_current_iou_effect integer := 0;
  v_projected_iou_effect integer := 0;
  v_iou_effect_delta integer := 0;

  v_current_iou_exposure integer := 0;
  v_projected_iou_exposure integer := 0;
  v_other_exposure integer := 0;
  v_current_exposure integer := 0;
  v_projected_exposure integer := 0;
  v_exposure_released integer := 0;
  v_base_exposure integer := 0;

  v_current_visible_trust integer := 700;
  v_projected_visible_trust integer := 700;
  v_visible_trust_delta integer := 0;

  v_principal_cents bigint := 0;
  v_paid_cents bigint := 0;
  v_scheduled_total_cents bigint := 0;
  v_current_remaining_cents bigint := 0;
  v_projected_remaining_cents bigint := 0;
  v_payment_amount_cents bigint;

  v_completion_reward_max integer := 0;
  v_early_bonus_max integer := 0;
  v_existing_early_bonus integer := 0;
  v_existing_penalty integer := 0;
  v_new_penalty integer := 0;
  v_projected_penalty integer := 0;
  v_projected_early_bonus integer := 0;
  v_completion_credit_unlocked integer := 0;
  v_early_bonus_unlocked integer := 0;

  v_completes_iou boolean := false;
  v_new_early_qualifier boolean := false;
  v_eligible boolean := false;
  v_ineligible_reason text;
  v_explanation jsonb := '[]'::jsonb;

  v_candidate_count integer := 0;
  v_next_payment_id uuid;
  v_next_due_date date;
  v_all_unpaid_count integer := 0;
  v_overdue_unpaid_count integer := 0;
begin
  if p_iou_id is null or p_subject_user_id is null then
    raise exception 'Missing required scenario projection input'
      using errcode = '22023';
  end if;

  if v_scenario not in (
    'pay_next_today',
    'payoff_today',
    'complete_on_schedule'
  ) then
    raise exception 'Unsupported score scenario'
      using errcode = '22023';
  end if;

  v_today := (v_as_of at time zone 'UTC')::date;

  select i.*
  into v_iou
  from public.ious as i
  where i.id = p_iou_id
    and i.borrower_id = p_subject_user_id;

  if not found then
    raise exception 'IOU score scenario not found or not accessible'
      using errcode = '42501';
  end if;

  select p.*
  into v_profile
  from public.profiles as p
  where p.id = p_subject_user_id;

  if not found then
    raise exception 'IOU score scenario not found or not accessible'
      using errcode = '42501';
  end if;

  begin
    select sa.id
    into strict v_score_agreement_id
    from public.score_agreements as sa
    where sa.source_type = 'personal_iou'
      and sa.source_id = p_iou_id
      and sa.user_id = p_subject_user_id;
  exception
    when no_data_found or too_many_rows then
      raise exception 'IOU score scenario not found or not accessible'
        using errcode = '42501';
  end;

  begin
    select
      tmv.version,
      greatest(700, coalesce((tmv.config ->> 'base_score')::integer, 700))
    into strict
      v_model_version,
      v_base_score
    from public.trust_model_versions as tmv
    where tmv.model_key = 'iou_score'
      and tmv.status = 'shadow'
    order by tmv.activated_at desc nulls last;
  exception
    when no_data_found then
      raise exception 'No shadow model registered for iou_score'
        using errcode = 'P0002';
    when too_many_rows then
      raise exception 'Multiple shadow models for iou_score; expected exactly one'
        using errcode = 'P0003';
  end;

  if v_model_version <> 'v2.2-shadow' then
    raise exception 'Score v2.2 shadow model is not active'
      using errcode = 'P0004';
  end if;

  v_progress := public.score_v22_pending_agreement_progress(
    v_score_agreement_id,
    v_as_of
  );

  v_principal_cents := greatest(
    coalesce((v_progress ->> 'principal_cents')::bigint, 0),
    0
  );
  v_paid_cents := greatest(
    coalesce((v_progress ->> 'paid_cents')::bigint, 0),
    0
  );
  v_completion_reward_max := greatest(
    coalesce((v_progress ->> 'completion_reward_max')::integer, 0),
    0
  );
  v_early_bonus_max := greatest(
    coalesce((v_progress ->> 'early_bonus_max')::integer, 0),
    0
  );
  v_existing_early_bonus := greatest(
    coalesce((v_progress ->> 'early_bonus_earned')::integer, 0),
    0
  );
  v_existing_penalty := greatest(
    coalesce((v_progress ->> 'active_penalties')::integer, 0),
    0
  );
  v_current_iou_effect := coalesce(
    (v_progress ->> 'current_public_score_effect')::integer,
    0
  );

  v_current_contribution_total :=
    public.score_v2_effective_contributions_internal(
      p_subject_user_id,
      v_model_version,
      v_as_of
    );

  v_current_score := greatest(
    300,
    least(1400, v_base_score + v_current_contribution_total)
  );

  select
    coalesce(sum(pay.amount_cents), 0)::bigint,
    coalesce(sum(pay.amount_cents) filter (where pay.paid_at is null), 0)::bigint,
    count(*) filter (where pay.paid_at is null)::integer,
    count(*) filter (
      where pay.paid_at is null
        and pay.due_date < v_today
    )::integer
  into
    v_scheduled_total_cents,
    v_current_remaining_cents,
    v_all_unpaid_count,
    v_overdue_unpaid_count
  from public.payments as pay
  where pay.iou_id = p_iou_id;

  v_current_iou_exposure := greatest(0, coalesce(v_iou.exposure_points, 0));

  select coalesce(sum(greatest(0, coalesce(other_iou.exposure_points, 0))), 0)::integer
  into v_other_exposure
  from public.ious as other_iou
  where other_iou.borrower_id = p_subject_user_id
    and other_iou.id <> p_iou_id
    and other_iou.activated_at is not null
    and other_iou.deleted_at is null
    and other_iou.archived_at is null
    and other_iou.status in ('open', 'late');

  v_current_exposure := least(
    70,
    greatest(0, v_other_exposure + v_current_iou_exposure)
  );

  v_current_visible_trust := public.score_v2_visible_trust(
    v_current_score,
    v_current_exposure,
    100
  );

  if v_iou.deleted_at is not null
     or v_iou.archived_at is not null
     or v_iou.activated_at is null
     or v_iou.status not in ('open', 'late')
     or coalesce((v_progress ->> 'agreement_completed')::boolean, false)
     or v_current_remaining_cents <= 0
  then
    v_ineligible_reason := 'This IOU does not have an eligible remaining payment.';
  elsif v_scenario = 'pay_next_today' then
    select
      pay.id,
      pay.amount_cents,
      pay.due_date
    into
      v_next_payment_id,
      v_payment_amount_cents,
      v_next_due_date
    from public.payments as pay
    where pay.iou_id = p_iou_id
      and pay.paid_at is null
      and lower(coalesce(pay.status, '')) in (
        'scheduled',
        'due',
        'late',
        'overdue',
        'failed'
      )
    order by pay.due_date, pay.id
    limit 1;

    if v_next_payment_id is null
       or v_payment_amount_cents is null
       or v_payment_amount_cents <= 0
    then
      v_ineligible_reason := 'The next payment is not currently eligible for a score estimate.';
    else
      v_eligible := true;
      v_new_early_qualifier := v_next_due_date > v_today;

      if v_next_due_date < v_today then
        v_new_penalty := public.score_v22_late_penalty_points(
          coalesce((v_progress ->> 'agreement_ceiling')::integer, 0),
          v_principal_cents,
          v_payment_amount_cents,
          greatest(v_today - v_next_due_date, 0)
        );
      else
        v_new_penalty := 0;
      end if;
    end if;

  elsif v_scenario = 'payoff_today' then
    select
      coalesce(sum(pay.amount_cents), 0)::bigint,
      count(*)::integer,
      coalesce(bool_or(pay.due_date > v_today), false),
      coalesce(sum(
        public.score_v22_late_penalty_points(
          coalesce((v_progress ->> 'agreement_ceiling')::integer, 0),
          v_principal_cents,
          pay.amount_cents,
          greatest(v_today - pay.due_date, 0)
        )
      ) filter (where pay.due_date < v_today), 0)::integer
    into
      v_payment_amount_cents,
      v_candidate_count,
      v_new_early_qualifier,
      v_new_penalty
    from public.payments as pay
    where pay.iou_id = p_iou_id
      and pay.paid_at is null
      and lower(coalesce(pay.status, '')) in (
        'scheduled',
        'due',
        'late',
        'overdue',
        'failed'
      );

    if v_candidate_count = 0
       or coalesce(v_payment_amount_cents, 0) <= 0
       or v_candidate_count <> v_all_unpaid_count
    then
      v_payment_amount_cents := null;
      v_ineligible_reason := 'The remaining balance is not currently eligible for an immediate payoff estimate.';
    else
      v_eligible := true;
    end if;

  elsif v_scenario = 'complete_on_schedule' then
    select
      coalesce(sum(pay.amount_cents), 0)::bigint,
      count(*)::integer
    into
      v_payment_amount_cents,
      v_candidate_count
    from public.payments as pay
    where pay.iou_id = p_iou_id
      and pay.paid_at is null
      and lower(coalesce(pay.status, '')) in (
        'scheduled',
        'due'
      );

    if v_overdue_unpaid_count > 0 then
      v_payment_amount_cents := null;
      v_ineligible_reason := 'An overdue payment prevents an on-schedule completion estimate.';
    elsif v_candidate_count = 0
       or coalesce(v_payment_amount_cents, 0) <= 0
       or v_candidate_count <> v_all_unpaid_count
    then
      v_payment_amount_cents := null;
      v_ineligible_reason := 'The remaining schedule is not eligible for an on-schedule completion estimate.';
    else
      v_eligible := true;
      v_new_early_qualifier := false;
      v_new_penalty := 0;
    end if;
  end if;

  if not v_eligible then
    v_projected_score := v_current_score;
    v_projected_iou_effect := v_current_iou_effect;
    v_projected_iou_exposure := v_current_iou_exposure;
    v_projected_exposure := v_current_exposure;
    v_projected_visible_trust := v_current_visible_trust;
    v_projected_penalty := v_existing_penalty;
    v_explanation := jsonb_build_array(
      coalesce(v_ineligible_reason, 'Score estimate unavailable.')
    );
  else
    v_projected_remaining_cents := greatest(
      v_current_remaining_cents - coalesce(v_payment_amount_cents, 0),
      0
    );

    v_completes_iou :=
      least(
        v_paid_cents + coalesce(v_payment_amount_cents, 0),
        v_principal_cents
      ) >= v_principal_cents;

    v_projected_penalty := v_existing_penalty + greatest(v_new_penalty, 0);

    if v_existing_early_bonus > 0 or v_new_early_qualifier then
      v_projected_early_bonus := v_early_bonus_max;
    else
      v_projected_early_bonus := 0;
    end if;

    if v_completes_iou then
      v_projected_iou_effect :=
        v_completion_reward_max
        + v_projected_early_bonus
        - v_projected_penalty;
      v_completion_credit_unlocked := v_completion_reward_max;
      v_early_bonus_unlocked := v_projected_early_bonus;
    else
      -- Positive payment progress and any early bonus remain locked until the
      -- IOU is completed. New late penalties are immediately public.
      v_projected_iou_effect := -v_projected_penalty;
      v_completion_credit_unlocked := 0;
      v_early_bonus_unlocked := 0;
    end if;

    v_iou_effect_delta := v_projected_iou_effect - v_current_iou_effect;
    v_projected_score := greatest(
      300,
      least(1400, v_current_score + v_iou_effect_delta)
    );

    v_base_exposure := public.calculate_iou_exposure(
      v_iou.principal_cents::numeric,
      coalesce(v_iou.apr_bps, 0)::numeric,
      coalesce(v_profile.iou_score, 700)
    );

    if v_scheduled_total_cents <= 0
       or v_projected_remaining_cents <= 0
       or v_completes_iou
    then
      v_projected_iou_exposure := 0;
    else
      v_projected_iou_exposure := least(
        70,
        greatest(
          0,
          ceil(
            (v_base_exposure::numeric * v_projected_remaining_cents)
            / v_scheduled_total_cents
          )::integer
        )
      );
    end if;

    v_projected_exposure := least(
      70,
      greatest(0, v_other_exposure + v_projected_iou_exposure)
    );

    v_projected_visible_trust := public.score_v2_visible_trust(
      v_projected_score,
      v_projected_exposure,
      100
    );

    if v_scenario = 'pay_next_today' then
      v_explanation := v_explanation || jsonb_build_array(
        'This estimate assumes the next eligible payment is successfully confirmed today.'
      );
    elsif v_scenario = 'payoff_today' then
      v_explanation := v_explanation || jsonb_build_array(
        'This estimate assumes the full remaining balance is successfully confirmed today.'
      );
    else
      v_explanation := v_explanation || jsonb_build_array(
        'This estimate assumes every remaining payment is completed on its scheduled date and no other score activity changes first.'
      );
    end if;

    if v_completes_iou then
      v_explanation := v_explanation || jsonb_build_array(
        format(
          'Completion would unlock %s base completion points.',
          v_completion_reward_max
        )
      );
    else
      v_explanation := v_explanation || jsonb_build_array(
        'Positive payment progress remains locked until this IOU is completed.'
      );
    end if;

    if v_new_early_qualifier and v_completes_iou then
      v_explanation := v_explanation || jsonb_build_array(
        format(
          'An early payment would qualify for and unlock the %s-point early-payment bonus at completion.',
          v_early_bonus_max
        )
      );
    elsif v_new_early_qualifier then
      v_explanation := v_explanation || jsonb_build_array(
        format(
          'An early payment would qualify for a %s-point bonus that remains locked until completion.',
          v_early_bonus_max
        )
      );
    elsif v_existing_early_bonus > 0 and v_completes_iou then
      v_explanation := v_explanation || jsonb_build_array(
        format(
          'The existing %s-point early-payment bonus would unlock at completion.',
          v_existing_early_bonus
        )
      );
    end if;

    if v_new_penalty > 0 then
      v_explanation := v_explanation || jsonb_build_array(
        format(
          'Paying overdue installments today would add %s late-payment penalty points.',
          v_new_penalty
        )
      );
    end if;

    if v_existing_penalty > 0 then
      v_explanation := v_explanation || jsonb_build_array(
        format(
          '%s existing late-payment penalty points would remain.',
          v_existing_penalty
        )
      );
    end if;

    if v_current_exposure > v_projected_exposure then
      v_explanation := v_explanation || jsonb_build_array(
        format(
          'Active exposure would decrease by %s points.',
          v_current_exposure - v_projected_exposure
        )
      );
    end if;
  end if;

  v_score_delta := v_projected_score - v_current_score;
  v_visible_trust_delta :=
    v_projected_visible_trust - v_current_visible_trust;
  v_exposure_released := greatest(
    v_current_exposure - v_projected_exposure,
    0
  );

  return jsonb_build_object(
    'scenario', v_scenario,
    'eligible', v_eligible,
    'paymentAmountCents', v_payment_amount_cents,
    'currentScore', v_current_score,
    'projectedScore', v_projected_score,
    'scoreDelta', v_score_delta,
    'currentVisibleTrust', v_current_visible_trust,
    'projectedVisibleTrust', v_projected_visible_trust,
    'visibleTrustDelta', v_visible_trust_delta,
    'currentIouEffect', v_current_iou_effect,
    'projectedIouEffect', v_projected_iou_effect,
    'currentExposure', v_current_exposure,
    'projectedExposure', v_projected_exposure,
    'exposureReleased', v_exposure_released,
    'completionCreditUnlocked', v_completion_credit_unlocked,
    'earlyBonusUnlocked', v_early_bonus_unlocked,
    'retainedPenalty', v_projected_penalty,
    'completesIou', v_completes_iou,
    'explanation', v_explanation
  );
end
$function$;

revoke all
  on function public.score_v22_iou_scenario_projection_internal(
    uuid,
    uuid,
    text,
    timestamptz
  )
  from public, anon, authenticated, service_role;

grant execute
  on function public.score_v22_iou_scenario_projection_internal(
    uuid,
    uuid,
    text,
    timestamptz
  )
  to service_role, postgres;

comment on function public.score_v22_iou_scenario_projection_internal(
  uuid,
  uuid,
  text,
  timestamptz
)
is
  'Internal read-only Score v2.2 personal-IOU scenario projector. Reuses active v2.2 contribution, late-penalty, exposure, and Visible Trust rules without recording payment or score evidence.';

create or replace function public.get_my_iou_score_v22_scenario(
  p_iou_id uuid,
  p_scenario text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_caller_id uuid;
  v_caller_role text;
  v_subject_user_id uuid;
begin
  v_caller_id := auth.uid();

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

  if v_caller_id is null then
    if v_caller_role in ('anon', 'authenticated') then
      raise exception 'Authentication required'
        using errcode = '42501';
    elsif v_caller_role = 'service_role' then
      null;
    elsif session_user = 'postgres' then
      null;
    else
      raise exception 'Authentication required'
        using errcode = '42501';
    end if;
  end if;

  begin
    select sa.user_id
    into strict v_subject_user_id
    from public.score_agreements as sa
    where sa.source_type = 'personal_iou'
      and sa.source_id = p_iou_id
      and (
        v_caller_id is null
        or sa.user_id = v_caller_id
      );
  exception
    when no_data_found or too_many_rows then
      raise exception 'IOU score scenario not found or not accessible'
        using errcode = '42501';
  end;

  return public.score_v22_iou_scenario_projection_internal(
    p_iou_id,
    v_subject_user_id,
    p_scenario,
    now()
  );
end
$function$;

revoke all
  on function public.get_my_iou_score_v22_scenario(uuid, text)
  from public, anon, authenticated, service_role;

grant execute
  on function public.get_my_iou_score_v22_scenario(uuid, text)
  to authenticated, service_role, postgres;

comment on function public.get_my_iou_score_v22_scenario(uuid, text)
is
  'Authenticated borrower-facing read-only Score v2.2 IOU scenario estimate. Supported scenarios: pay_next_today, payoff_today, complete_on_schedule. No payment or score evidence is recorded.';

-- Keep internal score tables private.
revoke select
  on table public.score_agreements
  from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Fail-closed deployment invariants.
-- --------------------------------------------------------------------------
do $invariants$
declare
  v_count integer;
  v_security_definer boolean;
begin
  select p.prosecdef
  into v_security_definer
  from pg_proc as p
  join pg_namespace as n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_my_iou_score_v22_scenario'
    and pg_get_function_identity_arguments(p.oid)
        = 'p_iou_id uuid, p_scenario text';

  if v_security_definer is distinct from true then
    raise exception
      'get_my_iou_score_v22_scenario must remain SECURITY DEFINER';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_scenario'
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_count <> 1 then
    raise exception
      'authenticated must have exactly one EXECUTE grant on get_my_iou_score_v22_scenario; found %',
      v_count;
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_scenario'
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'PUBLIC/anon must not execute get_my_iou_score_v22_scenario';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'score_v22_iou_scenario_projection_internal'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'App roles must not execute score_v22_iou_scenario_projection_internal';
  end if;

  select count(*)
  into v_count
  from information_schema.table_privileges
  where table_schema = 'public'
    and table_name = 'score_agreements'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'SELECT';

  if v_count <> 0 then
    raise exception
      'score_agreements SELECT was exposed to an app role';
  end if;
end
$invariants$;

commit;
