-- ============================================================================
-- Regression tests: Score v2.2 Official Read Cutover
-- DEV project only: colkilearqxuyldzjutw
--
-- Tests:
--   T1-T9    correctness: score formula, supersession, clamping, exposure
--   T10      read immutability: all 6 targets, both public RPCs
--   T11-T14  structural: column count, grants, function existence
--   SA1-SA5  behavioral security: JWT-based role tests, Trust Report auth
--
-- Rollback regression is in: score_v22_official_read_cutover_rollback_regression.sql
-- ============================================================================

begin;

do $$
declare
  -- primary fixture (most v2.2 contributions)
  v_test_user_id  uuid;
  -- secondary fixture (for cross-user isolation and Trust Report tests)
  v_other_user_id uuid;

  -- canonical function result
  v_canonical     record;
  -- get_my_current_trust_score() result (called as v_test_user_id)
  v_rpc           record;
  -- get_my_current_trust_score() result (called as v_other_user_id)
  v_other_rpc     record;
  -- canonical result for v_other_user_id
  v_other_canon   record;
  -- view row
  v_view          record;

  -- formula verification
  v_raw_contribution  integer;
  v_expected_score    integer;
  v_expected_visible  integer;

  -- immutability snapshots — counts
  v_toe_count_before     bigint;
  v_toe_count_after      bigint;
  v_contrib_count_before bigint;
  v_contrib_count_after  bigint;
  v_agree_count_before   bigint;
  v_agree_count_after    bigint;
  v_snap_count_before    bigint;
  v_snap_count_after     bigint;
  -- immutability snapshots — profile field values (counts alone are insufficient)
  v_iou_score_before     integer;
  v_iou_score_after      integer;
  v_exposure_before      integer;
  v_exposure_after       integer;

  -- security tests
  v_denied   boolean;
  v_row_count integer;
