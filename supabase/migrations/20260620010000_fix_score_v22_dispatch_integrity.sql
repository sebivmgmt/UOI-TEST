begin;

-- ============================================================================
-- Score v2.2 dispatch integrity
--
-- Fixes:
--   1. Generic agreement/user recalculation wrappers now dispatch v2.2 to the
--      dedicated v2.2 engine instead of the legacy generic internal engine.
--   2. The deprecated generic outcome trigger is removed. v2.2 now has one
--      automatic outcome dispatcher.
--   3. A BEFORE INSERT guard rejects legacy-style rows written under the
--      v2.2-shadow model version.
--
-- Existing v2.0/v2.1 contribution history remains untouched.
-- ============================================================================

create or replace function public.score_v22_validate_contribution_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.model_version <> 'v2.2-shadow' then
    return new;
  end if;

  if new.contribution_type not in (
    'agreement_completion',
    'early_payment_bonus',
    'payment_late_penalty'
  ) then
    raise exception
      'Score v2.2 contribution insert rejected: contribution_type % is not valid for v2.2-shadow',
      new.contribution_type
      using errcode = '23514';
  end if;

  if new.contribution_type in (
    'agreement_completion',
    'early_payment_bonus'
  ) and new.impact_direction <> 'reward' then
    raise exception
      'Score v2.2 contribution insert rejected: % must be a reward',
      new.contribution_type
      using errcode = '23514';
  end if;

  if new.contribution_type = 'payment_late_penalty'
     and new.impact_direction <> 'penalty' then
    raise exception
      'Score v2.2 contribution insert rejected: payment_late_penalty must be a penalty'
      using errcode = '23514';
  end if;

  if new.source_outcome_at is null then
    raise exception
      'Score v2.2 contribution insert rejected: source_outcome_at is required'
      using errcode = '23502';
  end if;

  if new.agreement_ceiling is null or new.agreement_ceiling < 0 then
    raise exception
      'Score v2.2 contribution insert rejected: agreement_ceiling is required and nonnegative'
      using errcode = '23514';
  end if;

  if new.pair_index is null or new.pair_index < 1 then
    raise exception
      'Score v2.2 contribution insert rejected: pair_index is required and must be positive'
      using errcode = '23514';
  end if;

  if nullif(btrim(new.source_outcome_type), '') is null then
    raise exception
      'Score v2.2 contribution insert rejected: source_outcome_type is required'
      using errcode = '23502';
  end if;

  if coalesce(new.calculation_details ->> 'model_version', '')
     <> 'v2.2-shadow' then
    raise exception
      'Score v2.2 contribution insert rejected: calculation_details.model_version must equal v2.2-shadow'
      using errcode = '23514';
  end if;

  return new;
end
$function$;

drop trigger if exists trg_score_v22_validate_contribution_insert
  on public.score_v2_contributions;

create trigger trg_score_v22_validate_contribution_insert
before insert on public.score_v2_contributions
for each row
execute function public.score_v22_validate_contribution_insert();

revoke all
  on function public.score_v22_validate_contribution_insert()
  from public, anon, authenticated, service_role;

grant execute
  on function public.score_v22_validate_contribution_insert()
  to postgres;

