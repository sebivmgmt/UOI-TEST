-- ============================================================================
-- Score v2.2 dispatch-integrity regression
-- DEV fixture:
--   score agreement db90834c-948f-473a-831a-453132b05f1c
--   borrower        55e9da3f-3b96-405c-9afa-7b45c74c98dc
-- ============================================================================

begin;

do $tests$
declare
  c_agreement constant uuid :=
    'db90834c-948f-473a-831a-453132b05f1c';
  c_borrower constant uuid :=
    '55e9da3f-3b96-405c-9afa-7b45c74c98dc';

  v_before integer;
  v_after integer;
  v_result jsonb;
  v_snapshot_id uuid;
  v_snapshot public.trust_score_snapshots%rowtype;
  v_effective integer;
  v_count integer;
  v_rejected boolean := false;
begin
  -- 1. The deprecated generic outcome trigger is gone.
  select count(*)
  into v_count
  from pg_trigger
  where tgrelid = 'public.trust_outcome_events'::regclass
    and not tgisinternal
    and tgname = 'trg_score_v2_shadow_on_outcome';

  if v_count <> 0 then
    raise exception
      'Dispatch regression: deprecated generic trigger is still active';
  end if;

  -- 2. The dedicated v2.2 dispatcher exists exactly once.
  select count(*)
  into v_count
  from pg_trigger
  where tgrelid = 'public.trust_outcome_events'::regclass
    and not tgisinternal
    and tgname = 'trg_score_v22_dispatch_outcome_event';

  if v_count <> 1 then
    raise exception
      'Dispatch regression: expected one v2.2 trigger, found %',
      v_count;
  end if;

  -- 3. Generic agreement recalculation dispatches to v2.2 and is idempotent.
  perform public.score_v22_recalculate_agreement(c_agreement, now());

  select count(*)
  into v_before
  from public.score_v2_contributions
  where score_agreement_id = c_agreement
    and model_version = 'v2.2-shadow';

  v_result := public.recalculate_score_v2_agreement(
    c_agreement,
    'v2.2-shadow'
  );

  perform public.recalculate_score_v2_agreement(
    c_agreement,
    'v2.2-shadow'
  );

  select count(*)
  into v_after
  from public.score_v2_contributions
  where score_agreement_id = c_agreement
    and model_version = 'v2.2-shadow';

  if v_result ->> 'model_version' <> 'v2.2-shadow'
     or v_after <> v_before then
    raise exception
      'Dispatch regression: agreement wrapper failed; result=%, before=%, after=%',
      v_result,
      v_before,
      v_after;
  end if;

  -- 4. Generic user recalculation also dispatches v2.2 and remains idempotent.
  perform public.recalculate_score_v2_user(
    c_borrower,
    'v2.2-shadow'
  );

  select count(*)
  into v_before
  from public.score_v2_contributions
  where user_id = c_borrower
    and model_version = 'v2.2-shadow';

  v_result := public.recalculate_score_v2_user(
    c_borrower,
    'v2.2-shadow'
  );

  select count(*)
  into v_after
  from public.score_v2_contributions
  where user_id = c_borrower
    and model_version = 'v2.2-shadow';

  if v_result ->> 'model_version' <> 'v2.2-shadow'
     or v_after <> v_before then
    raise exception
      'Dispatch regression: user wrapper failed; result=%, before=%, after=%',
      v_result,
      v_before,
      v_after;
  end if;

  -- 5. No legacy payment_performance row may exist under v2.2-shadow.
  select count(*)
  into v_count
  from public.score_v2_contributions
  where model_version = 'v2.2-shadow'
    and contribution_type = 'payment_performance';

  if v_count <> 0 then
    raise exception
      'Dispatch regression: found % legacy payment_performance rows under v2.2-shadow',
      v_count;
  end if;

  -- 6. BEFORE INSERT guard rejects a legacy-style v2.2 row.
  begin
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
      metadata,
      impact_direction,
      calculation_details,
      source_outcome_at,
      agreement_ceiling,
      pair_index
    )
    select
      user_id,
      outcome_event_id,
      score_agreement_id,
      'payment_performance',
      source_outcome_type,
      model_key,
      'v2.2-shadow',
      0,
      points_cap,
      metadata,
      'reward',
      jsonb_build_object(
        'model_version',
        'v2.2-shadow'
      ),
      source_outcome_at,
      agreement_ceiling,
      pair_index
    from public.score_v2_contributions
    where score_agreement_id = c_agreement
      and model_version = 'v2.2-shadow'
    limit 1;

    raise exception
      'Dispatch regression: invalid v2.2 insert was not rejected';
  exception
    when check_violation or not_null_violation then
      if sqlerrm like
        'Score v2.2 contribution insert rejected:%' then
        v_rejected := true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception
      'Dispatch regression: invalid insert guard did not fire';
  end if;

  -- 7. Snapshot and effective contribution ledger agree.
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub',
      c_borrower::text,
      'role',
      'authenticated'
    )::text,
    true
  );

  v_snapshot_id := public.create_trust_score_snapshot(
    c_borrower,
    'score_v22_dispatch_regression'
  );

  select *
  into v_snapshot
  from public.trust_score_snapshots
  where id = v_snapshot_id;

  v_effective :=
    public.score_v2_effective_contributions_internal(
      c_borrower,
      'v2.2-shadow',
      now()
    );

  if v_snapshot.model_version <> 'v2.2-shadow'
     or v_snapshot.score_contributed_total <> v_effective
     or v_snapshot.v2_shadow_score
        <> greatest(300, least(1400, 700 + v_effective))
  then
    raise exception
      'Dispatch regression: snapshot mismatch model=%, total=%, effective=%, score=%',
      v_snapshot.model_version,
      v_snapshot.score_contributed_total,
      v_effective,
      v_snapshot.v2_shadow_score;
  end if;
end
$tests$;

select jsonb_build_object(
  'suite', 'Score v2.2 dispatch integrity',
  'passed', true,
  'agreement_wrapper', 'v2.2-aware',
  'user_wrapper', 'v2.2-aware',
  'automatic_outcome_dispatchers', 1,
  'legacy_v2_rows_under_v22', 0,
  'snapshot_consistency', true,
  'cleanup', 'transaction_rollback'
) as score_v22_dispatch_regression_summary;

rollback;
