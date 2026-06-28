-- ============================================================================
-- Score v2.2 official cutover-readiness audit
-- READ ONLY. DEV ONLY.
--
-- Returns one JSON document containing:
--   * every DEV profile's legacy score, computed v2.2 score, difference,
--     Visible Trust, and active exposure
--   * missing/duplicate/malformed score agreements
--   * paid payments missing outcome evidence
--   * expected v2.2 contributions missing from outcome evidence
--   * broken correction edges/chains
--   * historical agreement events requiring backfill
--   * explicit per-user and global blockers
--   * final safe_to_cut_over result
--
-- Run only with:
--   node scripts/run-score-v22-sql.mjs --read-only <this-file>
-- ============================================================================

with recursive
audit_clock as (
  select
    now() as as_of,
    now() - interval '2 years' as evidence_cutoff
),

model_state as (
  select
    count(*) filter (
      where model_key = 'iou_score'
        and status = 'shadow'
    )::integer as shadow_count,
    count(*) filter (
      where model_key = 'iou_score'
        and version = 'v2.2-shadow'
        and status = 'shadow'
    )::integer as v22_shadow_count,
    count(*) filter (
      where model_key = 'iou_score'
        and version = 'v2.2-shadow'
    )::integer as v22_registry_count,
    max(
      coalesce((config ->> 'base_score')::integer, 700)
    ) filter (
      where model_key = 'iou_score'
        and version = 'v2.2-shadow'
    )::integer as v22_base_score
  from public.trust_model_versions
),

dispatch_state as (
  select
    count(*) filter (
      where p.proname = 'score_v22_dispatch_outcome_event'
        and t.tgenabled <> 'D'
    )::integer as v22_dispatch_count,
    count(*) filter (
      where p.proname = 'trg_score_v2_shadow_on_outcome'
        and t.tgenabled <> 'D'
    )::integer as legacy_dispatch_count
  from pg_trigger as t
  join pg_proc as p
    on p.oid = t.tgfoid
  where t.tgrelid = 'public.trust_outcome_events'::regclass
    and not t.tgisinternal
),

required_indexes(index_name) as (
  values
    ('score_agreements_personal_iou_source_unique'),
    ('trust_outcome_events_payment_per_agreement_unique'),
    ('trust_outcome_events_one_successor_uidx'),
    ('trust_outcome_events_correction_key_uidx'),
    ('score_v2_contributions_event_type_version_unique'),
    ('score_v2_contributions_v22_completion_uidx')
),

required_index_state as (
  select
    r.index_name,
    coalesce(i.indisvalid, false) as is_valid,
    coalesce(i.indisready, false) as is_ready
  from required_indexes as r
  left join pg_class as idx
    on idx.relname = r.index_name
  left join pg_namespace as ns
    on ns.oid = idx.relnamespace
   and ns.nspname = 'public'
  left join pg_index as i
    on i.indexrelid = idx.oid
),

redundant_index_warnings as (
  select jsonb_build_object(
    'warning_code', 'redundant_contribution_uniqueness_indexes',
    'indexes', jsonb_agg(index_name order by index_name)
  ) as warning
  from (
    select indexname as index_name
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'score_v2_contributions'
      and indexname in (
        'score_v2_contributions_event_type_model_uidx',
        'score_v2_contributions_event_type_version_unique'
      )
  ) as x
  having count(*) > 1
),

computed_exposure as (
  select
    p.id as user_id,
    least(
      70,
      greatest(
        0,
        coalesce(
          sum(
            greatest(0, coalesce(i.exposure_points, 0))
          ) filter (
            where i.id is not null
              and i.activated_at is not null
              and i.deleted_at is null
              and i.archived_at is null
              and i.status in ('open', 'late')
          ),
          0
        )
      )
    )::integer as active_exposure
  from public.profiles as p
  left join public.ious as i
    on i.borrower_id = p.id
  group by p.id
),

v22_contribution_totals as (
  select
    sc.user_id,
    coalesce(
      sum(
        case
          when sc.impact_direction = 'penalty'
            then -sc.points_awarded
          else sc.points_awarded
        end
      ),
      0
    )::integer as v22_contribution_total
  from public.score_v2_contributions as sc
  join public.trust_outcome_events as toe
    on toe.id = sc.outcome_event_id
  cross join audit_clock as c
  where sc.model_key = 'iou_score'
    and sc.model_version = 'v2.2-shadow'
    and toe.outcome_at > c.evidence_cutoff
    and toe.created_at <= c.as_of
    and sc.calculated_at <= c.as_of
    and not exists (
      select 1
      from public.trust_outcome_events as child
      where child.supersedes_outcome_event_id = toe.id
        and child.created_at <= c.as_of
    )
  group by sc.user_id
),

user_scores_raw as (
  select
    p.id as user_id,
    p.email,
    coalesce(p.iou_score, 700)::integer as legacy_public_score,
    coalesce(p.active_exposure_points, 0)::integer as stored_active_exposure,
    ce.active_exposure,
    coalesce(vct.v22_contribution_total, 0)::integer
      as v22_contribution_total
  from public.profiles as p
  join computed_exposure as ce
    on ce.user_id = p.id
  left join v22_contribution_totals as vct
    on vct.user_id = p.id
),

user_scores as (
  select
    u.*,
    greatest(
      300,
      least(1400, 700 + u.v22_contribution_total)
    )::integer as score_v22
  from user_scores_raw as u
),

user_score_output as (
  select
    u.*,
    (u.score_v22 - u.legacy_public_score)::integer as score_difference,
    greatest(
      300,
      u.score_v22 - greatest(0, coalesce(u.active_exposure, 0))
    )::integer as visible_trust
  from user_scores as u
),

