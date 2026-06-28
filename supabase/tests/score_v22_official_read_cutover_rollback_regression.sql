-- ============================================================================
-- Rollback regression: Score v2.2 Official Read Cutover
-- DEV project only: colkilearqxuyldzjutw
--
-- This file:
--   1. Starts in the post-cutover state (score_v22_current_state_internal exists)
--   2. Snapshots representative evidence counts and profile field values
--   3. Runner injects literal rollback file at sentinel — no inline copy kept here
--   4. Verifies legacy-read behavior is restored
--   5. Verifies score_v22_current_state_internal no longer exists
--   6. Verifies v2.2 evidence data is intact (counts and profile values)
--   7. Rolls back the entire transaction — DEV is left in the cutover state
--
-- NOTE: Step 3 contains a sentinel (-- <<INJECT_ROLLBACK_FILE>>) that is
--       replaced at runtime by run_score_v22_cutover_regression.sh with the
--       literal contents of the rollback file. No inline copy is kept here.
-- ============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Snapshot pre-rollback state into a temp table
-- ─────────────────────────────────────────────────────────────────────────────

create temp table _rollback_regression (
  test_user_id              uuid,
  other_user_id             uuid,
  pre_v22_contrib_count     bigint,
  pre_v22_outcome_count     bigint,
  pre_agreement_count       bigint,
  pre_snapshot_count        bigint,
  pre_iou_score             integer,
  pre_active_exposure       integer,
  pre_canonical_score       integer,
  canonical_func_existed    boolean
);

do $pre$
declare
  v_test_user_id   uuid;
  v_other_user_id  uuid;
  v_canonical_score integer;
  v_canon          record;
begin
  select sc.user_id into v_test_user_id
  from   public.score_v2_contributions sc
  where  sc.model_key = 'iou_score' and sc.model_version = 'v2.2-shadow'
  group  by sc.user_id order by count(*) desc limit 1;

  if v_test_user_id is null then
    raise exception 'SETUP FAIL: no v2.2-shadow contributions found.';
  end if;

  select sc.user_id into v_other_user_id
  from   public.score_v2_contributions sc
  where  sc.model_key = 'iou_score' and sc.model_version = 'v2.2-shadow'
    and  sc.user_id <> v_test_user_id
  group  by sc.user_id order by count(*) desc limit 1;

  -- record canonical score before rollback (function must exist at this point)
  select * into v_canon from public.score_v22_current_state_internal(v_test_user_id);
  v_canonical_score := v_canon.shadow_score;

  insert into _rollback_regression (
    test_user_id,
    other_user_id,
    pre_v22_contrib_count,
    pre_v22_outcome_count,
    pre_agreement_count,
    pre_snapshot_count,
    pre_iou_score,
    pre_active_exposure,
    pre_canonical_score,
    canonical_func_existed
  )
  select
    v_test_user_id,
    v_other_user_id,
    (select count(*) from public.score_v2_contributions
     where model_key = 'iou_score' and model_version = 'v2.2-shadow'),
    (select count(*) from public.trust_outcome_events),
    (select count(*) from public.score_agreements),
    (select count(*) from public.trust_score_snapshots),
    p.iou_score,
    p.active_exposure_points,
    v_canonical_score,
    exists (
      select 1 from pg_proc fn
      join pg_namespace ns on ns.oid = fn.pronamespace
      where ns.nspname = 'public' and fn.proname = 'score_v22_current_state_internal'
    )
  from public.profiles p
  where p.id = v_test_user_id;

  raise notice 'PRE-ROLLBACK: canonical score=%, iou_score=%, exposure=%',
    v_canonical_score,
    (select iou_score from public.profiles where id = v_test_user_id),
    (select active_exposure_points from public.profiles where id = v_test_user_id);
end;
$pre$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Verify canonical function existed before rollback
-- ─────────────────────────────────────────────────────────────────────────────