-- --------------------------------------------------------------------------
-- Controlled agreement wrapper: dispatch by immutable model version.
-- --------------------------------------------------------------------------
create or replace function public.recalculate_score_v2_agreement(
  p_score_agreement_id uuid,
  p_model_version text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller_role text;
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

  if v_caller_role <> 'service_role'
     and session_user <> 'postgres' then
    raise exception 'Service-role or postgres required'
      using errcode = '42501';
  end if;

  if p_model_version = 'v2.2-shadow' then
    return public.score_v22_recalculate_agreement(
      p_score_agreement_id,
      now()
    );
  elsif p_model_version = 'v2.1-shadow' then
    return public.score_v2_recalculate_agreement_v21(
      p_score_agreement_id
    );
  else
    return public.score_v2_recalculate_agreement_internal(
      p_score_agreement_id,
      p_model_version
    );
  end if;
end
$function$;

-- --------------------------------------------------------------------------
-- Controlled user wrapper: every agreement uses the same version-aware
-- dispatch. The wrapper remains service-role/postgres only.
-- --------------------------------------------------------------------------
create or replace function public.recalculate_score_v2_user(
  p_user_id uuid,
  p_model_version text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller_role text;
  v_agr_id uuid;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
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

  if v_caller_role <> 'service_role'
     and session_user <> 'postgres' then
    raise exception 'Service-role or postgres required'
      using errcode = '42501';
  end if;

  for v_agr_id in
    select id
    from public.score_agreements
    where user_id = p_user_id
      and source_type = 'personal_iou'
    order by created_at, id
  loop
    if p_model_version = 'v2.2-shadow' then
      v_result := public.score_v22_recalculate_agreement(
        v_agr_id,
        now()
      );
    elsif p_model_version = 'v2.1-shadow' then
      v_result := public.score_v2_recalculate_agreement_v21(
        v_agr_id
      );
    else
      v_result := public.score_v2_recalculate_agreement_internal(
        v_agr_id,
        p_model_version
      );
    end if;

    v_results := v_results || jsonb_build_array(v_result);
  end loop;

  return jsonb_build_object(
    'ok', true,
    'user_id', p_user_id,
    'model_version', p_model_version,
    'agreements_processed', jsonb_array_length(v_results),
    'results', v_results
  );
end
$function$;

revoke all
  on function public.recalculate_score_v2_agreement(uuid, text)
  from public, anon, authenticated;

revoke all
  on function public.recalculate_score_v2_user(uuid, text)
  from public, anon, authenticated;

grant execute
  on function public.recalculate_score_v2_agreement(uuid, text)
  to postgres, service_role;

grant execute
  on function public.recalculate_score_v2_user(uuid, text)
  to postgres, service_role;

-- The legacy internal function must not be directly callable through API roles.
-- Version-aware wrappers above remain the supported entry points.
revoke all
  on function public.score_v2_recalculate_agreement_internal(uuid, text)
  from public, anon, authenticated, service_role;

grant execute
  on function public.score_v2_recalculate_agreement_internal(uuid, text)
  to postgres;

-- v2.1 remains available only through the controlled wrapper for audit and
-- historical regression use.
revoke all
  on function public.score_v2_recalculate_agreement_v21(uuid)
  from public, anon, authenticated;

grant execute
  on function public.score_v2_recalculate_agreement_v21(uuid)
  to postgres, service_role;

-- --------------------------------------------------------------------------
-- Sole outcome dispatcher.
--
-- v2.1 is deprecated and preserved. It must not continue generating new
-- automatic rows. v2.2-shadow is the sole shadow model and therefore the only
-- automatic outcome dispatcher.
-- --------------------------------------------------------------------------
drop trigger if exists trg_score_v2_shadow_on_outcome
  on public.trust_outcome_events;

-- --------------------------------------------------------------------------
-- Fail-closed deployment invariants.
-- --------------------------------------------------------------------------
do $invariants$
declare
  v_count integer;
begin
  select count(*)
  into v_count
  from pg_trigger
  where tgrelid = 'public.trust_outcome_events'::regclass
    and not tgisinternal
    and tgname = 'trg_score_v22_dispatch_outcome_event';

  if v_count <> 1 then
    raise exception
      'Expected exactly one v2.2 outcome trigger; found %',
      v_count;
  end if;

  select count(*)
  into v_count
  from pg_trigger
  where tgrelid = 'public.trust_outcome_events'::regclass
    and not tgisinternal
    and tgname = 'trg_score_v2_shadow_on_outcome';

  if v_count <> 0 then
    raise exception
      'Deprecated generic outcome trigger is still active';
  end if;

  select count(*)
  into v_count
  from public.trust_model_versions
  where model_key = 'iou_score'
    and status = 'shadow';

  if v_count <> 1 then
    raise exception
      'Expected exactly one shadow model; found %',
      v_count;
  end if;

  if not exists (
    select 1
    from public.trust_model_versions
    where model_key = 'iou_score'
      and version = 'v2.2-shadow'
      and status = 'shadow'
  ) then
    raise exception
      'v2.2-shadow is not the sole active shadow model';
  end if;

  select count(*)
  into v_count
  from public.score_v2_contributions
  where model_version = 'v2.2-shadow'
    and (
      contribution_type not in (
        'agreement_completion',
        'early_payment_bonus',
        'payment_late_penalty'
      )
      or source_outcome_at is null
      or agreement_ceiling is null
      or pair_index is null
      or coalesce(
        calculation_details ->> 'model_version',
        ''
      ) <> 'v2.2-shadow'
      or (
        contribution_type in (
          'agreement_completion',
          'early_payment_bonus'
        )
        and impact_direction <> 'reward'
      )
      or (
        contribution_type = 'payment_late_penalty'
        and impact_direction <> 'penalty'
      )
    );

  if v_count <> 0 then
    raise exception
      'Found % invalid pre-existing v2.2 contribution rows',
      v_count;
  end if;
end
$invariants$;

commit;