iou_payment_totals as (
  select
    i.id as iou_id,
    coalesce(
      sum(p.amount_cents) filter (
        where p.paid_at is not null
           or p.confirmed_paid_at is not null
           or p.status = 'paid'
      ),
      0
    )::bigint as paid_cents
  from public.ious as i
  left join public.payments as p
    on p.iou_id = i.id
  group by i.id
),

iou_scope as (
  select
    i.*,
    coalesce(pt.paid_cents, 0)::bigint as paid_cents
  from public.ious as i
  left join iou_payment_totals as pt
    on pt.iou_id = i.id
  where i.activated_at is not null
     or i.status in ('open', 'late', 'paid', 'archived')
     or coalesce(pt.paid_cents, 0) > 0
     or exists (
       select 1
       from public.score_agreements as sa
       where sa.source_type = 'personal_iou'
         and sa.source_id = i.id
     )
),

agreement_rollup as (
  select
    sa.source_id as iou_id,
    count(*)::integer as agreement_count,
    array_agg(sa.id order by sa.id) as agreement_ids
  from public.score_agreements as sa
  where sa.source_type = 'personal_iou'
    and sa.source_id is not null
  group by sa.source_id
),

agreement_issues as (
  select
    i.borrower_id as user_id,
    'missing_score_agreement'::text as issue_code,
    'iou'::text as entity_type,
    i.id::text as entity_id,
    true as is_blocker,
    true as requires_backfill,
    jsonb_build_object(
      'iou_id', i.id,
      'status', i.status,
      'activated_at', i.activated_at,
      'principal_cents', i.principal_cents
    ) as details
  from iou_scope as i
  left join agreement_rollup as ar
    on ar.iou_id = i.id
  where coalesce(ar.agreement_count, 0) = 0

  union all

  select
    i.borrower_id,
    'duplicate_score_agreements',
    'iou',
    i.id::text,
    true,
    false,
    jsonb_build_object(
      'iou_id', i.id,
      'agreement_count', ar.agreement_count,
      'agreement_ids', to_jsonb(ar.agreement_ids)
    )
  from iou_scope as i
  join agreement_rollup as ar
    on ar.iou_id = i.id
  where ar.agreement_count > 1

  union all

  select
    sa.user_id,
    'orphan_personal_iou_score_agreement',
    'score_agreement',
    sa.id::text,
    true,
    true,
    jsonb_build_object(
      'score_agreement_id', sa.id,
      'source_id', sa.source_id,
      'status', sa.status
    )
  from public.score_agreements as sa
  left join public.ious as i
    on i.id = sa.source_id
  where sa.source_type = 'personal_iou'
    and (
      sa.source_id is null
      or i.id is null
    )

  union all

  select
    sa.user_id,
    'score_agreement_subject_mismatch',
    'score_agreement',
    sa.id::text,
    true,
    false,
    jsonb_build_object(
      'score_agreement_id', sa.id,
      'iou_id', i.id,
      'agreement_user_id', sa.user_id,
      'iou_borrower_id', i.borrower_id
    )
  from public.score_agreements as sa
  join public.ious as i
    on i.id = sa.source_id
  where sa.source_type = 'personal_iou'
    and sa.user_id is distinct from i.borrower_id

  union all

  select
    sa.user_id,
    'score_agreement_counterparty_mismatch',
    'score_agreement',
    sa.id::text,
    true,
    false,
    jsonb_build_object(
      'score_agreement_id', sa.id,
      'iou_id', i.id,
      'agreement_counterparty_id', sa.counterparty_id,
      'iou_lender_id', i.lender_id
    )
  from public.score_agreements as sa
  join public.ious as i
    on i.id = sa.source_id
  where sa.source_type = 'personal_iou'
    and sa.counterparty_id is distinct from i.lender_id

  union all

  select
    sa.user_id,
    'score_agreement_amount_mismatch',
    'score_agreement',
    sa.id::text,
    true,
    false,
    jsonb_build_object(
      'score_agreement_id', sa.id,
      'iou_id', i.id,
      'agreement_amount_cents', sa.amount_cents,
      'iou_principal_cents', i.principal_cents
    )
  from public.score_agreements as sa
  join public.ious as i
    on i.id = sa.source_id
  where sa.source_type = 'personal_iou'
    and sa.amount_cents is distinct from i.principal_cents
),

agreement_anchors as (
  select
    sa.id as score_agreement_id,
    sa.user_id,
    sa.counterparty_id,
    sa.source_id as iou_id,
    sa.amount_cents as principal_cents,
    coalesce(sa.activated_at, sa.created_at, 'epoch'::timestamptz) as anchor_at
  from public.score_agreements as sa
  join public.ious as i
    on i.id = sa.source_id
   and i.borrower_id = sa.user_id
   and i.lender_id = sa.counterparty_id
  where sa.source_type = 'personal_iou'
    and sa.amount_cents > 0
),

agreement_pair_index as (
  select
    a.*,
    (
      select count(*)::integer
      from agreement_anchors as prior
      where prior.user_id = a.user_id
        and prior.counterparty_id = a.counterparty_id
        and prior.anchor_at > a.anchor_at - interval '2 years'
        and (
          prior.anchor_at < a.anchor_at
          or (
            prior.anchor_at = a.anchor_at
            and prior.score_agreement_id::text
                <= a.score_agreement_id::text
          )
        )
    )::integer as pair_index
  from agreement_anchors as a
),

agreement_math as (
  select
    a.*,
    public.score_v22_ceiling_for_pair_index(
      a.principal_cents,
      greatest(a.pair_index, 1)
    )::integer as agreement_ceiling
  from agreement_pair_index as a
),

