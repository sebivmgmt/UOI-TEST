-- Read-only Score v2.2 preflight report.
-- Run against DEV before db push when you want an explicit schema snapshot.

SELECT
  current_database() AS database_name,
  now() AS checked_at,
  to_regclass('public.trust_model_versions') AS trust_model_versions,
  to_regclass('public.score_agreements') AS score_agreements,
  to_regclass('public.score_v2_contributions') AS score_v2_contributions,
  to_regclass('public.trust_outcome_events') AS trust_outcome_events,
  to_regclass('public.ious') AS ious,
  to_regclass('public.payments') AS payments;

SELECT
  a.attname AS column_name,
  pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
  a.attnotnull AS not_null,
  pg_get_expr(d.adbin, d.adrelid) AS default_expression
FROM pg_attribute AS a
LEFT JOIN pg_attrdef AS d
  ON d.adrelid = a.attrelid
 AND d.adnum = a.attnum
WHERE a.attrelid = 'public.score_v2_contributions'::regclass
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY a.attnum;

SELECT
  c.conname,
  c.contype,
  pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint AS c
WHERE c.conrelid = 'public.score_v2_contributions'::regclass
ORDER BY c.contype, c.conname;

SELECT
  idx.indexrelid::regclass AS index_name,
  idx.indisunique,
  pg_get_indexdef(idx.indexrelid) AS definition
FROM pg_index AS idx
WHERE idx.indrelid = 'public.score_v2_contributions'::regclass
ORDER BY idx.indexrelid::regclass::text;

SELECT *
FROM public.trust_model_versions
ORDER BY 1;
