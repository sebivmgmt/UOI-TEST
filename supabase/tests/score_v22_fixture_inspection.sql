-- Score v2.2 approved DEV fixture inspection.
-- Read-only.

SELECT
  public.score_v22_same_pair_index(
    'db90834c-948f-473a-831a-453132b05f1c'
  ) AS pair_index,
  public.score_v22_agreement_ceiling(
    'db90834c-948f-473a-831a-453132b05f1c'
  ) AS agreement_ceiling,
  public.score_v22_pending_agreement_progress(
    'db90834c-948f-473a-831a-453132b05f1c',
    now()
  ) AS progress;

SELECT
  c.score_agreement_id,
  c.outcome_event_id,
  c.model_version,
  c.contribution_type,
  c.impact_direction,
  c.points_awarded,
  c.source_outcome_at,
  c.agreement_ceiling,
  c.pair_index,
  c.calculation_details
FROM public.score_v2_contributions AS c
WHERE c.score_agreement_id = 'db90834c-948f-473a-831a-453132b05f1c'
ORDER BY c.model_version, c.source_outcome_at, c.contribution_type;

SELECT
  e.id AS outcome_event_id,
  public.score_v22_event_type(to_jsonb(e)) AS outcome_type,
  public.score_v22_event_at(to_jsonb(e)) AS outcome_at,
  public.score_v22_event_payment_id(to_jsonb(e)) AS payment_id,
  to_jsonb(e) AS immutable_event
FROM public.trust_outcome_events AS e
WHERE public.score_v22_event_score_agreement_id(to_jsonb(e))
      = 'db90834c-948f-473a-831a-453132b05f1c'
ORDER BY public.score_v22_event_at(to_jsonb(e)), e.id;

SELECT
  count(*) FILTER (
    WHERE model_version = 'v2.1-shadow'
  ) AS preserved_v21_rows,
  count(*) FILTER (
    WHERE model_version = 'v2.2-shadow'
  ) AS v22_rows
FROM public.score_v2_contributions
WHERE score_agreement_id = 'db90834c-948f-473a-831a-453132b05f1c';