paid_payments as (
  select
    p.*,
    i.borrower_id,
    i.lender_id,
    sa.id as score_agreement_id
  from public.payments as p
  join public.ious as i
    on i.id = p.iou_id
  left join public.score_agreements as sa
    on sa.source_type = 'personal_iou'
   and sa.source_id = i.id
   and sa.user_id = i.borrower_id
  where p.paid_at is not null
     or p.confirmed_paid_at is not null
     or p.status = 'paid'
),

root_payment_outcome_counts as (
  select
    toe.score_agreement_id,
    public.score_v22_event_payment_id(to_jsonb(toe)) as payment_id,
    count(*)::integer as root_outcome_count,
    array_agg(toe.id order by toe.created_at, toe.id) as outcome_ids
  from public.trust_outcome_events as toe
  where toe.outcome_type in (
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late'
    )
    and toe.supersedes_outcome_event_id is null
  group by
    toe.score_agreement_id,
    public.score_v22_event_payment_id(to_jsonb(toe))
),

payment_issues as (
  select
    p.borrower_id as user_id,
    'paid_payment_missing_outcome'::text as issue_code,
    'payment'::text as entity_type,
    p.id::text as entity_id,
    true as is_blocker,
    true as requires_backfill,
    jsonb_build_object(
      'payment_id', p.id,
      'iou_id', p.iou_id,
      'score_agreement_id', p.score_agreement_id,
      'status', p.status,
      'paid_at', p.paid_at,
      'confirmed_paid_at', p.confirmed_paid_at,
      'amount_cents', p.amount_cents
    ) as details
  from paid_payments as p
  left join root_payment_outcome_counts as oc
    on oc.score_agreement_id = p.score_agreement_id
   and oc.payment_id = p.id
  where p.score_agreement_id is null
     or coalesce(oc.root_outcome_count, 0) = 0

  union all

  select
    p.borrower_id,
    'paid_payment_has_duplicate_root_outcomes',
    'payment',
    p.id::text,
    true,
    false,
    jsonb_build_object(
      'payment_id', p.id,
      'iou_id', p.iou_id,
      'score_agreement_id', p.score_agreement_id,
      'root_outcome_count', oc.root_outcome_count,
      'outcome_ids', to_jsonb(oc.outcome_ids)
    )
  from paid_payments as p
  join root_payment_outcome_counts as oc
    on oc.score_agreement_id = p.score_agreement_id
   and oc.payment_id = p.id
  where oc.root_outcome_count > 1

  union all

  select
    p.borrower_id,
    'paid_payment_missing_paid_timestamp',
    'payment',
    p.id::text,
    true,
    true,
    jsonb_build_object(
      'payment_id', p.id,
      'iou_id', p.iou_id,
      'status', p.status,
      'paid_at', p.paid_at,
      'confirmed_paid_at', p.confirmed_paid_at
    )
  from paid_payments as p
  where p.paid_at is null
    and p.confirmed_paid_at is null
),

leaf_outcomes as (
  select toe.*
  from public.trust_outcome_events as toe
  cross join audit_clock as c
  where toe.created_at <= c.as_of
    and toe.outcome_at <= c.as_of
    and not exists (
      select 1
      from public.trust_outcome_events as child
      where child.supersedes_outcome_event_id = toe.id
        and child.created_at <= c.as_of
    )
),

payment_leaf_outcomes as (
  select
    lo.*,
    public.score_v22_event_payment_id(to_jsonb(lo)) as payment_id
  from leaf_outcomes as lo
  where lo.outcome_type in (
    'payment_paid_early',
    'payment_paid_on_time',
    'payment_paid_late'
  )
),

outcome_evidence_issues as (
  select
    lo.user_id,
    'payment_outcome_missing_payment_id'::text as issue_code,
    'trust_outcome_event'::text as entity_type,
    lo.id::text as entity_id,
    true as is_blocker,
    true as requires_backfill,
    jsonb_build_object(
      'outcome_event_id', lo.id,
      'score_agreement_id', lo.score_agreement_id,
      'outcome_type', lo.outcome_type
    ) as details
  from payment_leaf_outcomes as lo
  where lo.payment_id is null

  union all

  select
    lo.user_id,
    'payment_outcome_references_missing_payment',
    'trust_outcome_event',
    lo.id::text,
    true,
    true,
    jsonb_build_object(
      'outcome_event_id', lo.id,
      'score_agreement_id', lo.score_agreement_id,
      'payment_id', lo.payment_id,
      'outcome_type', lo.outcome_type
    )
  from payment_leaf_outcomes as lo
  left join public.payments as p
    on p.id = lo.payment_id
  where lo.payment_id is not null
    and p.id is null

  union all

  select
    lo.user_id,
    'payment_outcome_iou_mismatch',
    'trust_outcome_event',
    lo.id::text,
    true,
    false,
    jsonb_build_object(
      'outcome_event_id', lo.id,
      'score_agreement_id', lo.score_agreement_id,
      'payment_id', lo.payment_id,
      'payment_iou_id', p.iou_id,
      'agreement_iou_id', sa.source_id
    )
  from payment_leaf_outcomes as lo
  join public.payments as p
    on p.id = lo.payment_id
  join public.score_agreements as sa
    on sa.id = lo.score_agreement_id
  where sa.source_type = 'personal_iou'
    and p.iou_id is distinct from sa.source_id

  union all

  select
    lo.user_id,
    'late_outcome_missing_positive_lateness',
    'trust_outcome_event',
    lo.id::text,
    true,
    true,
    jsonb_build_object(
      'outcome_event_id', lo.id,
      'payment_id', lo.payment_id,
      'days_late', public.score_v22_days_late(
        to_jsonb(p),
        to_jsonb(lo)
      )
    )
  from payment_leaf_outcomes as lo
  left join public.payments as p
    on p.id = lo.payment_id
  where lo.outcome_type = 'payment_paid_late'
    and public.score_v22_days_late(
      coalesce(to_jsonb(p), '{}'::jsonb),
      to_jsonb(lo)
    ) <= 0
),

