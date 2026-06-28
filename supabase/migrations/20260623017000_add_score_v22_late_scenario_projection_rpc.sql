begin;

-- ============================================================================
-- Score v2.2 borrower-facing late-payment scenario projection
--
-- Purpose:
--   Return a read-only estimate for one supported late-payment checkpoint.
--   The projection reuses the active v2.2 late-penalty, contribution,
--   exposure, and Visible Trust rules without recording any payment, outcome,
--   contribution, exposure, or snapshot row.
--
-- Important semantics:
--   * "While unpaid" values describe the current score/exposure state before
--     any late payment is confirmed.
--   * "Projected" values describe the estimate after the selected payment is
--     successfully confirmed exactly p_days_late days late.
--   * A missed/unpaid payment is not silently converted into a new score event.
-- ============================================================================

create or replace function public.score_v22_iou_late_scenario_projection_internal(
  p_iou_id uuid,
  p_payment_id uuid,
  p_subject_user_id uuid,
  p_days_late integer,
  p_as_of timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_as_of timestamptz := coalesce(p_as_of, now());

  v_iou public.ious%rowtype;
  v_payment public.payments%rowtype;
  v_profile public.profiles%rowtype;
  v_score_agreement_id uuid;
  v_progress jsonb;
  v_pay_now jsonb;

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

  v_current_visible_trust integer := 700;
  v_projected_visible_trust integer := 700;
  v_visible_trust_delta integer := 0;

  v_principal_cents bigint := 0;
  v_paid_cents bigint := 0;
  v_scheduled_total_cents bigint := 0;
  v_current_remaining_cents bigint := 0;
  v_projected_remaining_cents bigint := 0;

  v_agreement_ceiling integer := 0;
  v_completion_reward_max integer := 0;
  v_early_bonus_earned integer := 0;
  v_existing_penalty integer := 0;
  v_additional_late_penalty integer := 0;
  v_total_retained_penalty integer := 0;

  v_completes_iou boolean := false;
  v_eligible boolean := false;
  v_ineligible_reason text;

  v_base_exposure integer := 0;

  v_pay_now_projected_score integer := 0;
  v_pay_now_projected_visible_trust integer := 0;
  v_pay_now_projected_iou_effect integer := 0;
  v_opportunity_loss_vs_pay_now integer := 0;

  v_explanation jsonb := '[]'::jsonb;
begin
  if p_iou_id is null
     or p_payment_id is null
     or p_subject_user_id is null
  then
    raise exception 'Missing required late scenario input'
      using errcode = '22023';
  end if;

  if p_days_late not in (1, 7, 14, 30) then
    raise exception 'Unsupported late-payment checkpoint'
      using errcode = '22023';
  end if;

  select i.*
  into v_iou
  from public.ious as i
  where i.id = p_iou_id
    and i.borrower_id = p_subject_user_id;

  if not found then
    raise exception 'IOU late scenario not found or not accessible'
      using errcode = '42501';
  end if;

  select pay.*
  into v_payment
  from public.payments as pay
  where pay.id = p_payment_id
    and pay.iou_id = p_iou_id;

  if not found then
    raise exception 'IOU late scenario not found or not accessible'
      using errcode = '42501';
  end if;

  select p.*
  into v_profile
  from public.profiles as p
  where p.id = p_subject_user_id;

  if not found then
    raise exception 'IOU late scenario not found or not accessible'
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
      raise exception 'IOU late scenario not found or not accessible'
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
  v_agreement_ceiling := greatest(
    coalesce((v_progress ->> 'agreement_ceiling')::integer, 0),
    0
  );
  v_completion_reward_max := greatest(
    coalesce((v_progress ->> 'completion_reward_max')::integer, 0),
    0
  );
  v_early_bonus_earned := greatest(
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
    coalesce(sum(pay.amount_cents) filter (where pay.paid_at is null), 0)::bigint
  into
    v_scheduled_total_cents,
    v_current_remaining_cents
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
    v_ineligible_reason := 'This IOU does not have an eligible unpaid payment.';
  elsif v_payment.paid_at is not null
     or lower(coalesce(v_payment.status, '')) not in (
       'scheduled',
       'due',
       'late',
       'overdue',
       'failed'
     )
     or coalesce(v_payment.amount_cents, 0) <= 0
  then
    v_ineligible_reason := 'This payment is not eligible for a late-payment estimate.';
  else
    v_eligible := true;
  end if;

  if not v_eligible then
    return jsonb_build_object(
      'eligible', false,
      'daysLate', p_days_late,
      'paymentAmountCents', null,
      'dueDate', v_payment.due_date,
      'currentScore', v_current_score,
      'projectedScore', v_current_score,
      'scoreDelta', 0,
      'currentVisibleTrust', v_current_visible_trust,
      'projectedVisibleTrust', v_current_visible_trust,
      'visibleTrustDelta', 0,
      'currentIouEffect', v_current_iou_effect,
      'projectedIouEffect', v_current_iou_effect,
      'additionalLatePenalty', 0,
      'totalRetainedPenalty', v_existing_penalty,
      'currentExposure', v_current_exposure,
      'projectedExposure', v_current_exposure,
      'completionCreditStillLocked', v_completion_reward_max,
      'earlyBonusStillLocked', v_early_bonus_earned,
      'completesIou', false,
      'payNowProjectedScore', v_current_score,
      'payNowProjectedVisibleTrust', v_current_visible_trust,
      'opportunityLossVsPayNow', 0,
      'explanation', jsonb_build_array(
        coalesce(v_ineligible_reason, 'Late-payment estimate unavailable.')
      )
    );
  end if;

  v_additional_late_penalty := public.score_v22_late_penalty_points(
    v_agreement_ceiling,
    v_principal_cents,
    v_payment.amount_cents,
    p_days_late
  );

  v_total_retained_penalty :=
    v_existing_penalty + greatest(v_additional_late_penalty, 0);

  v_projected_remaining_cents := greatest(
    v_current_remaining_cents - v_payment.amount_cents,
    0
  );

  v_completes_iou := least(
    v_paid_cents + v_payment.amount_cents,
    v_principal_cents
  ) >= v_principal_cents;

  if v_completes_iou then
    v_projected_iou_effect :=
      v_completion_reward_max
      + v_early_bonus_earned
      - v_total_retained_penalty;
  else
    -- Positive progress remains locked until completion. The hypothetical late
    -- penalty is public once the late payment is authoritatively confirmed.
    v_projected_iou_effect := -v_total_retained_penalty;
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

  v_score_delta := v_projected_score - v_current_score;
  v_visible_trust_delta :=
    v_projected_visible_trust - v_current_visible_trust;

  -- Compare against the existing authoritative "pay next today" projector.
  -- This is informational only and records nothing.
  v_pay_now := public.score_v22_iou_scenario_projection_internal(
    p_iou_id,
    p_subject_user_id,
    'pay_next_today',
    v_as_of
  );

  v_pay_now_projected_score := coalesce(
    (v_pay_now ->> 'projectedScore')::integer,
    v_current_score
  );
  v_pay_now_projected_visible_trust := coalesce(
    (v_pay_now ->> 'projectedVisibleTrust')::integer,
    v_current_visible_trust
  );
  v_pay_now_projected_iou_effect := coalesce(
    (v_pay_now ->> 'projectedIouEffect')::integer,
    v_current_iou_effect
  );

  v_opportunity_loss_vs_pay_now := greatest(
    v_pay_now_projected_iou_effect - v_projected_iou_effect,
    0
  );

  v_explanation := jsonb_build_array(
    format(
      'While this payment remains unpaid, completion credit stays locked and active exposure remains in place.'
    ),
    format(
      'If this payment is successfully confirmed %s day%s late, the estimated additional late-payment penalty is %s point%s.',
      p_days_late,
      case when p_days_late = 1 then '' else 's' end,
      v_additional_late_penalty,
      case when v_additional_late_penalty = 1 then '' else 's' end
    ),
    format(
      'Compared with paying now, this scenario gives up an estimated %s point%s of this IOU''s projected contribution.',
      v_opportunity_loss_vs_pay_now,
      case when v_opportunity_loss_vs_pay_now = 1 then '' else 's' end
    )
  );

  if v_completes_iou then
    v_explanation := v_explanation || jsonb_build_array(
      format(
        'Successful confirmation would complete the IOU and unlock %s completion points, while all recorded penalties remain.',
        v_completion_reward_max
      )
    );
  else
    v_explanation := v_explanation || jsonb_build_array(
      'This payment would not complete the IOU, so positive progress would remain locked.'
    );
  end if;

  return jsonb_build_object(
    'eligible', true,
    'daysLate', p_days_late,
    'paymentAmountCents', v_payment.amount_cents,
    'dueDate', v_payment.due_date,
    'currentScore', v_current_score,
    'projectedScore', v_projected_score,
    'scoreDelta', v_score_delta,
    'currentVisibleTrust', v_current_visible_trust,
    'projectedVisibleTrust', v_projected_visible_trust,
    'visibleTrustDelta', v_visible_trust_delta,
    'currentIouEffect', v_current_iou_effect,
    'projectedIouEffect', v_projected_iou_effect,
    'additionalLatePenalty', v_additional_late_penalty,
    'totalRetainedPenalty', v_total_retained_penalty,
    'currentExposure', v_current_exposure,
    'projectedExposure', v_projected_exposure,
    'completionCreditStillLocked', v_completion_reward_max,
    'earlyBonusStillLocked', v_early_bonus_earned,
    'completesIou', v_completes_iou,
    'payNowProjectedScore', v_pay_now_projected_score,
    'payNowProjectedVisibleTrust', v_pay_now_projected_visible_trust,
    'opportunityLossVsPayNow', v_opportunity_loss_vs_pay_now,
    'explanation', v_explanation
  );
end
$function$;

revoke all
  on function public.score_v22_iou_late_scenario_projection_internal(
    uuid,
    uuid,
    uuid,
    integer,
    timestamptz
  )
  from public, anon, authenticated, service_role;

grant execute
  on function public.score_v22_iou_late_scenario_projection_internal(
    uuid,
    uuid,
    uuid,
    integer,
    timestamptz
  )
  to service_role, postgres;

comment on function public.score_v22_iou_late_scenario_projection_internal(
  uuid,
  uuid,
  uuid,
  integer,
  timestamptz
)
is
  'Internal read-only Score v2.2 late-payment projector. Returns while-unpaid context and the estimate after one payment is successfully confirmed at a supported late checkpoint. Records no financial or scoring evidence.';

create or replace function public.get_my_iou_score_v22_late_scenario(
  p_iou_id uuid,
  p_payment_id uuid,
  p_days_late integer
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
      raise exception 'IOU late scenario not found or not accessible'
        using errcode = '42501';
  end;

  return public.score_v22_iou_late_scenario_projection_internal(
    p_iou_id,
    p_payment_id,
    v_subject_user_id,
    p_days_late,
    now()
  );
end
$function$;

revoke all
  on function public.get_my_iou_score_v22_late_scenario(uuid, uuid, integer)
  from public, anon, authenticated, service_role;

grant execute
  on function public.get_my_iou_score_v22_late_scenario(uuid, uuid, integer)
  to authenticated, service_role, postgres;

comment on function public.get_my_iou_score_v22_late_scenario(uuid, uuid, integer)
is
  'Authenticated borrower-facing read-only Score v2.2 late-payment estimate. Supported checkpoints: 1, 7, 14, 30 days late. Records no payment or score evidence.';

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
    and p.proname = 'get_my_iou_score_v22_late_scenario'
    and pg_get_function_identity_arguments(p.oid)
        = 'p_iou_id uuid, p_payment_id uuid, p_days_late integer';

  if v_security_definer is distinct from true then
    raise exception
      'get_my_iou_score_v22_late_scenario must remain SECURITY DEFINER';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_late_scenario'
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_count <> 1 then
    raise exception
      'authenticated must have exactly one EXECUTE grant on get_my_iou_score_v22_late_scenario; found %',
      v_count;
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'get_my_iou_score_v22_late_scenario'
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'PUBLIC/anon must not execute get_my_iou_score_v22_late_scenario';
  end if;

  select count(*)
  into v_count
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name = 'score_v22_iou_late_scenario_projection_internal'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception
      'App roles must not execute score_v22_iou_late_scenario_projection_internal';
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
