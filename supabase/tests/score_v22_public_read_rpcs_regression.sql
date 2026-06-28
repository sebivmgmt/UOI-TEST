-- ============================================================================
-- Regression tests: Score v2.2 Public Read RPCs
-- DEV project only: colkilearqxuyldzjutw
--
-- Tests:
--   P1-P2    security: anon denied both RPCs
--   P3-P4    access: authenticated caller succeeds on both RPCs
--   P5-P6    correctness: all returned fields exactly match canonical function
--   P7       batch deduplication: duplicate IDs produce one row per user
--   P8-P9    edge cases: null and empty arrays return zero rows
--   P10-P11  edge cases: non-existent profile IDs return zero rows
--   P12      limit enforcement: arrays >100 IDs are rejected
--   P13-P18  read immutability: no mutations across any of the 6 evidence targets
--   P19      canonical function still unavailable directly to authenticated
--
-- All changes are rolled back — DEV state is not modified.
-- ============================================================================

begin;

do $$
declare
  -- primary fixture
  v_test_user_id    uuid;
  -- secondary fixture (for batch and dedup tests)
  v_other_user_id   uuid;
  -- guaranteed non-existent profile UUID
  v_nonexistent_id  uuid;

  -- results
  v_canonical       record;
  v_single          record;
  v_batch_row       record;

  -- immutability snapshots
  v_toe_before      bigint;
  v_toe_after       bigint;
  v_contrib_before  bigint;
  v_contrib_after   bigint;
  v_agree_before    bigint;
  v_agree_after     bigint;
  v_snap_before     bigint;
  v_snap_after      bigint;
  v_iou_score_before    integer;
  v_iou_score_after     integer;
  v_exposure_before     integer;
  v_exposure_after      integer;

  -- helpers
  v_denied      boolean;
  v_row_count   integer;
  v_count       integer;