late_expected_raw as (
  select
    lo.user_id,
    lo.id as outcome_event_id,
    lo.score_agreement_id,
    lo.outcome_type,
    lo.outcome_at,
    lo.payment_id,
    am.agreement_ceiling,
    am.principal_cents,
    public.score_v22_payment_amount_cents(
      coalesce(to_jsonb(p), '{}'::jsonb),
      to_jsonb(lo)
    ) as installment_cents,
    public.score_v22_days_late(
      coalesce(to_jsonb(p), '{}'::jsonb),
      to_jsonb(lo)
    ) as days_late
  from payment_leaf_outcomes as lo
  join agreement_math as am
    on am.score_agreement_id = lo.score_agreement_id
  left join public.payments as p
    on p.id = lo.payment_id
  where lo.outcome_type = 'payment_paid_late'
),

late_expected as (
  select
    l.user_id,
    l.outcome_event_id,
    l.score_agreement_id,
    'payment_late_penalty'::text as contribution_type,
    public.score_v22_late_penalty_points(
      l.agreement_ceiling,
      l.principal_cents,
      l.installment_cents,
      l.days_late
    )::integer as expected_points,
    'penalty'::text as expected_direction,
    l.outcome_at as expected_source_outcome_at
  from late_expected_raw as l
  where l.installment_cents > 0
    and l.days_late > 0
    and public.score_v22_late_penalty_points(
      l.agreement_ceiling,
      l.principal_cents,
      l.installment_cents,
      l.days_late
    ) > 0
),

completion_outcomes as (
  select distinct on (lo.score_agreement_id)
    lo.user_id,
    lo.id as outcome_event_id,
    lo.score_agreement_id,
    lo.outcome_at
  from leaf_outcomes as lo
  where lo.outcome_type = 'agreement_completed'
  order by lo.score_agreement_id, lo.outcome_at, lo.id
),

completion_expected as (
  select
    co.user_id,
    co.outcome_event_id,
    co.score_agreement_id,
    'agreement_completion'::text as contribution_type,
    greatest(
      am.agreement_ceiling
        - round(am.agreement_ceiling * 0.20)::integer,
      0
    )::integer as expected_points,
    'reward'::text as expected_direction,
    co.outcome_at as expected_source_outcome_at
  from completion_outcomes as co
  join agreement_math as am
    on am.score_agreement_id = co.score_agreement_id
),

qualifying_early_outcomes as (
  select distinct on (lo.score_agreement_id)
    lo.user_id,
    lo.id as outcome_event_id,
    lo.score_agreement_id,
    lo.outcome_at
  from leaf_outcomes as lo
  where lo.outcome_type = 'payment_paid_early'
  order by lo.score_agreement_id, lo.outcome_at, lo.id
),

early_expected as (
  select
    eo.user_id,
    eo.outcome_event_id,
    eo.score_agreement_id,
    'early_payment_bonus'::text as contribution_type,
    round(am.agreement_ceiling * 0.20)::integer as expected_points,
    'reward'::text as expected_direction,
    eo.outcome_at as expected_source_outcome_at
  from qualifying_early_outcomes as eo
  join completion_outcomes as co
    on co.score_agreement_id = eo.score_agreement_id
   and eo.outcome_at <= co.outcome_at
  join agreement_math as am
    on am.score_agreement_id = eo.score_agreement_id
  where round(am.agreement_ceiling * 0.20)::integer > 0
),

expected_contributions as (
  select * from late_expected
  union all
  select * from completion_expected
  union all
  select * from early_expected
),

missing_contribution_issues as (
  select
    e.user_id,
    'outcome_missing_v22_contribution'::text as issue_code,
    'trust_outcome_event'::text as entity_type,
    e.outcome_event_id::text as entity_id,
    true as is_blocker,
    true as requires_backfill,
    jsonb_build_object(
      'outcome_event_id', e.outcome_event_id,
      'score_agreement_id', e.score_agreement_id,
      'expected_contribution_type', e.contribution_type,
      'expected_points', e.expected_points,
      'expected_direction', e.expected_direction,
      'expected_source_outcome_at', e.expected_source_outcome_at
    ) as details
  from expected_contributions as e
  left join public.score_v2_contributions as c
    on c.outcome_event_id = e.outcome_event_id
   and c.score_agreement_id = e.score_agreement_id
   and c.contribution_type = e.contribution_type
   and c.model_key = 'iou_score'
   and c.model_version = 'v2.2-shadow'
  where c.id is null
),

contribution_value_issues as (
  select
    e.user_id,
    'v22_contribution_value_mismatch'::text as issue_code,
    'score_v2_contribution'::text as entity_type,
    c.id::text as entity_id,
    true as is_blocker,
    false as requires_backfill,
    jsonb_build_object(
      'contribution_id', c.id,
      'outcome_event_id', e.outcome_event_id,
      'score_agreement_id', e.score_agreement_id,
      'contribution_type', e.contribution_type,
      'expected_points', e.expected_points,
      'actual_points', c.points_awarded,
      'expected_direction', e.expected_direction,
      'actual_direction', c.impact_direction,
      'expected_source_outcome_at', e.expected_source_outcome_at,
      'actual_source_outcome_at', c.source_outcome_at
    ) as details
  from expected_contributions as e
  join public.score_v2_contributions as c
    on c.outcome_event_id = e.outcome_event_id
   and c.score_agreement_id = e.score_agreement_id
   and c.contribution_type = e.contribution_type
   and c.model_key = 'iou_score'
   and c.model_version = 'v2.2-shadow'
  where c.points_awarded is distinct from e.expected_points
     or c.impact_direction is distinct from e.expected_direction
     or c.source_outcome_at
          is distinct from e.expected_source_outcome_at
),