begin

  -- ── resolve primary fixture ───────────────────────────────────────────────
  select sc.user_id
  into   v_test_user_id
  from   public.score_v2_contributions sc
  where  sc.model_key     = 'iou_score'
    and  sc.model_version = 'v2.2-shadow'
  group  by sc.user_id
  order  by count(*) desc
  limit  1;

  if v_test_user_id is null then
    raise exception 'SETUP FAIL: no v2.2-shadow contributions. Seed fixture data.';
  end if;

  -- resolve secondary fixture (different user, also with v2.2 contributions)
  select sc.user_id
  into   v_other_user_id
  from   public.score_v2_contributions sc
  where  sc.model_key     = 'iou_score'
    and  sc.model_version = 'v2.2-shadow'
    and  sc.user_id       <> v_test_user_id
  group  by sc.user_id
  order  by count(*) desc
  limit  1;

  -- ── T1: canonical function returns row with non-null score ────────────────
  select * into v_canonical
  from   public.score_v22_current_state_internal(v_test_user_id);

  if v_canonical is null then
    raise exception 'T1 FAIL: score_v22_current_state_internal returned no row';
  end if;
  if v_canonical.shadow_score is null then
    raise exception 'T1 FAIL: shadow_score is null';
  end if;
  if v_canonical.model_version is distinct from 'v2.2-shadow' then
    raise exception 'T1 FAIL: model_version % != v2.2-shadow', v_canonical.model_version;
  end if;
  raise notice 'T1 PASS: canonical returns score=% for %', v_canonical.shadow_score, v_test_user_id;

  -- ── T2: score clamped to [300, 1400] ─────────────────────────────────────
  if v_canonical.shadow_score < 300 or v_canonical.shadow_score > 1400 then
    raise exception 'T2 FAIL: shadow_score % outside [300, 1400]', v_canonical.shadow_score;
  end if;
  raise notice 'T2 PASS: shadow_score % in [300, 1400]', v_canonical.shadow_score;

  -- ── T3: score formula matches supersession-filtered contribution sum ───────
  select coalesce(sum(
    case when sc.impact_direction = 'penalty' then -sc.points_awarded
         else sc.points_awarded end
  ), 0)::integer
  into v_raw_contribution
  from public.score_v2_contributions sc
  join public.trust_outcome_events toe on toe.id = sc.outcome_event_id
  where sc.user_id       = v_test_user_id
    and sc.model_key     = 'iou_score'
    and sc.model_version = 'v2.2-shadow'
    and toe.outcome_at   > now() - interval '2 years'
    and toe.created_at   <= now()
    and sc.calculated_at <= now()
    and not exists (
      select 1 from public.trust_outcome_events child
      where child.supersedes_outcome_event_id = toe.id
        and child.created_at <= now()
    );

  v_expected_score := greatest(300, least(1400, 700 + v_raw_contribution));

  if v_canonical.shadow_score is distinct from v_expected_score then
    raise exception 'T3 FAIL: canonical score % != audit formula score %',
      v_canonical.shadow_score, v_expected_score;
  end if;
  raise notice 'T3 PASS: score % matches audit formula (contribution=%)',
    v_canonical.shadow_score, v_raw_contribution;

  -- ── T4: effective_contribution_total matches supersession-filtered sum ─────
  if v_canonical.effective_contribution_total is distinct from v_raw_contribution then
    raise exception 'T4 FAIL: effective_contribution_total % != supersession-filtered %',
      v_canonical.effective_contribution_total, v_raw_contribution;
  end if;
  raise notice 'T4 PASS: no double-counting; effective_contribution_total=%', v_raw_contribution;

  -- ── T5: visible_trust in [300, shadow_score] ─────────────────────────────
  if v_canonical.visible_trust < 300 then
    raise exception 'T5 FAIL: visible_trust % < 300', v_canonical.visible_trust;
  end if;
  if v_canonical.visible_trust > v_canonical.shadow_score then
    raise exception 'T5 FAIL: visible_trust % > shadow_score %',
      v_canonical.visible_trust, v_canonical.shadow_score;
  end if;
  raise notice 'T5 PASS: visible_trust % in [300, %]',
    v_canonical.visible_trust, v_canonical.shadow_score;

  -- ── T6: exposure reduces visible_trust correctly ──────────────────────────
  v_expected_visible := greatest(300, v_canonical.shadow_score - v_canonical.active_exposure_points);
  if v_canonical.visible_trust is distinct from v_expected_visible then
    raise exception 'T6 FAIL: visible_trust % != max(300, score-exposure)=%',
      v_canonical.visible_trust, v_expected_visible;
  end if;
  raise notice 'T6 PASS: exposure deducted (score=%, exposure=%, visible=%)',
    v_canonical.shadow_score, v_canonical.active_exposure_points, v_canonical.visible_trust;

  -- ── T7: trust_report_shadow_v.public_score matches canonical ─────────────
  select * into v_view
  from   public.trust_report_shadow_v
  where  user_id = v_test_user_id;

  if v_view is null then
    raise exception 'T7 FAIL: no row in trust_report_shadow_v for %', v_test_user_id;
  end if;
  if v_view.public_score is distinct from v_canonical.shadow_score then
    raise exception 'T7 FAIL: view.public_score % != canonical.shadow_score %',
      v_view.public_score, v_canonical.shadow_score;
  end if;
  raise notice 'T7 PASS: view.public_score % matches canonical', v_view.public_score;

  -- ── T8: trust_report_shadow_v.visible_trust matches canonical ────────────
  if v_view.visible_trust is distinct from v_canonical.visible_trust then
    raise exception 'T8 FAIL: view.visible_trust % != canonical.visible_trust %',
      v_view.visible_trust, v_canonical.visible_trust;
  end if;
  raise notice 'T8 PASS: view.visible_trust % matches canonical', v_view.visible_trust;

  -- ── T8b–T8g: remaining 6 canonical fields exactly match view ──────────────
  if v_view.active_exposure_points is distinct from v_canonical.active_exposure_points then
    raise exception 'T8b FAIL: view.active_exposure_points % != canonical %',
      v_view.active_exposure_points, v_canonical.active_exposure_points;
  end if;
  raise notice 'T8b PASS: view.active_exposure_points=%', v_view.active_exposure_points;

  if v_view.trust_tier is distinct from v_canonical.trust_tier then
    raise exception 'T8c FAIL: view.trust_tier % != canonical %',
      v_view.trust_tier, v_canonical.trust_tier;
  end if;
  raise notice 'T8c PASS: view.trust_tier=%', v_view.trust_tier;

  if v_view.proof_depth is distinct from v_canonical.proof_depth then
    raise exception 'T8d FAIL: view.proof_depth % != canonical %',
      v_view.proof_depth, v_canonical.proof_depth;
  end if;
  raise notice 'T8d PASS: view.proof_depth=%', v_view.proof_depth;

  if v_view.proof_depth_label is distinct from v_canonical.proof_depth_label then
    raise exception 'T8e FAIL: view.proof_depth_label % != canonical %',
      v_view.proof_depth_label, v_canonical.proof_depth_label;
  end if;
  raise notice 'T8e PASS: view.proof_depth_label=%', v_view.proof_depth_label;

  if v_view.confidence_score is distinct from v_canonical.confidence_score then
    raise exception 'T8f FAIL: view.confidence_score % != canonical %',
      v_view.confidence_score, v_canonical.confidence_score;
  end if;
  raise notice 'T8f PASS: view.confidence_score=%', v_view.confidence_score;

  if v_view.confidence_label is distinct from v_canonical.confidence_label then
    raise exception 'T8g FAIL: view.confidence_label % != canonical %',
      v_view.confidence_label, v_canonical.confidence_label;
  end if;
  raise notice 'T8g PASS: view.confidence_label=%', v_view.confidence_label;

  -- ── T9: proof_depth in [0, 100] and trust_tier is a valid value ──────────
  if v_canonical.proof_depth < 0 or v_canonical.proof_depth > 100 then
    raise exception 'T9 FAIL: proof_depth % outside [0, 100]', v_canonical.proof_depth;
  end if;
  if v_view.trust_tier not in (
    'rebuilding_user', 'verified_user', 'developing_trust',
    'reliable', 'strong', 'excellent', 'elite_trust', 'iou_pillar'
  ) then
    raise exception 'T9 FAIL: view.trust_tier % is not a recognised tier', v_view.trust_tier;
  end if;
  raise notice 'T9 PASS: proof_depth=%, trust_tier=%',
    v_canonical.proof_depth, v_view.trust_tier;

  -- ════════════════════════════════════════════════════════════════════════════
  -- T10: READ IMMUTABILITY
  -- Capture before-state for all 6 targets. Execute all read paths including
  -- get_my_current_trust_score() and get_trust_report_for_viewer(). Verify
  -- after-state is identical. Profile fields are compared by value, not count.
  -- ════════════════════════════════════════════════════════════════════════════

  -- T10-A: capture before state ─────────────────────────────────────────────
  select count(*) into v_toe_count_before
  from public.trust_outcome_events;

  select count(*) into v_contrib_count_before
  from public.score_v2_contributions;

  select count(*) into v_agree_count_before
  from public.score_agreements;

  select count(*) into v_snap_count_before
  from public.trust_score_snapshots;

  select p.iou_score, p.active_exposure_points
  into   v_iou_score_before, v_exposure_before
  from   public.profiles p
  where  p.id = v_test_user_id;

  -- T10-B: execute all read paths ───────────────────────────────────────────

  -- canonical internal function
  perform * from public.score_v22_current_state_internal(v_test_user_id);

  -- view
  perform * from public.trust_report_shadow_v where user_id = v_test_user_id;

  -- public self-score RPC (set JWT so auth.uid() resolves)
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_test_user_id::text, 'role', 'authenticated')::text,
    true
  );
  perform * from public.get_my_current_trust_score();

  -- Trust Report RPC: insert a temporary share so we can call the authorized path
  -- (INSERT is rolled back with the transaction; does not persist to DEV data)
  if v_other_user_id is not null then
    delete from public.trust_report_shares
    where  owner_user_id  = v_test_user_id
      and  viewer_user_id = v_other_user_id;

    insert into public.trust_report_shares (
      owner_user_id, viewer_user_id, scope
    ) values (v_test_user_id, v_other_user_id, 'summary');

    perform * from public.get_trust_report_for_viewer(v_test_user_id, v_other_user_id, 'summary');
  else
    raise notice 'T10 SKIP (viewer path): no second fixture user; skipping get_trust_report_for_viewer read';
  end if;

  -- T10-C: capture after state and assert ───────────────────────────────────
  select count(*) into v_toe_count_after    from public.trust_outcome_events;
  select count(*) into v_contrib_count_after from public.score_v2_contributions;
  select count(*) into v_agree_count_after   from public.score_agreements;
  select count(*) into v_snap_count_after    from public.trust_score_snapshots;

  select p.iou_score, p.active_exposure_points
  into   v_iou_score_after, v_exposure_after
  from   public.profiles p
  where  p.id = v_test_user_id;

  if v_toe_count_before != v_toe_count_after then
    raise exception 'T10 FAIL: trust_outcome_events count changed % → %',
      v_toe_count_before, v_toe_count_after;
  end if;
  if v_contrib_count_before != v_contrib_count_after then
    raise exception 'T10 FAIL: score_v2_contributions count changed % → %',
      v_contrib_count_before, v_contrib_count_after;
  end if;
  if v_agree_count_before != v_agree_count_after then
    raise exception 'T10 FAIL: score_agreements count changed % → %',
      v_agree_count_before, v_agree_count_after;
  end if;
  if v_snap_count_before != v_snap_count_after then
    raise exception 'T10 FAIL: trust_score_snapshots count changed % → %',
      v_snap_count_before, v_snap_count_after;
  end if;
  if v_iou_score_before is distinct from v_iou_score_after then
    raise exception 'T10 FAIL: profiles.iou_score changed % → % for %',
      v_iou_score_before, v_iou_score_after, v_test_user_id;
  end if;
  if v_exposure_before is distinct from v_exposure_after then
    raise exception 'T10 FAIL: profiles.active_exposure_points changed % → % for %',
      v_exposure_before, v_exposure_after, v_test_user_id;
  end if;

  raise notice 'T10 PASS: all 6 immutability targets unchanged after canonical + view + get_my_current_trust_score() + get_trust_report_for_viewer()';

  -- ── T11: canonical function has 18 return columns ─────────────────────────
  if (
    select count(*)
    from information_schema.routines r
    join information_schema.parameters p
      on p.specific_name = r.specific_name
      and p.specific_schema = r.routine_schema
      and p.parameter_mode = 'OUT'
    where r.routine_schema = 'public'
      and r.routine_name   = 'score_v22_current_state_internal'
  ) <> 18 then
    raise exception 'T11 FAIL: score_v22_current_state_internal does not have 18 OUT columns';
  end if;
  raise notice 'T11 PASS: canonical function has 18 return columns';

  -- ── T12: score_v22_current_state_internal not callable by anon/authenticated
  if exists (
    select 1
    from   information_schema.role_routine_grants
    where  routine_schema = 'public'
      and  routine_name   = 'score_v22_current_state_internal'
      and  grantee in ('PUBLIC', 'anon', 'authenticated')
  ) then
    raise exception 'T12 FAIL: score_v22_current_state_internal granted to public/anon/authenticated';
  end if;
  raise notice 'T12 PASS: score_v22_current_state_internal restricted (not in public/anon/authenticated grants)';

  -- ── T13: get_my_current_trust_score() grants correct ─────────────────────
  if not exists (
    select 1
    from   information_schema.role_routine_grants
    where  routine_schema  = 'public'
      and  routine_name    = 'get_my_current_trust_score'
      and  grantee         = 'authenticated'
      and  privilege_type  = 'EXECUTE'
  ) then
    raise exception 'T13 FAIL: get_my_current_trust_score not granted to authenticated';
  end if;
  if exists (
    select 1
    from   information_schema.role_routine_grants
    where  routine_schema = 'public'
      and  routine_name   = 'get_my_current_trust_score'
      and  grantee in ('PUBLIC', 'anon')
  ) then
    raise exception 'T13 FAIL: get_my_current_trust_score callable by public or anon';
  end if;
  raise notice 'T13 PASS: get_my_current_trust_score granted to authenticated only';

  -- ── T14: score_v22_current_state_internal exists ──────────────────────────
  if not exists (
    select 1 from pg_proc p
    join   pg_namespace n on n.oid = p.pronamespace
    where  n.nspname = 'public' and p.proname = 'score_v22_current_state_internal'
  ) then
    raise exception 'T14 FAIL: score_v22_current_state_internal does not exist';
  end if;
  raise notice 'T14 PASS: score_v22_current_state_internal exists';

  -- ════════════════════════════════════════════════════════════════════════════
  -- SA1–SA5: BEHAVIORAL SECURITY TESTS
  -- Uses set_config('request.jwt.claims', ..., true) to simulate callers.
  -- auth.uid() reads from jwt claims 'sub'; no sub = null uid = 42501.
  -- All changes are rolled back at end of transaction.
  -- ════════════════════════════════════════════════════════════════════════════

  -- ── SA1: anon cannot execute get_my_current_trust_score() ─────────────────
  -- JWT without 'sub' → auth.uid() returns null → function raises 42501.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'anon')::text,
    true
  );
  v_denied := false;
  begin
    perform public.get_my_current_trust_score();
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'SA1 FAIL: anon was not denied get_my_current_trust_score()';
  end if;
  raise notice 'SA1 PASS: anon correctly denied get_my_current_trust_score()';

  -- ── SA2: authenticated JWT owner gets their own score ─────────────────────
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_test_user_id::text, 'role', 'authenticated')::text,
    true
  );
  select * into v_rpc from public.get_my_current_trust_score();

  if v_rpc is null or v_rpc.shadow_score is null then
    raise exception 'SA2 FAIL: get_my_current_trust_score() returned no row for JWT owner';
  end if;
  if v_rpc.shadow_score is distinct from v_canonical.shadow_score then
    raise exception 'SA2 FAIL: JWT owner score % != canonical %',
      v_rpc.shadow_score, v_canonical.shadow_score;
  end if;
  raise notice 'SA2 PASS: JWT owner gets own score %', v_rpc.shadow_score;

  -- ── SA3: authenticated user gets own score, not another user's ────────────
  -- The function always uses auth.uid() — there is no user-id parameter.
  -- Call as v_other_user_id; verify the returned score equals the canonical
  -- state for v_other_user_id, not for v_test_user_id.
  if v_other_user_id is not null then
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', v_other_user_id::text, 'role', 'authenticated')::text,
      true
    );
    select * into v_other_rpc   from public.get_my_current_trust_score();
    select * into v_other_canon from public.score_v22_current_state_internal(v_other_user_id);

    if v_other_rpc is null or v_other_rpc.shadow_score is null then
      raise exception 'SA3 FAIL: get_my_current_trust_score() returned no row for second user';
    end if;
    if v_other_rpc.shadow_score is distinct from v_other_canon.shadow_score then
      raise exception 'SA3 FAIL: second user score via RPC % != canonical %',
        v_other_rpc.shadow_score, v_other_canon.shadow_score;
    end if;
    -- prove the RPC is scoped to the caller's identity, not a fixed user
    -- (v_rpc was computed as v_test_user_id; v_other_rpc is now v_other_user_id's score)
    raise notice 'SA3 PASS: second user gets own score %; first user score was %',
      v_other_rpc.shadow_score, v_rpc.shadow_score;
  else
    raise notice 'SA3 SKIP: only one user with v2.2 contributions in DEV; cross-user isolation cannot be tested';
  end if;

  -- ── SA4: unauthorized viewer gets empty Trust Report ─────────────────────
  -- has_active_trust_report_share returns false when no share exists.
  -- get_trust_report_for_viewer returns 0 rows and logs access_denied.
  if v_other_user_id is not null then
    -- remove any pre-existing share from v_other_user_id → v_test_user_id
    -- (direction: v_other_user_id as viewer of v_test_user_id's report)
    delete from public.trust_report_shares
    where  owner_user_id  = v_other_user_id
      and  viewer_user_id = v_test_user_id;

    select count(*) into v_row_count
    from public.get_trust_report_for_viewer(v_other_user_id, v_test_user_id, 'summary');

    if v_row_count <> 0 then
      raise exception 'SA4 FAIL: unauthorized viewer got % row(s), expected 0', v_row_count;
    end if;
    raise notice 'SA4 PASS: unauthorized viewer correctly returned empty result';
  else
    raise notice 'SA4 SKIP: no second fixture user for Trust Report authorization test';
  end if;

  -- ── SA5: viewer with active share reads Trust Report ─────────────────────
  -- Insert a temporary share (rolled back with the transaction).
  if v_other_user_id is not null then
    insert into public.trust_report_shares (
      owner_user_id, viewer_user_id, scope
    ) values (v_other_user_id, v_test_user_id, 'summary');

    select count(*) into v_row_count
    from public.get_trust_report_for_viewer(v_other_user_id, v_test_user_id, 'summary');

    if v_row_count <> 1 then
      raise exception 'SA5 FAIL: authorized viewer got % rows, expected 1', v_row_count;
    end if;
    raise notice 'SA5 PASS: authorized viewer correctly received Trust Report';
  else
    raise notice 'SA5 SKIP: no second fixture user';
  end if;

  raise notice '';
  raise notice '=== Regression complete ===';
end;
$$;

rollback;
