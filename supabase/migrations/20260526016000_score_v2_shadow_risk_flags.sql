-- IOU Score v2 — Shadow Risk Flags
-- Private/internal risk flag generation.
--
-- No profile score changes.
-- No score event changes.
-- No live scoring switch.

create or replace function public.upsert_score_risk_flag(
  p_user_id uuid,
  p_flag_type text,
  p_severity text default 'low',
  p_source_type text default null,
  p_source_id uuid default null,
  p_description text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_flag_id uuid;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  if p_flag_type is null then
    raise exception 'Missing flag type';
  end if;

  select id
  into v_flag_id
  from public.score_risk_flags
  where user_id = p_user_id
    and flag_type = p_flag_type
    and coalesce(source_type, '') = coalesce(p_source_type, '')
    and source_id is not distinct from p_source_id
    and is_active = true
  limit 1;

  if v_flag_id is not null then
    update public.score_risk_flags
    set
      severity = p_severity,
      description = p_description,
      metadata = coalesce(metadata, '{}'::jsonb) || coalesce(p_metadata, '{}'::jsonb)
    where id = v_flag_id;

    return v_flag_id;
  end if;

  insert into public.score_risk_flags (
    user_id,
    flag_type,
    severity,
    source_type,
    source_id,
    description,
    metadata
  )
  values (
    p_user_id,
    p_flag_type,
    p_severity,
    p_source_type,
    p_source_id,
    p_description,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_flag_id;

  return v_flag_id;
end;
$function$;


create or replace function public.generate_score_v2_shadow_risk_flags()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_created integer := 0;
  r record;
  v_flag_id uuid;
begin
  -- 1. Same-pair concentration.
  for r in
    select
      sa.user_id,
      sa.counterparty_id,
      count(*) as active_pair_count,
      sum(sa.score_ceiling) as active_pair_ceiling,
      max(sa.same_pair_index) as max_same_pair_index
    from public.score_agreements sa
    where sa.source_type = 'personal_iou'
      and sa.status in ('active', 'completed')
      and sa.counterparty_id is not null
      and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    group by sa.user_id, sa.counterparty_id
    having count(*) >= 5
  loop
    v_flag_id := public.upsert_score_risk_flag(
      r.user_id,
      'same_pair_concentration',
      case
        when r.active_pair_count >= 10 then 'high'
        when r.active_pair_count >= 7 then 'medium'
        else 'low'
      end,
      'profile_pair',
      null,
      'Multiple score-affecting IOUs with the same counterparty.',
      jsonb_build_object(
        'counterparty_id', r.counterparty_id,
        'active_pair_count', r.active_pair_count,
        'active_pair_ceiling', r.active_pair_ceiling,
        'max_same_pair_index', r.max_same_pair_index,
        'shadow_mode', true
      )
    );

    v_created := v_created + 1;
  end loop;

  -- 2. Many tiny IOUs.
  for r in
    select
      sa.user_id,
      count(*) as tiny_iou_count,
      sum(sa.score_ceiling) as tiny_iou_ceiling
    from public.score_agreements sa
    where sa.source_type = 'personal_iou'
      and sa.amount_cents < 10000
      and sa.status in ('active', 'completed')
      and sa.score_ceiling > 0
    group by sa.user_id
    having count(*) >= 5
  loop
    v_flag_id := public.upsert_score_risk_flag(
      r.user_id,
      'many_tiny_ious',
      case
        when r.tiny_iou_count >= 20 then 'high'
        when r.tiny_iou_count >= 10 then 'medium'
        else 'low'
      end,
      'score_agreements',
      null,
      'User has many small IOUs; these should build history more than score.',
      jsonb_build_object(
        'tiny_iou_count', r.tiny_iou_count,
        'tiny_iou_ceiling', r.tiny_iou_ceiling,
        'threshold_amount_cents', 10000,
        'shadow_mode', true
      )
    );

    v_created := v_created + 1;
  end loop;

  -- 3. Self no-score detected.
  for r in
    select
      sa.user_id,
      count(*) as self_iou_count
    from public.score_agreements sa
    where sa.user_id = sa.counterparty_id
      and sa.source_type = 'personal_iou'
    group by sa.user_id
    having count(*) > 0
  loop
    v_flag_id := public.upsert_score_risk_flag(
      r.user_id,
      'self_no_score_detected',
      'low',
      'score_agreements',
      null,
      'Self IOUs were detected and excluded from score impact.',
      jsonb_build_object(
        'self_iou_count', r.self_iou_count,
        'shadow_mode', true
      )
    );

    v_created := v_created + 1;
  end loop;

  -- 4. High active exposure.
  for r in
    select
      id as user_id,
      active_exposure_points
    from public.profiles
    where coalesce(active_exposure_points, 0) >= 50
  loop
    v_flag_id := public.upsert_score_risk_flag(
      r.user_id,
      'high_active_exposure',
      case
        when r.active_exposure_points >= 100 then 'high'
        when r.active_exposure_points >= 70 then 'medium'
        else 'low'
      end,
      'profiles',
      r.user_id,
      'User has elevated active exposure.',
      jsonb_build_object(
        'active_exposure_points', r.active_exposure_points,
        'shadow_mode', true
      )
    );

    v_created := v_created + 1;
  end loop;

  return v_created;
end;
$function$;