contribution_integrity_issues as (
  select
    c.user_id,
    'v22_contribution_contract_mismatch'::text as issue_code,
    'score_v2_contribution'::text as entity_type,
    c.id::text as entity_id,
    true as is_blocker,
    false as requires_backfill,
    jsonb_build_object(
      'contribution_id', c.id,
      'outcome_event_id', c.outcome_event_id,
      'contribution_score_agreement_id', c.score_agreement_id,
      'outcome_score_agreement_id', toe.score_agreement_id,
      'contribution_user_id', c.user_id,
      'agreement_user_id', sa.user_id,
      'contribution_type', c.contribution_type,
      'impact_direction', c.impact_direction,
      'source_outcome_type', c.source_outcome_type,
      'actual_outcome_type', toe.outcome_type,
      'source_outcome_at', c.source_outcome_at,
      'actual_outcome_at', toe.outcome_at
    ) as details
  from public.score_v2_contributions as c
  join public.trust_outcome_events as toe
    on toe.id = c.outcome_event_id
  join public.score_agreements as sa
    on sa.id = c.score_agreement_id
  where c.model_version = 'v2.2-shadow'
    and (
      c.score_agreement_id is distinct from toe.score_agreement_id
      or c.user_id is distinct from sa.user_id
      or c.source_outcome_type is distinct from toe.outcome_type
      or c.source_outcome_at is distinct from toe.outcome_at
      or (
        c.contribution_type = 'payment_late_penalty'
        and c.impact_direction <> 'penalty'
      )
      or (
        c.contribution_type in (
          'agreement_completion',
          'early_payment_bonus'
        )
        and c.impact_direction <> 'reward'
      )
      or c.contribution_type = 'payment_performance'
    )
),

correction_edges as (
  select
    child.id as child_id,
    child.user_id as child_user_id,
    child.score_agreement_id as child_score_agreement_id,
    child.source_type as child_source_type,
    child.source_id as child_source_id,
    child.outcome_type as child_outcome_type,
    child.outcome_at as child_outcome_at,
    child.created_at as child_created_at,
    child.correction_key,
    child.correction_reason,
    child.supersedes_outcome_event_id as parent_id,
    parent.user_id as parent_user_id,
    parent.score_agreement_id as parent_score_agreement_id,
    parent.source_type as parent_source_type,
    parent.source_id as parent_source_id,
    parent.outcome_type as parent_outcome_type,
    parent.outcome_at as parent_outcome_at,
    parent.created_at as parent_created_at,
    public.score_v22_event_payment_id(to_jsonb(child))
      as child_payment_id,
    public.score_v22_event_payment_id(to_jsonb(parent))
      as parent_payment_id
  from public.trust_outcome_events as child
  left join public.trust_outcome_events as parent
    on parent.id = child.supersedes_outcome_event_id
  where child.supersedes_outcome_event_id is not null
),

correction_edge_issues as (
  select
    ce.child_user_id as user_id,
    'broken_correction_edge'::text as issue_code,
    'trust_outcome_event'::text as entity_type,
    ce.child_id::text as entity_id,
    true as is_blocker,
    false as requires_backfill,
    jsonb_build_object(
      'child_id', ce.child_id,
      'parent_id', ce.parent_id,
      'reasons', to_jsonb(array_remove(array[
        case when ce.parent_user_id is null
          then 'missing_parent' end,
        case when ce.child_id = ce.parent_id
          then 'self_reference' end,
        case when ce.child_user_id
                   is distinct from ce.parent_user_id
          then 'user_mismatch' end,
        case when ce.child_score_agreement_id
                   is distinct from ce.parent_score_agreement_id
          then 'score_agreement_mismatch' end,
        case when ce.child_source_type
                   is distinct from ce.parent_source_type
          then 'source_type_mismatch' end,
        case when ce.child_source_id
                   is distinct from ce.parent_source_id
          then 'source_id_mismatch' end,
        case when ce.child_payment_id is null
          then 'child_missing_payment_id' end,
        case when ce.parent_payment_id is null
          then 'parent_missing_payment_id' end,
        case when ce.child_payment_id
                   is distinct from ce.parent_payment_id
          then 'payment_id_mismatch' end,
        case when ce.child_outcome_type not in (
          'payment_paid_early',
          'payment_paid_on_time',
          'payment_paid_late'
        ) then 'invalid_child_outcome_type' end,
        case when ce.parent_outcome_type not in (
          'payment_paid_early',
          'payment_paid_on_time',
          'payment_paid_late'
        ) then 'invalid_parent_outcome_type' end,
        case when ce.child_outcome_at
                   is distinct from ce.parent_outcome_at
          then 'outcome_at_mismatch' end,
        case when ce.child_created_at < ce.parent_created_at
          then 'created_before_parent' end,
        case when nullif(btrim(ce.correction_key), '') is null
          then 'missing_correction_key' end,
        case when nullif(btrim(ce.correction_reason), '') is null
          then 'missing_correction_reason' end
      ]::text[], null))
    ) as details
  from correction_edges as ce
  where ce.parent_user_id is null
     or ce.child_id = ce.parent_id
     or ce.child_user_id is distinct from ce.parent_user_id
     or ce.child_score_agreement_id
          is distinct from ce.parent_score_agreement_id
     or ce.child_source_type is distinct from ce.parent_source_type
     or ce.child_source_id is distinct from ce.parent_source_id
     or ce.child_payment_id is null
     or ce.parent_payment_id is null
     or ce.child_payment_id is distinct from ce.parent_payment_id
     or ce.child_outcome_type not in (
       'payment_paid_early',
       'payment_paid_on_time',
       'payment_paid_late'
     )
     or ce.parent_outcome_type not in (
       'payment_paid_early',
       'payment_paid_on_time',
       'payment_paid_late'
     )
     or ce.child_outcome_at is distinct from ce.parent_outcome_at
     or ce.child_created_at < ce.parent_created_at
     or nullif(btrim(ce.correction_key), '') is null
     or nullif(btrim(ce.correction_reason), '') is null

  union all

  select
    parent.user_id,
    'correction_parent_has_multiple_successors',
    'trust_outcome_event',
    parent.id::text,
    true,
    false,
    jsonb_build_object(
      'parent_id', parent.id,
      'successor_count', count(*)::integer,
      'successor_ids', jsonb_agg(child.id order by child.created_at, child.id)
    )
  from public.trust_outcome_events as parent
  join public.trust_outcome_events as child
    on child.supersedes_outcome_event_id = parent.id
  group by parent.id, parent.user_id
  having count(*) > 1
),