begin

  -- ── resolve fixtures ──────────────────────────────────────────────────────
  select sc.user_id
  into   v_test_user_id
  from   public.score_v2_contributions sc
  where  sc.model_key     = 'iou_score'
    and  sc.model_version = 'v2.2-shadow'
  group  by sc.user_id
  order  by count(*) desc
  limit  1;

  if v_test_user_id is null then
    raise exception 'SETUP FAIL: no v2.2-shadow contributions. Seed fixture data before running.';
  end if;

  select sc.user_id
  into   v_other_user_id
  from   public.score_v2_contributions sc
  where  sc.model_key     = 'iou_score'
    and  sc.model_version = 'v2.2-shadow'
    and  sc.user_id       <> v_test_user_id
  group  by sc.user_id
  order  by count(*) desc
  limit  1;

  -- A UUID guaranteed not to be a profile — random in UUIDv4 space
  v_nonexistent_id := gen_random_uuid();
  while exists (select 1 from public.profiles p where p.id = v_nonexistent_id) loop
    v_nonexistent_id := gen_random_uuid();
  end loop;

  -- ── P1: anon denied get_public_iou_score_v22 ─────────────────────────────
  -- JWT without 'sub' → auth.uid() returns null → 42501
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'anon')::text,
    true
  );
  v_denied := false;
  begin
    perform public.get_public_iou_score_v22(v_test_user_id);
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'P1 FAIL: anon was not denied get_public_iou_score_v22';
  end if;
  raise notice 'P1 PASS: anon denied get_public_iou_score_v22';

  -- ── P2: anon denied get_public_iou_scores_v22 ────────────────────────────
  v_denied := false;
  begin
    perform public.get_public_iou_scores_v22(array[v_test_user_id]);
  exception when insufficient_privilege then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'P2 FAIL: anon was not denied get_public_iou_scores_v22';
  end if;
  raise notice 'P2 PASS: anon denied get_public_iou_scores_v22';

  -- ── P3: authenticated can call get_public_iou_score_v22 ──────────────────
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_test_user_id::text, 'role', 'authenticated')::text,
    true
  );
  select * into v_single from public.get_public_iou_score_v22(v_test_user_id);
  if v_single is null then
    raise exception 'P3 FAIL: get_public_iou_score_v22 returned no row for existing user';
  end if;
  raise notice 'P3 PASS: authenticated got single result, public_score=%', v_single.public_score;

  -- ── P4: authenticated can call get_public_iou_scores_v22 ─────────────────
  select count(*) into v_row_count
  from public.get_public_iou_scores_v22(array[v_test_user_id]);
  if v_row_count <> 1 then
    raise exception 'P4 FAIL: get_public_iou_scores_v22 returned % rows for 1 existing ID', v_row_count;
  end if;
  raise notice 'P4 PASS: authenticated got % row(s) from batch RPC', v_row_count;

  -- ── P5: single RPC — all 6 returned fields match canonical function ────────
  select * into v_canonical from public.score_v22_current_state_internal(v_test_user_id);

  if v_single.user_id is distinct from v_test_user_id then
    raise exception 'P5 FAIL: single.user_id % != test user %', v_single.user_id, v_test_user_id;
  end if;
  if v_single.model_version is distinct from v_canonical.model_version then
    raise exception 'P5 FAIL: single.model_version % != canonical %',
      v_single.model_version, v_canonical.model_version;
  end if;
  if v_single.public_score is distinct from v_canonical.shadow_score then
    raise exception 'P5 FAIL: single.public_score % != canonical.shadow_score %',
      v_single.public_score, v_canonical.shadow_score;
  end if;
  if v_single.visible_trust is distinct from v_canonical.visible_trust then
    raise exception 'P5 FAIL: single.visible_trust % != canonical %',
      v_single.visible_trust, v_canonical.visible_trust;
  end if;
  if v_single.trust_tier is distinct from v_canonical.trust_tier then
    raise exception 'P5 FAIL: single.trust_tier % != canonical %',
      v_single.trust_tier, v_canonical.trust_tier;
  end if;
  if v_single.active_exposure_points is distinct from v_canonical.active_exposure_points then
    raise exception 'P5 FAIL: single.active_exposure_points % != canonical %',
      v_single.active_exposure_points, v_canonical.active_exposure_points;
  end if;
  raise notice 'P5 PASS: all 6 single-RPC fields exactly match canonical (score=%)',
    v_single.public_score;

  -- ── P6: batch RPC — result for test user matches canonical ────────────────
  select * into v_batch_row
  from public.get_public_iou_scores_v22(array[v_test_user_id])
  where user_id = v_test_user_id;

  if v_batch_row is null then
    raise exception 'P6 FAIL: batch RPC returned no row for test user';
  end if;
  if v_batch_row.public_score is distinct from v_canonical.shadow_score then
    raise exception 'P6 FAIL: batch.public_score % != canonical %',
      v_batch_row.public_score, v_canonical.shadow_score;
  end if;
  if v_batch_row.visible_trust is distinct from v_canonical.visible_trust then
    raise exception 'P6 FAIL: batch.visible_trust % != canonical %',
      v_batch_row.visible_trust, v_canonical.visible_trust;
  end if;
  if v_batch_row.trust_tier is distinct from v_canonical.trust_tier then
    raise exception 'P6 FAIL: batch.trust_tier % != canonical %',
      v_batch_row.trust_tier, v_canonical.trust_tier;
  end if;
  if v_batch_row.active_exposure_points is distinct from v_canonical.active_exposure_points then
    raise exception 'P6 FAIL: batch.active_exposure_points % != canonical %',
      v_batch_row.active_exposure_points, v_canonical.active_exposure_points;
  end if;
  raise notice 'P6 PASS: all batch-RPC fields match canonical for test user';

  -- ── P7: duplicate IDs produce one row per user ────────────────────────────
  -- Send v_test_user_id three times; expect exactly one row back.
  select count(*) into v_row_count
  from public.get_public_iou_scores_v22(
    array[v_test_user_id, v_test_user_id, v_test_user_id]
  );
  if v_row_count <> 1 then
    raise exception 'P7 FAIL: 3 duplicate IDs returned % rows, expected 1', v_row_count;
  end if;
  raise notice 'P7 PASS: 3 duplicate IDs collapsed to 1 row';

  -- ── P8: null array returns zero rows ─────────────────────────────────────
  select count(*) into v_row_count
  from public.get_public_iou_scores_v22(null::uuid[]);
  if v_row_count <> 0 then
    raise exception 'P8 FAIL: null array returned % rows, expected 0', v_row_count;
  end if;
  raise notice 'P8 PASS: null array returned 0 rows';

  -- ── P9: empty array returns zero rows ────────────────────────────────────
  select count(*) into v_row_count
  from public.get_public_iou_scores_v22(array[]::uuid[]);
  if v_row_count <> 0 then
    raise exception 'P9 FAIL: empty array returned % rows, expected 0', v_row_count;
  end if;
  raise notice 'P9 PASS: empty array returned 0 rows';

  -- ── P10: non-existent ID returns zero rows (single RPC) ───────────────────
  select count(*) into v_row_count
  from public.get_public_iou_score_v22(v_nonexistent_id);
  if v_row_count <> 0 then
    raise exception 'P10 FAIL: non-existent ID returned % rows from single RPC', v_row_count;
  end if;
  raise notice 'P10 PASS: non-existent ID returns 0 rows from single RPC';

  -- ── P11: non-existent ID excluded from batch results ─────────────────────
  select count(*) into v_row_count
  from public.get_public_iou_scores_v22(
    array[v_test_user_id, v_nonexistent_id]
  );
  if v_row_count <> 1 then
    raise exception 'P11 FAIL: batch with 1 real + 1 fake ID returned % rows, expected 1', v_row_count;
  end if;
  raise notice 'P11 PASS: non-existent ID excluded from batch result';

  -- ── P12: array with >100 IDs is rejected ─────────────────────────────────
  v_denied := false;
  begin
    perform public.get_public_iou_scores_v22(
      array_fill(v_test_user_id, array[101])
    );
  exception when invalid_parameter_value then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'P12 FAIL: 101-element array was not rejected';
  end if;
  raise notice 'P12 PASS: 101-element array rejected with invalid_parameter_value';

  -- ════════════════════════════════════════════════════════════════════════════
  -- P13–P18: READ IMMUTABILITY
  -- Verify that executing both public RPCs (and the canonical function they
  -- delegate to) leaves all 6 evidence targets completely unchanged.
  -- ════════════════════════════════════════════════════════════════════════════

  select count(*) into v_toe_before    from public.trust_outcome_events;
  select count(*) into v_contrib_before from public.score_v2_contributions;
  select count(*) into v_agree_before  from public.score_agreements;
  select count(*) into v_snap_before   from public.trust_score_snapshots;
  select p.iou_score, p.active_exposure_points
  into   v_iou_score_before, v_exposure_before
  from   public.profiles p
  where  p.id = v_test_user_id;

  -- Execute both RPCs for the test user (canonical function is called internally)
  perform public.get_public_iou_score_v22(v_test_user_id);
  perform public.get_public_iou_scores_v22(array[v_test_user_id]);
  if v_other_user_id is not null then
    perform public.get_public_iou_scores_v22(array[v_test_user_id, v_other_user_id]);
  end if;

  select count(*) into v_toe_after    from public.trust_outcome_events;
  select count(*) into v_contrib_after from public.score_v2_contributions;
  select count(*) into v_agree_after  from public.score_agreements;
  select count(*) into v_snap_after   from public.trust_score_snapshots;
  select p.iou_score, p.active_exposure_points
  into   v_iou_score_after, v_exposure_after
  from   public.profiles p
  where  p.id = v_test_user_id;

  if v_toe_before != v_toe_after then
    raise exception 'P13 FAIL: trust_outcome_events changed % → %', v_toe_before, v_toe_after;
  end if;
  raise notice 'P13 PASS: trust_outcome_events unchanged (count=%)', v_toe_after;

  if v_contrib_before != v_contrib_after then
    raise exception 'P14 FAIL: score_v2_contributions changed % → %', v_contrib_before, v_contrib_after;
  end if;
  raise notice 'P14 PASS: score_v2_contributions unchanged (count=%)', v_contrib_after;

  if v_agree_before != v_agree_after then
    raise exception 'P15 FAIL: score_agreements changed % → %', v_agree_before, v_agree_after;
  end if;
  raise notice 'P15 PASS: score_agreements unchanged (count=%)', v_agree_after;

  if v_snap_before != v_snap_after then
    raise exception 'P16 FAIL: trust_score_snapshots changed % → %', v_snap_before, v_snap_after;
  end if;
  raise notice 'P16 PASS: trust_score_snapshots unchanged (count=%)', v_snap_after;

  if v_iou_score_before is distinct from v_iou_score_after then
    raise exception 'P17 FAIL: profiles.iou_score changed % → % for %',
      v_iou_score_before, v_iou_score_after, v_test_user_id;
  end if;
  raise notice 'P17 PASS: profiles.iou_score unchanged (=%)', v_iou_score_after;

  if v_exposure_before is distinct from v_exposure_after then
    raise exception 'P18 FAIL: profiles.active_exposure_points changed % → % for %',
      v_exposure_before, v_exposure_after, v_test_user_id;
  end if;
  raise notice 'P18 PASS: profiles.active_exposure_points unchanged (=%)', v_exposure_after;

  -- ── P19: canonical function still not directly accessible to authenticated ─
  -- Verified via grant table — the test session runs as postgres (superuser)
  -- so grant-level denial cannot be exercised directly; the grant state is
  -- the authoritative check.
  select count(*) into v_count
  from information_schema.role_routine_grants
  where routine_schema = 'public'
    and routine_name   = 'score_v22_current_state_internal'
    and grantee in ('PUBLIC', 'anon', 'authenticated')
    and privilege_type = 'EXECUTE';

  if v_count <> 0 then
    raise exception 'P19 FAIL: score_v22_current_state_internal is granted to PUBLIC/anon/authenticated (count=%)', v_count;
  end if;
  raise notice 'P19 PASS: score_v22_current_state_internal remains restricted from PUBLIC/anon/authenticated';

  raise notice '';
  raise notice '=== P1–P19 passed ===';
end;
$$;

rollback;