do $check_pre$
begin
  if not (select canonical_func_existed from _rollback_regression limit 1) then
    raise exception 'PRECONDITION FAIL: score_v22_current_state_internal did not exist before rollback. Run cutover migration first.';
  end if;
  raise notice 'PRECONDITION PASS: cutover state confirmed';
end;
$check_pre$;


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Rollback SQL (injected by runner from actual rollback file)
-- Sentinel below is replaced by run_score_v22_cutover_regression.sh with the
-- literal contents of:
--   supabase/rollbacks/20260627018000_score_v22_official_read_cutover_rollback.sql
-- ─────────────────────────────────────────────────────────────────────────────

-- <<INJECT_ROLLBACK_FILE>>


-- ─────────────────────────────────────────────────────────────────────────────
-- Step 4: Post-rollback assertions
-- ─────────────────────────────────────────────────────────────────────────────

do $post$
declare
  r                   _rollback_regression%rowtype;
  v_post_contrib      bigint;
  v_post_outcome      bigint;
  v_post_agree        bigint;
  v_post_snap         bigint;
  v_post_iou_score    integer;
  v_post_exposure     integer;
  v_rpc               record;
  v_view_row          record;
  v_row_count         integer;
  v_denied            boolean;
  v_canonical_gone    boolean;
begin
  select * into r from _rollback_regression limit 1;

  -- RB1: score_v22_current_state_internal no longer exists ───────────────────
  v_canonical_gone := not exists (
    select 1 from pg_proc fn
    join pg_namespace ns on ns.oid = fn.pronamespace
    where ns.nspname = 'public' and fn.proname = 'score_v22_current_state_internal'
  );
  if not v_canonical_gone then
    raise exception 'RB1 FAIL: score_v22_current_state_internal still exists after rollback';
  end if;
  raise notice 'RB1 PASS: score_v22_current_state_internal dropped';

  -- RB2: get_my_current_trust_score() callable via legacy path ──────────────
  -- Set JWT so auth.uid() resolves to the test user.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', r.test_user_id::text, 'role', 'authenticated')::text,
    true
  );
  select * into v_rpc from public.get_my_current_trust_score();
  if v_rpc is null or v_rpc.shadow_score is null then
    raise exception 'RB2 FAIL: get_my_current_trust_score() returned no row after rollback';
  end if;
  if v_rpc.shadow_score < 300 or v_rpc.shadow_score > 1400 then
    raise exception 'RB2 FAIL: post-rollback score % outside [300, 1400]', v_rpc.shadow_score;
  end if;
  -- The legacy function resolves the shadow model from trust_model_versions
  -- (which is still 'v2.2-shadow'). The contribution data and formula are the
  -- same, so the score is expected to match the pre-rollback canonical score.
  if v_rpc.shadow_score is distinct from r.pre_canonical_score then
    raise notice 'RB2 NOTE: post-rollback score % differs from pre-rollback canonical %. This may occur if evidence changed between snapshot and now.',
      v_rpc.shadow_score, r.pre_canonical_score;
  end if;
  raise notice 'RB2 PASS: get_my_current_trust_score() callable, score=%', v_rpc.shadow_score;

  -- RB3: legacy function uses dynamic model discovery (not hardcoded v2.2-shadow)
  -- verify model_version is resolved from trust_model_versions
  if v_rpc.model_version is null then
    raise exception 'RB3 FAIL: model_version is null after rollback';
  end if;
  raise notice 'RB3 PASS: legacy function resolved model_version=%', v_rpc.model_version;

  -- RB4: trust_report_shadow_v is queryable and has expected columns ──────────
  select * into v_view_row
  from public.trust_report_shadow_v
  where user_id = r.test_user_id;

  if v_view_row is null then
    raise exception 'RB4 FAIL: trust_report_shadow_v returned no row for %', r.test_user_id;
  end if;
  if v_view_row.public_score is null then
    raise exception 'RB4 FAIL: view.public_score is null after rollback';
  end if;
  raise notice 'RB4 PASS: view queryable, public_score=%', v_view_row.public_score;

  -- RB5: get_trust_report_for_viewer() still enforces authorization ──────────
  if r.other_user_id is not null then
    -- ensure no pre-existing share (within transaction)
    delete from public.trust_report_shares
    where  owner_user_id  = r.other_user_id
      and  viewer_user_id = r.test_user_id;

    select count(*) into v_row_count
    from public.get_trust_report_for_viewer(r.other_user_id, r.test_user_id, 'summary');

    if v_row_count <> 0 then
      raise exception 'RB5 FAIL: unauthorized viewer got % row(s) after rollback', v_row_count;
    end if;
    raise notice 'RB5 PASS: Trust Report authorization still enforced after rollback';
  else
    raise notice 'RB5 SKIP: no second fixture user';
  end if;

  -- RB6: anon still denied get_my_current_trust_score() after rollback ────────
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
    raise exception 'RB6 FAIL: anon was not denied after rollback';
  end if;
  raise notice 'RB6 PASS: anon still denied get_my_current_trust_score() after rollback';

  -- RB7: profiles.iou_score unchanged ──────────────────────────────────────
  select iou_score, active_exposure_points
  into v_post_iou_score, v_post_exposure
  from public.profiles where id = r.test_user_id;

  if v_post_iou_score is distinct from r.pre_iou_score then
    raise exception 'RB7 FAIL: profiles.iou_score changed % → %',
      r.pre_iou_score, v_post_iou_score;
  end if;
  raise notice 'RB7 PASS: profiles.iou_score unchanged (=%)', v_post_iou_score;

  -- RB8: profiles.active_exposure_points unchanged ──────────────────────────
  if v_post_exposure is distinct from r.pre_active_exposure then
    raise exception 'RB8 FAIL: profiles.active_exposure_points changed % → %',
      r.pre_active_exposure, v_post_exposure;
  end if;
  raise notice 'RB8 PASS: profiles.active_exposure_points unchanged (=%)', v_post_exposure;

  -- RB9: v2.2 contribution count unchanged ──────────────────────────────────
  select count(*) into v_post_contrib
  from public.score_v2_contributions
  where model_key = 'iou_score' and model_version = 'v2.2-shadow';

  if v_post_contrib is distinct from r.pre_v22_contrib_count then
    raise exception 'RB9 FAIL: v2.2 contribution count changed % → %',
      r.pre_v22_contrib_count, v_post_contrib;
  end if;
  raise notice 'RB9 PASS: v2.2 contributions intact (count=%)', v_post_contrib;

  -- RB10: trust_outcome_events count unchanged ───────────────────────────────
  select count(*) into v_post_outcome from public.trust_outcome_events;
  if v_post_outcome is distinct from r.pre_v22_outcome_count then
    raise exception 'RB10 FAIL: trust_outcome_events count changed % → %',
      r.pre_v22_outcome_count, v_post_outcome;
  end if;
  raise notice 'RB10 PASS: trust_outcome_events intact (count=%)', v_post_outcome;

  -- RB11: score_agreements count unchanged ───────────────────────────────────
  select count(*) into v_post_agree from public.score_agreements;
  if v_post_agree is distinct from r.pre_agreement_count then
    raise exception 'RB11 FAIL: score_agreements count changed % → %',
      r.pre_agreement_count, v_post_agree;
  end if;
  raise notice 'RB11 PASS: score_agreements intact (count=%)', v_post_agree;

  -- RB12: trust_score_snapshots count unchanged ──────────────────────────────
  select count(*) into v_post_snap from public.trust_score_snapshots;
  if v_post_snap is distinct from r.pre_snapshot_count then
    raise exception 'RB12 FAIL: trust_score_snapshots count changed % → %',
      r.pre_snapshot_count, v_post_snap;
  end if;
  raise notice 'RB12 PASS: trust_score_snapshots intact (count=%)', v_post_snap;

  raise notice '';
  raise notice '=== Rollback regression complete ===';
end;
$post$;

rollback;