correction_walk(
  start_id,
  user_id,
  current_id,
  next_parent_id,
  path,
  depth,
  cycle_found
) as (
  select
    toe.id,
    toe.user_id,
    toe.id,
    toe.supersedes_outcome_event_id,
    array[toe.id]::uuid[],
    0,
    false
  from public.trust_outcome_events as toe
  where toe.supersedes_outcome_event_id is not null

  union all

  select
    w.start_id,
    w.user_id,
    parent.id,
    parent.supersedes_outcome_event_id,
    w.path || parent.id,
    w.depth + 1,
    parent.id = any(w.path)
  from correction_walk as w
  join public.trust_outcome_events as parent
    on parent.id = w.next_parent_id
  where not w.cycle_found
    and w.depth < 100
),

correction_chain_rollup as (
  select
    w.start_id,
    min(w.user_id::text)::uuid as user_id,
    bool_or(w.cycle_found) as cycle_found,
    bool_or(
      w.depth >= 100
      and w.next_parent_id is not null
    ) as depth_limit_reached,
    max(w.depth)::integer as max_depth
  from correction_walk as w
  group by w.start_id
  having bool_or(w.cycle_found)
      or bool_or(
        w.depth >= 100
        and w.next_parent_id is not null
      )
),

correction_chain_issues as (
  select
    w.user_id,
    'broken_correction_chain'::text as issue_code,
    'trust_outcome_event'::text as entity_type,
    w.start_id::text as entity_id,
    true as is_blocker,
    false as requires_backfill,
    jsonb_build_object(
      'start_id', w.start_id,
      'cycle_found', w.cycle_found,
      'depth_limit_reached', w.depth_limit_reached,
      'max_depth', w.max_depth
    ) as details
  from correction_chain_rollup as w
),

historical_event_rows as (
  select
    ae.id as agreement_event_id,
    coalesce(
      direct_sa.user_id,
      sa.user_id,
      i.borrower_id,
      ae.user_id
    ) as user_id,
    ae.event_type,
    ae.event_at,
    coalesce(ae.score_agreement_id, sa.id) as score_agreement_id,
    coalesce(ae.source_id, direct_sa.source_id, sa.source_id) as iou_id,
    public.score_v22_event_payment_id(to_jsonb(ae)) as payment_id,
    ae.metadata
  from public.agreement_events as ae
  left join public.score_agreements as direct_sa
    on direct_sa.id = ae.score_agreement_id
  left join public.score_agreements as sa
    on sa.source_type = 'personal_iou'
   and sa.source_id = ae.source_id
  left join public.ious as i
    on i.id = coalesce(ae.source_id, direct_sa.source_id, sa.source_id)
  where ae.event_type in (
    'payment_paid_early',
    'payment_paid_on_time',
    'payment_paid_late',
    'agreement_completed'
  )
),

historical_backfill_issues as (
  select
    h.user_id,
    'historical_event_missing_score_agreement'::text as issue_code,
    'agreement_event'::text as entity_type,
    h.agreement_event_id::text as entity_id,
    true as is_blocker,
    true as requires_backfill,
    jsonb_build_object(
      'agreement_event_id', h.agreement_event_id,
      'event_type', h.event_type,
      'event_at', h.event_at,
      'iou_id', h.iou_id
    ) as details
  from historical_event_rows as h
  where h.score_agreement_id is null

  union all

  select
    h.user_id,
    'historical_payment_event_missing_payment_id',
    'agreement_event',
    h.agreement_event_id::text,
    true,
    true,
    jsonb_build_object(
      'agreement_event_id', h.agreement_event_id,
      'event_type', h.event_type,
      'event_at', h.event_at,
      'score_agreement_id', h.score_agreement_id,
      'iou_id', h.iou_id
    )
  from historical_event_rows as h
  where h.event_type in (
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late'
    )
    and h.payment_id is null

  union all

  select
    h.user_id,
    'historical_payment_event_missing_outcome',
    'agreement_event',
    h.agreement_event_id::text,
    true,
    true,
    jsonb_build_object(
      'agreement_event_id', h.agreement_event_id,
      'event_type', h.event_type,
      'event_at', h.event_at,
      'score_agreement_id', h.score_agreement_id,
      'payment_id', h.payment_id,
      'iou_id', h.iou_id
    )
  from historical_event_rows as h
  where h.event_type in (
      'payment_paid_early',
      'payment_paid_on_time',
      'payment_paid_late'
    )
    and h.score_agreement_id is not null
    and h.payment_id is not null
    and not exists (
      select 1
      from public.trust_outcome_events as toe
      where toe.score_agreement_id = h.score_agreement_id
        and public.score_v22_event_payment_id(to_jsonb(toe))
              = h.payment_id
        and toe.outcome_type in (
          'payment_paid_early',
          'payment_paid_on_time',
          'payment_paid_late'
        )
    )

  union all

  select
    h.user_id,
    'historical_completion_event_missing_outcome',
    'agreement_event',
    h.agreement_event_id::text,
    true,
    true,
    jsonb_build_object(
      'agreement_event_id', h.agreement_event_id,
      'event_type', h.event_type,
      'event_at', h.event_at,
      'score_agreement_id', h.score_agreement_id,
      'iou_id', h.iou_id
    )
  from historical_event_rows as h
  where h.event_type = 'agreement_completed'
    and h.score_agreement_id is not null
    and not exists (
      select 1
      from public.trust_outcome_events as toe
      where toe.score_agreement_id = h.score_agreement_id
        and toe.outcome_type = 'agreement_completed'
    )
),

completion_state_issues as (
  select
    i.borrower_id as user_id,
    'completed_iou_missing_completion_outcome'::text as issue_code,
    'iou'::text as entity_type,
    i.id::text as entity_id,
    true as is_blocker,
    true as requires_backfill,
    jsonb_build_object(
      'iou_id', i.id,
      'status', i.status,
      'principal_cents', i.principal_cents,
      'paid_cents', i.paid_cents,
      'score_agreement_id', sa.id
    ) as details
  from iou_scope as i
  join public.score_agreements as sa
    on sa.source_type = 'personal_iou'
   and sa.source_id = i.id
   and sa.user_id = i.borrower_id
  where (
      i.status = 'paid'
      or i.paid_cents >= i.principal_cents
    )
    and not exists (
      select 1
      from public.trust_outcome_events as toe
      where toe.score_agreement_id = sa.id
        and toe.outcome_type = 'agreement_completed'
    )

  union all

  select
    sa.user_id,
    'completion_outcome_without_full_payment',
    'trust_outcome_event',
    toe.id::text,
    true,
    false,
    jsonb_build_object(
      'outcome_event_id', toe.id,
      'score_agreement_id', sa.id,
      'iou_id', i.id,
      'principal_cents', i.principal_cents,
      'paid_cents', coalesce(pt.paid_cents, 0)
    )
  from public.trust_outcome_events as toe
  join public.score_agreements as sa
    on sa.id = toe.score_agreement_id
   and sa.source_type = 'personal_iou'
  join public.ious as i
    on i.id = sa.source_id
  left join iou_payment_totals as pt
    on pt.iou_id = i.id
  where toe.outcome_type = 'agreement_completed'
    and coalesce(pt.paid_cents, 0) < i.principal_cents
),

exposure_issues as (
  select
    u.user_id,
    'stored_active_exposure_mismatch'::text as issue_code,
    'profile'::text as entity_type,
    u.user_id::text as entity_id,
    true as is_blocker,
    false as requires_backfill,
    jsonb_build_object(
      'stored_active_exposure', u.stored_active_exposure,
      'computed_active_exposure', u.active_exposure
    ) as details
  from user_score_output as u
  where u.stored_active_exposure is distinct from u.active_exposure
),

all_user_issues as (
  select * from agreement_issues
  union all
  select * from payment_issues
  union all
  select * from outcome_evidence_issues
  union all
  select * from missing_contribution_issues
  union all
  select * from contribution_value_issues
  union all
  select * from contribution_integrity_issues
  union all
  select * from correction_edge_issues
  union all
  select * from correction_chain_issues
  union all
  select * from historical_backfill_issues
  union all
  select * from completion_state_issues
  union all
  select * from exposure_issues
),

global_issues as (
  select
    'model_registry_not_cutover_ready'::text as issue_code,
    true as is_blocker,
    jsonb_build_object(
      'shadow_count', ms.shadow_count,
      'v22_shadow_count', ms.v22_shadow_count,
      'v22_registry_count', ms.v22_registry_count,
      'v22_base_score', ms.v22_base_score,
      'expected', jsonb_build_object(
        'shadow_count', 1,
        'v22_shadow_count', 1,
        'v22_registry_count', 1,
        'v22_base_score', 700
      )
    ) as details
  from model_state as ms
  where ms.shadow_count <> 1
     or ms.v22_shadow_count <> 1
     or ms.v22_registry_count <> 1
     or ms.v22_base_score is distinct from 700

  union all

  select
    'outcome_dispatch_not_cutover_ready',
    true,
    jsonb_build_object(
      'v22_dispatch_count', ds.v22_dispatch_count,
      'legacy_dispatch_count', ds.legacy_dispatch_count,
      'expected', jsonb_build_object(
        'v22_dispatch_count', 1,
        'legacy_dispatch_count', 0
      )
    )
  from dispatch_state as ds
  where ds.v22_dispatch_count <> 1
     or ds.legacy_dispatch_count <> 0

  union all

  select
    'required_index_missing_or_invalid',
    true,
    jsonb_build_object(
      'index_name', ris.index_name,
      'is_valid', ris.is_valid,
      'is_ready', ris.is_ready
    )
  from required_index_state as ris
  where not ris.is_valid
     or not ris.is_ready

  union all

  select
    'unowned_data_blocker:' || i.issue_code,
    true,
    jsonb_build_object(
      'entity_type', i.entity_type,
      'entity_id', i.entity_id,
      'requires_backfill', i.requires_backfill,
      'details', i.details
    )
  from all_user_issues as i
  where i.user_id is null
    and i.is_blocker
),

per_user_issue_rollup as (
  select
    p.id as user_id,
    count(*) filter (
      where i.issue_code = 'missing_score_agreement'
    )::integer as missing_score_agreements,
    count(*) filter (
      where i.issue_code = 'duplicate_score_agreements'
    )::integer as duplicate_score_agreements,
    count(*) filter (
      where i.issue_code = 'paid_payment_missing_outcome'
    )::integer as payments_missing_outcomes,
    count(*) filter (
      where i.issue_code = 'outcome_missing_v22_contribution'
    )::integer as outcomes_missing_contributions,
    count(*) filter (
      where i.issue_code in (
        'broken_correction_edge',
        'broken_correction_chain',
        'correction_parent_has_multiple_successors'
      )
    )::integer as broken_correction_chains,
    count(*) filter (
      where i.requires_backfill
    )::integer as historical_records_requiring_backfill,
    count(*) filter (
      where i.is_blocker
    )::integer as blocker_count,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'issue_code', i.issue_code,
          'entity_type', i.entity_type,
          'entity_id', i.entity_id,
          'requires_backfill', i.requires_backfill,
          'details', i.details
        )
        order by i.issue_code, i.entity_type, i.entity_id
      ) filter (where i.is_blocker),
      '[]'::jsonb
    ) as explicit_blockers
  from public.profiles as p
  left join all_user_issues as i
    on i.user_id = p.id
  group by p.id
),

per_user_output as (
  select
    u.user_id,
    u.email,
    u.legacy_public_score as current_legacy_public_score,
    u.score_v22,
    u.score_difference as difference,
    u.visible_trust,
    u.active_exposure,
    u.stored_active_exposure,
    u.v22_contribution_total,
    r.missing_score_agreements,
    r.duplicate_score_agreements,
    r.payments_missing_outcomes,
    r.outcomes_missing_contributions,
    r.broken_correction_chains,
    r.historical_records_requiring_backfill,
    r.explicit_blockers,
    (r.blocker_count = 0) as safe_to_cut_over
  from user_score_output as u
  join per_user_issue_rollup as r
    on r.user_id = u.user_id
),

summary as (
  select
    (select count(*)::integer from per_user_output) as user_count,
    (
      select count(*)::integer
      from per_user_output
      where not safe_to_cut_over
    ) as users_with_blockers,
    (
      select count(*)::integer
      from all_user_issues
      where is_blocker
    ) as user_blocker_count,
    (
      select count(*)::integer
      from global_issues
      where is_blocker
    ) as global_blocker_count,
    (
      select count(*)::integer
      from all_user_issues
      where issue_code = 'missing_score_agreement'
    ) as missing_score_agreement_count,
    (
      select count(*)::integer
      from all_user_issues
      where issue_code = 'duplicate_score_agreements'
    ) as duplicate_score_agreement_count,
    (
      select count(*)::integer
      from all_user_issues
      where issue_code = 'paid_payment_missing_outcome'
    ) as payments_missing_outcomes_count,
    (
      select count(*)::integer
      from all_user_issues
      where issue_code = 'outcome_missing_v22_contribution'
    ) as outcomes_missing_contributions_count,
    (
      select count(*)::integer
      from all_user_issues
      where issue_code in (
        'broken_correction_edge',
        'broken_correction_chain',
        'correction_parent_has_multiple_successors'
      )
    ) as broken_correction_chain_count,
    (
      select count(*)::integer
      from all_user_issues
      where requires_backfill
    ) as historical_backfill_count
)

select jsonb_build_object(
  'audit', 'Score v2.2 official cutover-readiness',
  'project_ref', 'colkilearqxuyldzjutw',
  'generated_at', c.as_of,
  'evidence_cutoff', c.evidence_cutoff,
  'read_only_required', true,
  'model_version', 'v2.2-shadow',
  'summary', jsonb_build_object(
    'user_count', s.user_count,
    'users_with_blockers', s.users_with_blockers,
    'user_blocker_count', s.user_blocker_count,
    'global_blocker_count', s.global_blocker_count,
    'missing_score_agreement_count',
      s.missing_score_agreement_count,
    'duplicate_score_agreement_count',
      s.duplicate_score_agreement_count,
    'payments_missing_outcomes_count',
      s.payments_missing_outcomes_count,
    'outcomes_missing_contributions_count',
      s.outcomes_missing_contributions_count,
    'broken_correction_chain_count',
      s.broken_correction_chain_count,
    'historical_backfill_count',
      s.historical_backfill_count
  ),
  'global_blockers', coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'issue_code', g.issue_code,
          'details', g.details
        )
        order by g.issue_code
      )
      from global_issues as g
      where g.is_blocker
    ),
    '[]'::jsonb
  ),
  'warnings', coalesce(
    (
      select jsonb_agg(r.warning)
      from redundant_index_warnings as r
    ),
    '[]'::jsonb
  ),
  'users', coalesce(
    (
      select jsonb_agg(
        to_jsonb(u)
        order by u.email nulls last, u.user_id
      )
      from per_user_output as u
    ),
    '[]'::jsonb
  ),
  'safe_to_cut_over',
    (
      s.user_blocker_count = 0
      and s.global_blocker_count = 0
    ),
  'next_required_step',
    case
      when s.user_blocker_count = 0
       and s.global_blocker_count = 0
      then 'Rerun the full Score v2.2 regression suite, then review cutover and rollback migrations.'
      else 'Repair the reported blockers and rerun this read-only audit.'
    end
) as score_v22_cutover_readiness
from audit_clock as c
cross join summary as s;
