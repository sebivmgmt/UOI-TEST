-- ============================================================================
-- Migration: Score v2.2 shadow engine
-- File:      20260620008000_score_v22_shadow.sql
-- Scope:     DEV first. Do not apply to LIVE until separately approved.
--
-- Doctrine implemented:
--   * On-time personal-IOU installments are score-neutral.
--   * Early installments earn a capped bonus that remains locked until completion.
--   * Each separate late installment can create its own immediate penalty.
--   * Completion unlocks the base reward and any earned early bonus.
--   * Late penalties remain independent and are not erased by completion.
--   * All score-active evidence uses: outcome_at > as_of - interval '2 years'.
--   * v2.1 contribution rows are never updated or deleted.
-- ============================================================================

-- --------------------------------------------------------------------------
-- 0. Hard preflight: fail before making changes when the required v2 tables
--    are not present. This prevents a partially guessed deployment.
-- --------------------------------------------------------------------------
DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.trust_model_versions') IS NULL THEN
    v_missing := array_append(v_missing, 'public.trust_model_versions');
  END IF;
  IF to_regclass('public.score_agreements') IS NULL THEN
    v_missing := array_append(v_missing, 'public.score_agreements');
  END IF;
  IF to_regclass('public.score_v2_contributions') IS NULL THEN
    v_missing := array_append(v_missing, 'public.score_v2_contributions');
  END IF;
  IF to_regclass('public.trust_outcome_events') IS NULL THEN
    v_missing := array_append(v_missing, 'public.trust_outcome_events');
  END IF;
  IF to_regclass('public.ious') IS NULL THEN
    v_missing := array_append(v_missing, 'public.ious');
  END IF;
  IF to_regclass('public.payments') IS NULL THEN
    v_missing := array_append(v_missing, 'public.payments');
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      'Score v2.2 preflight failed. Missing required objects: %',
      array_to_string(v_missing, ', ');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'score_agreement_id'
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'Score v2.2 requires score_v2_contributions.score_agreement_id';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'outcome_event_id'
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'Score v2.2 requires score_v2_contributions.outcome_event_id';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'contribution_type'
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'Score v2.2 requires score_v2_contributions.contribution_type';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'model_version'
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'Score v2.2 requires score_v2_contributions.model_version';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'impact_direction'
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'Score v2.2 requires score_v2_contributions.impact_direction';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'points_awarded'
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'Score v2.2 requires score_v2_contributions.points_awarded';
  END IF;
END
$preflight$;

-- --------------------------------------------------------------------------
-- 1. Explainability columns. Existing v2.1 rows are preserved unchanged.
-- --------------------------------------------------------------------------
ALTER TABLE public.score_v2_contributions
  ADD COLUMN IF NOT EXISTS calculation_details jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS source_outcome_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS agreement_ceiling integer NULL,
  ADD COLUMN IF NOT EXISTS pair_index integer NULL;

COMMENT ON COLUMN public.score_v2_contributions.calculation_details IS
  'Versioned deterministic calculation inputs and outputs. Never contains mutable application state.';
COMMENT ON COLUMN public.score_v2_contributions.source_outcome_at IS
  'Timestamp of the exact immutable evidence event that controls the strict two-year score-active boundary.';
COMMENT ON COLUMN public.score_v2_contributions.agreement_ceiling IS
  'Agreement ceiling used by the model when this append-only contribution was created.';
COMMENT ON COLUMN public.score_v2_contributions.pair_index IS
  'Same borrower/lender pair index used by the model when this append-only contribution was created.';

-- Fail closed when the current table has an unknown required insert column.
-- This is preferable to inventing a value for a column whose semantics are not
-- part of the v2.2 contract. Columns with defaults are safe and need no entry.
DO $contribution_insert_shape$
DECLARE
  v_unknown_required text;
BEGIN
  SELECT string_agg(a.attname, ', ' ORDER BY a.attnum)
  INTO v_unknown_required
  FROM pg_attribute AS a
  LEFT JOIN pg_attrdef AS d
    ON d.adrelid = a.attrelid
   AND d.adnum = a.attnum
  WHERE a.attrelid = 'public.score_v2_contributions'::regclass
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attnotnull
    AND d.adbin IS NULL
    AND a.attidentity = ''
    AND a.attgenerated = ''
    AND a.attname NOT IN (
      'score_agreement_id',
      'outcome_event_id',
      'contribution_type',
      'model_version',
      'impact_direction',
      'points_awarded',
      'source_outcome_type',
      'points_cap',
      'calculation_details',
      'source_outcome_at',
      'agreement_ceiling',
      'pair_index',
      'user_id',
      'subject_user_id',
      'borrower_id',
      'domain',
      'score_domain'
    );

  IF v_unknown_required IS NOT NULL THEN
    RAISE EXCEPTION
      'Score v2.2 cannot safely insert contributions. Unknown NOT NULL columns without defaults: %',
      v_unknown_required;
  END IF;
END
$contribution_insert_shape$;

-- --------------------------------------------------------------------------
-- 2. Contribution types and uniqueness.
--
-- Old rule removed:
--   UNIQUE(score_agreement_id, contribution_type, model_version)
--
-- New rules:
--   * one completion reward per agreement/model
--   * one early bonus per agreement/model
--   * multiple late penalties per agreement/model
--   * same outcome event/type/model cannot be processed twice
-- --------------------------------------------------------------------------
DO $drop_checks$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.score_v2_contributions'::regclass
      AND contype = 'c'
      AND (
        pg_get_constraintdef(oid) ILIKE '%contribution_type%'
        OR pg_get_constraintdef(oid) ILIKE '%model_version%'
      )
  LOOP
    EXECUTE format(
      'ALTER TABLE public.score_v2_contributions DROP CONSTRAINT %I',
      r.conname
    );
  END LOOP;
END
$drop_checks$;

ALTER TABLE public.score_v2_contributions
  ADD CONSTRAINT score_v2_contributions_type_check
  CHECK (
    contribution_type IN (
      'payment_performance',
      'agreement_completion',
      'payment_late_penalty',
      'agreement_default_penalty',
      'early_payment_bonus'
    )
  ),
  ADD CONSTRAINT score_v2_contributions_model_nonempty_check
  CHECK (btrim(model_version) <> '');

DO $drop_old_unique_constraint$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.score_v2_contributions'::regclass
      AND contype = 'u'
      AND pg_get_constraintdef(oid)
          ~* '\(\s*score_agreement_id\s*,\s*contribution_type\s*,\s*model_version\s*\)'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.score_v2_contributions DROP CONSTRAINT %I',
      r.conname
    );
  END LOOP;
END
$drop_old_unique_constraint$;

DO $drop_old_unique$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT idx.indexrelid::regclass AS index_name
    FROM pg_index idx
    JOIN pg_class tbl ON tbl.oid = idx.indrelid
    JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
    WHERE ns.nspname = 'public'
      AND tbl.relname = 'score_v2_contributions'
      AND idx.indisunique
      AND pg_get_indexdef(idx.indexrelid)
          ~* '\(\s*score_agreement_id\s*,\s*contribution_type\s*,\s*model_version\s*\)'
  LOOP
    EXECUTE format('DROP INDEX IF EXISTS %s', r.index_name);
  END LOOP;
END
$drop_old_unique$;

CREATE UNIQUE INDEX IF NOT EXISTS score_v2_contributions_event_type_model_uidx
  ON public.score_v2_contributions
    (outcome_event_id, contribution_type, model_version)
  WHERE outcome_event_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS score_v2_contributions_v22_single_reward_uidx
  ON public.score_v2_contributions
    (score_agreement_id, contribution_type, model_version)
  WHERE model_version = 'v2.2-shadow'
    AND contribution_type IN ('agreement_completion', 'early_payment_bonus');

CREATE INDEX IF NOT EXISTS score_v2_contributions_v22_agreement_idx
  ON public.score_v2_contributions
    (score_agreement_id, model_version, contribution_type);

CREATE INDEX IF NOT EXISTS score_v2_contributions_v22_source_time_idx
  ON public.score_v2_contributions
    (model_version, source_outcome_at DESC);

CREATE OR REPLACE FUNCTION public.score_v22_block_contribution_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF OLD.model_version = 'v2.2-shadow' THEN
    RAISE EXCEPTION
      'Score v2.2 contributions are append-only. Record a new correction event instead of mutating evidence-derived history.';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$function$;

DROP TRIGGER IF EXISTS trg_score_v22_block_contribution_mutation
  ON public.score_v2_contributions;

CREATE TRIGGER trg_score_v22_block_contribution_mutation
  BEFORE UPDATE OR DELETE ON public.score_v2_contributions
  FOR EACH ROW
  EXECUTE FUNCTION public.score_v22_block_contribution_mutation();

-- --------------------------------------------------------------------------
-- 3. Small JSON helpers.
--    They let v2.2 read the existing ledger defensively without hard-coding
--    optional metadata-column names.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_json_text(
  p_object jsonb,
  VARIADIC p_keys text[]
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_key text;
  v_value text;
BEGIN
  IF p_object IS NULL THEN
    RETURN NULL;
  END IF;

  FOREACH v_key IN ARRAY p_keys LOOP
    v_value := NULLIF(btrim(p_object ->> v_key), '');
    IF v_value IS NOT NULL THEN
      RETURN v_value;
    END IF;
  END LOOP;

  RETURN NULL;
END
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_json_uuid(
  p_object jsonb,
  VARIADIC p_keys text[]
)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_key text;
  v_value text;
BEGIN
  IF p_object IS NULL THEN
    RETURN NULL;
  END IF;

  FOREACH v_key IN ARRAY p_keys LOOP
    v_value := NULLIF(btrim(p_object ->> v_key), '');
    IF v_value IS NOT NULL THEN
      BEGIN
        RETURN v_value::uuid;
      EXCEPTION
        WHEN invalid_text_representation THEN
          NULL;
      END;
    END IF;
  END LOOP;

  RETURN NULL;
END
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_json_bigint(
  p_object jsonb,
  VARIADIC p_keys text[]
)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_key text;
  v_value text;
BEGIN
  IF p_object IS NULL THEN
    RETURN NULL;
  END IF;

  FOREACH v_key IN ARRAY p_keys LOOP
    v_value := NULLIF(btrim(p_object ->> v_key), '');
    IF v_value IS NOT NULL THEN
      BEGIN
        RETURN round(v_value::numeric)::bigint;
      EXCEPTION
        WHEN invalid_text_representation OR numeric_value_out_of_range THEN
          NULL;
      END;
    END IF;
  END LOOP;

  RETURN NULL;
END
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_json_timestamptz(
  p_object jsonb,
  VARIADIC p_keys text[]
)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_key text;
  v_value text;
BEGIN
  IF p_object IS NULL THEN
    RETURN NULL;
  END IF;

  FOREACH v_key IN ARRAY p_keys LOOP
    v_value := NULLIF(btrim(p_object ->> v_key), '');
    IF v_value IS NOT NULL THEN
      BEGIN
        RETURN v_value::timestamptz;
      EXCEPTION
        WHEN invalid_datetime_format OR datetime_field_overflow THEN
          NULL;
      END;
    END IF;
  END LOOP;

  RETURN NULL;
END
$function$;

-- --------------------------------------------------------------------------
-- 4. Agreement context and deterministic same-pair index.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_agreement_context(
  p_score_agreement_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_score_agreement jsonb;
  v_iou jsonb := '{}'::jsonb;
  v_iou_id uuid;
BEGIN
  SELECT to_jsonb(sa)
  INTO v_score_agreement
  FROM public.score_agreements AS sa
  WHERE sa.id = p_score_agreement_id;

  IF v_score_agreement IS NULL THEN
    RAISE EXCEPTION 'Score agreement not found: %', p_score_agreement_id;
  END IF;

  v_iou_id := public.score_v22_json_uuid(
    v_score_agreement,
    'iou_id',
    'agreement_id',
    'source_iou_id'
  );

  IF v_iou_id IS NOT NULL THEN
    SELECT to_jsonb(i)
    INTO v_iou
    FROM public.ious AS i
    WHERE i.id = v_iou_id;
  END IF;

  RETURN jsonb_build_object(
    'score_agreement_id', p_score_agreement_id,
    'score_agreement', v_score_agreement,
    'iou', COALESCE(v_iou, '{}'::jsonb)
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_context_borrower_id(
  p_context jsonb
)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT COALESCE(
    public.score_v22_json_uuid(
      p_context -> 'score_agreement',
      'borrower_id',
      'subject_user_id',
      'user_id'
    ),
    public.score_v22_json_uuid(
      p_context -> 'iou',
      'borrower_id',
      'subject_user_id',
      'user_id'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_context_lender_id(
  p_context jsonb
)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT COALESCE(
    public.score_v22_json_uuid(
      p_context -> 'score_agreement',
      'lender_id',
      'counterparty_user_id',
      'counterparty_id'
    ),
    public.score_v22_json_uuid(
      p_context -> 'iou',
      'lender_id',
      'counterparty_user_id',
      'counterparty_id'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_context_principal_cents(
  p_context jsonb
)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_cents bigint;
  v_amount_text text;
BEGIN
  v_cents := COALESCE(
    public.score_v22_json_bigint(
      p_context -> 'score_agreement',
      'principal_cents',
      'amount_cents',
      'original_principal_cents'
    ),
    public.score_v22_json_bigint(
      p_context -> 'iou',
      'principal_cents',
      'amount_cents',
      'original_principal_cents'
    )
  );

  IF v_cents IS NOT NULL THEN
    RETURN GREATEST(v_cents, 0);
  END IF;

  v_amount_text := COALESCE(
    public.score_v22_json_text(
      p_context -> 'score_agreement',
      'principal',
      'amount'
    ),
    public.score_v22_json_text(
      p_context -> 'iou',
      'principal',
      'amount'
    )
  );

  IF v_amount_text IS NULL THEN
    RETURN 0;
  END IF;

  BEGIN
    RETURN GREATEST(round(v_amount_text::numeric * 100)::bigint, 0);
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RETURN 0;
  END;
END
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_context_anchor_at(
  p_context jsonb
)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT COALESCE(
    public.score_v22_json_timestamptz(
      p_context -> 'score_agreement',
      'activated_at',
      'created_at',
      'accepted_at'
    ),
    public.score_v22_json_timestamptz(
      p_context -> 'iou',
      'activated_at',
      'created_at',
      'accepted_at'
    ),
    'epoch'::timestamptz
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_context_domain(
  p_context jsonb
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT lower(COALESCE(
    public.score_v22_json_text(
      p_context -> 'score_agreement',
      'domain',
      'score_domain',
      'agreement_type',
      'category'
    ),
    public.score_v22_json_text(
      p_context -> 'iou',
      'domain',
      'score_domain',
      'agreement_type',
      'category'
    ),
    'personal_iou'
  ));
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_is_personal_iou_domain(
  p_domain text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT lower(COALESCE(p_domain, 'personal_iou')) IN (
    'personal_iou',
    'personal',
    'iou',
    'standard_iou',
    'standard',
    'personal_loan',
    'loan'
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_same_pair_index(
  p_score_agreement_id uuid
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_context jsonb;
  v_borrower_id uuid;
  v_lender_id uuid;
  v_anchor_at timestamptz;
  v_count integer;
BEGIN
  v_context := public.score_v22_agreement_context(p_score_agreement_id);
  v_borrower_id := public.score_v22_context_borrower_id(v_context);
  v_lender_id := public.score_v22_context_lender_id(v_context);
  v_anchor_at := public.score_v22_context_anchor_at(v_context);

  IF NOT public.score_v22_is_personal_iou_domain(
    public.score_v22_context_domain(v_context)
  ) THEN
    RAISE EXCEPTION
      'Score agreement % is not a personal IOU domain',
      p_score_agreement_id;
  END IF;

  IF v_borrower_id IS NULL OR v_lender_id IS NULL THEN
    RAISE EXCEPTION
      'Score agreement % is missing borrower/lender identity',
      p_score_agreement_id;
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.score_agreements AS prior
  CROSS JOIN LATERAL public.score_v22_agreement_context(prior.id)
    AS prior_context(context_json)
  WHERE public.score_v22_context_borrower_id(prior_context.context_json) = v_borrower_id
    AND public.score_v22_context_lender_id(prior_context.context_json) = v_lender_id
    AND public.score_v22_is_personal_iou_domain(
      public.score_v22_context_domain(prior_context.context_json)
    )
    AND public.score_v22_context_anchor_at(prior_context.context_json)
          > v_anchor_at - interval '2 years'
    AND (
      public.score_v22_context_anchor_at(prior_context.context_json) < v_anchor_at
      OR (
        public.score_v22_context_anchor_at(prior_context.context_json) = v_anchor_at
        AND prior.id::text <= p_score_agreement_id::text
      )
    );

  RETURN GREATEST(COALESCE(v_count, 0), 1);
END
$function$;

-- --------------------------------------------------------------------------
-- 5. Deterministic ceiling.
--
-- Personal-IOU amount calibration anchors approved during v2 design:
--   $20=1, $40=2, $50=3, $100=7, $200=12, $250=16,
--   $480=29, $500=35, $750=45, $1,000=56, $2,000=104,
--   $5,000=200.
--
-- Values between anchors use deterministic linear interpolation.
-- Same-pair multiplier: 0.80^(pair_index - 1), rounded to nearest point.
-- No permanent minimum is applied, so repeated pair farming converges to zero.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_personal_iou_base_ceiling(
  p_principal_cents bigint
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_x bigint := GREATEST(COALESCE(p_principal_cents, 0), 0);
  v_amounts bigint[] := ARRAY[
    0, 2000, 4000, 5000, 10000, 20000, 25000,
    48000, 50000, 75000, 100000, 200000, 500000
  ];
  v_points integer[] := ARRAY[
    0, 1, 2, 3, 7, 12, 16,
    29, 35, 45, 56, 104, 200
  ];
  i integer;
  v_result numeric;
BEGIN
  IF v_x <= 0 THEN
    RETURN 0;
  END IF;

  IF v_x >= v_amounts[array_length(v_amounts, 1)] THEN
    RETURN v_points[array_length(v_points, 1)];
  END IF;

  FOR i IN 2..array_length(v_amounts, 1) LOOP
    IF v_x <= v_amounts[i] THEN
      v_result :=
        v_points[i - 1]
        + (
          (v_x - v_amounts[i - 1])::numeric
          * (v_points[i] - v_points[i - 1])::numeric
          / NULLIF((v_amounts[i] - v_amounts[i - 1])::numeric, 0)
        );
      RETURN GREATEST(round(v_result)::integer, 0);
    END IF;
  END LOOP;

  RETURN 200;
END
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_ceiling_for_pair_index(
  p_principal_cents bigint,
  p_pair_index integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT GREATEST(
    round(
      public.score_v22_personal_iou_base_ceiling(p_principal_cents)::numeric
      * power(0.80::numeric, GREATEST(COALESCE(p_pair_index, 1), 1) - 1)
    )::integer,
    0
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_agreement_ceiling(
  p_score_agreement_id uuid
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_context jsonb;
  v_principal_cents bigint;
  v_pair_index integer;
BEGIN
  v_context := public.score_v22_agreement_context(p_score_agreement_id);

  IF NOT public.score_v22_is_personal_iou_domain(
    public.score_v22_context_domain(v_context)
  ) THEN
    RAISE EXCEPTION
      'Score agreement % is not a personal IOU domain',
      p_score_agreement_id;
  END IF;

  v_principal_cents := public.score_v22_context_principal_cents(v_context);
  v_pair_index := public.score_v22_same_pair_index(p_score_agreement_id);

  RETURN public.score_v22_ceiling_for_pair_index(
    v_principal_cents,
    v_pair_index
  );
END
$function$;

-- --------------------------------------------------------------------------
-- 6. Late severity and deterministic penalty points.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_late_penalty_rate(
  p_days_late integer
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT CASE
    WHEN p_days_late IS NULL OR p_days_late <= 0 THEN 0.00::numeric
    WHEN p_days_late <= 3 THEN 0.15::numeric
    WHEN p_days_late <= 7 THEN 0.30::numeric
    WHEN p_days_late <= 14 THEN 0.50::numeric
    WHEN p_days_late <= 30 THEN 0.75::numeric
    ELSE 1.00::numeric
  END;
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_late_penalty_points(
  p_agreement_ceiling integer,
  p_principal_cents bigint,
  p_installment_cents bigint,
  p_days_late integer
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_proportional_ceiling numeric;
  v_proportional_cap integer;
  v_rate numeric;
  v_penalty integer;
BEGIN
  IF COALESCE(p_agreement_ceiling, 0) <= 0
     OR COALESCE(p_principal_cents, 0) <= 0
     OR COALESCE(p_installment_cents, 0) <= 0
     OR COALESCE(p_days_late, 0) <= 0 THEN
    RETURN 0;
  END IF;

  v_proportional_ceiling :=
    p_agreement_ceiling::numeric
    * LEAST(
        p_installment_cents::numeric / p_principal_cents::numeric,
        1.00::numeric
      );

  v_proportional_cap := GREATEST(round(v_proportional_ceiling)::integer, 1);
  v_rate := public.score_v22_late_penalty_rate(p_days_late);
  v_penalty := GREATEST(round(v_proportional_ceiling * v_rate)::integer, 1);

  RETURN LEAST(v_penalty, v_proportional_cap);
END
$function$;

-- --------------------------------------------------------------------------
-- 7. Outcome/payment adapters.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_event_type(
  p_event jsonb
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT lower(COALESCE(
    public.score_v22_json_text(
      p_event,
      'outcome_type',
      'event_type',
      'type',
      'outcome'
    ),
    ''
  ));
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_event_at(
  p_event jsonb
)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT COALESCE(
    public.score_v22_json_timestamptz(
      p_event,
      'outcome_at',
      'occurred_at',
      'event_at',
      'created_at'
    ),
    'epoch'::timestamptz
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_event_payment_id(
  p_event jsonb
)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT COALESCE(
    public.score_v22_json_uuid(
      p_event,
      'payment_id',
      'source_payment_id'
    ),
    public.score_v22_json_uuid(
      COALESCE(p_event -> 'metadata', '{}'::jsonb),
      'payment_id',
      'source_payment_id'
    ),
    public.score_v22_json_uuid(
      COALESCE(p_event -> 'evidence', '{}'::jsonb),
      'payment_id',
      'source_payment_id'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_event_score_agreement_id(
  p_event jsonb
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_candidate uuid;
  v_iou_id uuid;
  v_score_agreement_id uuid;
BEGIN
  v_candidate := COALESCE(
    public.score_v22_json_uuid(
      p_event,
      'score_agreement_id',
      'agreement_id'
    ),
    public.score_v22_json_uuid(
      COALESCE(p_event -> 'metadata', '{}'::jsonb),
      'score_agreement_id',
      'agreement_id'
    )
  );

  IF v_candidate IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.score_agreements
       WHERE id = v_candidate
     ) THEN
    RETURN v_candidate;
  END IF;

  v_iou_id := COALESCE(
    public.score_v22_json_uuid(
      p_event,
      'iou_id',
      'source_iou_id'
    ),
    public.score_v22_json_uuid(
      COALESCE(p_event -> 'metadata', '{}'::jsonb),
      'iou_id',
      'source_iou_id'
    ),
    v_candidate
  );

  IF v_iou_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT sa.id
  INTO v_score_agreement_id
  FROM public.score_agreements AS sa
  WHERE public.score_v22_json_uuid(
          to_jsonb(sa),
          'iou_id',
          'agreement_id',
          'source_iou_id'
        ) = v_iou_id
  ORDER BY sa.id
  LIMIT 1;

  RETURN v_score_agreement_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_payment_json(
  p_payment_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT to_jsonb(p)
  FROM public.payments AS p
  WHERE p.id = p_payment_id;
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_payment_amount_cents(
  p_payment jsonb,
  p_event jsonb
)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_cents bigint;
  v_amount text;
BEGIN
  v_cents := COALESCE(
    public.score_v22_json_bigint(
      p_payment,
      'amount_cents',
      'scheduled_amount_cents',
      'principal_cents',
      'payment_amount_cents'
    ),
    public.score_v22_json_bigint(
      p_event,
      'amount_cents',
      'scheduled_amount_cents',
      'payment_amount_cents'
    ),
    public.score_v22_json_bigint(
      COALESCE(p_event -> 'metadata', '{}'::jsonb),
      'amount_cents',
      'scheduled_amount_cents',
      'payment_amount_cents'
    )
  );

  IF v_cents IS NOT NULL THEN
    RETURN GREATEST(v_cents, 0);
  END IF;

  v_amount := COALESCE(
    public.score_v22_json_text(p_payment, 'amount', 'payment_amount'),
    public.score_v22_json_text(p_event, 'amount', 'payment_amount'),
    public.score_v22_json_text(
      COALESCE(p_event -> 'metadata', '{}'::jsonb),
      'amount',
      'payment_amount'
    )
  );

  IF v_amount IS NULL THEN
    RETURN 0;
  END IF;

  BEGIN
    RETURN GREATEST(round(v_amount::numeric * 100)::bigint, 0);
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RETURN 0;
  END;
END
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_payment_due_at(
  p_payment jsonb,
  p_event jsonb
)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT COALESCE(
    public.score_v22_json_timestamptz(
      p_payment,
      'due_at',
      'due_date'
    ),
    public.score_v22_json_timestamptz(
      p_event,
      'due_at',
      'due_date'
    ),
    public.score_v22_json_timestamptz(
      COALESCE(p_event -> 'metadata', '{}'::jsonb),
      'due_at',
      'due_date'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_payment_paid_at(
  p_payment jsonb,
  p_event jsonb
)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT COALESCE(
    public.score_v22_json_timestamptz(
      p_payment,
      'paid_at',
      'settled_at',
      'completed_at'
    ),
    public.score_v22_json_timestamptz(
      p_event,
      'paid_at',
      'settled_at',
      'completed_at',
      'outcome_at'
    ),
    public.score_v22_json_timestamptz(
      COALESCE(p_event -> 'metadata', '{}'::jsonb),
      'paid_at',
      'settled_at',
      'completed_at'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.score_v22_days_late(
  p_payment jsonb,
  p_event jsonb
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_explicit bigint;
  v_due_at timestamptz;
  v_paid_at timestamptz;
BEGIN
  v_explicit := COALESCE(
    public.score_v22_json_bigint(p_event, 'days_late'),
    public.score_v22_json_bigint(
      COALESCE(p_event -> 'metadata', '{}'::jsonb),
      'days_late'
    )
  );

  IF v_explicit IS NOT NULL THEN
    RETURN GREATEST(v_explicit::integer, 0);
  END IF;

  v_due_at := public.score_v22_payment_due_at(p_payment, p_event);
  v_paid_at := public.score_v22_payment_paid_at(p_payment, p_event);

  IF v_due_at IS NULL OR v_paid_at IS NULL OR v_paid_at <= v_due_at THEN
    RETURN 0;
  END IF;

  RETURN GREATEST(
    ceil(extract(epoch FROM (v_paid_at - v_due_at)) / 86400.0)::integer,
    1
  );
END
$function$;

-- --------------------------------------------------------------------------
-- 8. Append-only contribution writer.
--    Optional user/domain columns are populated when they exist.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_insert_contribution(
  p_score_agreement_id uuid,
  p_outcome_event_id uuid,
  p_subject_user_id uuid,
  p_contribution_type text,
  p_impact_direction text,
  p_points_awarded integer,
  p_source_outcome_at timestamptz,
  p_agreement_ceiling integer,
  p_pair_index integer,
  p_calculation_details jsonb,
  p_source_outcome_type text,
  p_points_cap integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_columns text :=
    'score_agreement_id, outcome_event_id, contribution_type, model_version, '
    'impact_direction, points_awarded, calculation_details, source_outcome_at, '
    'agreement_ceiling, pair_index, source_outcome_type, points_cap';
  v_values text := '$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12';
  v_sql text;
  v_row_count integer := 0;
BEGIN
  IF p_points_awarded < 0 THEN
    RAISE EXCEPTION 'points_awarded must be nonnegative';
  END IF;

  IF p_impact_direction NOT IN ('reward', 'penalty') THEN
    RAISE EXCEPTION 'Invalid impact direction: %', p_impact_direction;
  END IF;

  IF NULLIF(btrim(p_source_outcome_type), '') IS NULL THEN
    RAISE EXCEPTION 'source_outcome_type is required';
  END IF;

  IF p_points_cap IS NULL OR p_points_cap < 0 THEN
    RAISE EXCEPTION 'points_cap must be nonnegative';
  END IF;

  IF p_points_awarded > p_points_cap THEN
    RAISE EXCEPTION
      'points_awarded % exceeds points_cap %',
      p_points_awarded,
      p_points_cap;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'user_id'
      AND NOT attisdropped
  ) THEN
    v_columns := v_columns || ', user_id';
    v_values := v_values || ', $13';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'subject_user_id'
      AND NOT attisdropped
  ) THEN
    v_columns := v_columns || ', subject_user_id';
    v_values := v_values || ', $13';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'borrower_id'
      AND NOT attisdropped
  ) THEN
    v_columns := v_columns || ', borrower_id';
    v_values := v_values || ', $13';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'domain'
      AND NOT attisdropped
  ) THEN
    v_columns := v_columns || ', domain';
    v_values := v_values || ', $14';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.score_v2_contributions'::regclass
      AND attname = 'score_domain'
      AND NOT attisdropped
  ) THEN
    v_columns := v_columns || ', score_domain';
    v_values := v_values || ', $14';
  END IF;

  v_sql := format(
    'INSERT INTO public.score_v2_contributions (%s) '
    'VALUES (%s) '
    'ON CONFLICT DO NOTHING',
    v_columns,
    v_values
  );

  EXECUTE v_sql
  USING
    p_score_agreement_id,
    p_outcome_event_id,
    p_contribution_type,
    'v2.2-shadow',
    p_impact_direction,
    p_points_awarded,
    COALESCE(p_calculation_details, '{}'::jsonb),
    p_source_outcome_at,
    p_agreement_ceiling,
    p_pair_index,
    p_source_outcome_type,
    p_points_cap,
    p_subject_user_id,
    'personal_iou';

  GET DIAGNOSTICS v_row_count = ROW_COUNT;
  RETURN v_row_count = 1;
END
$function$;

-- --------------------------------------------------------------------------
-- 9. Pure evaluator used by regression tests and explainability.
--
-- Installment JSON shape:
--   {
--     "amount_cents": 25000,
--     "outcome": "early" | "on_time" | "late",
--     "days_late": 1,
--     "outcome_at": "2026-06-20T12:00:00Z"
--   }
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_evaluate_personal_iou(
  p_agreement_ceiling integer,
  p_principal_cents bigint,
  p_installments jsonb,
  p_completed_at timestamptz DEFAULT NULL,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_cutoff timestamptz := p_as_of - interval '2 years';
  v_base_reward integer :=
    GREATEST(COALESCE(p_agreement_ceiling, 0), 0)
    - round(GREATEST(COALESCE(p_agreement_ceiling, 0), 0) * 0.20)::integer;
  v_early_pool integer :=
    round(GREATEST(COALESCE(p_agreement_ceiling, 0), 0) * 0.20)::integer;
  v_paid_cents bigint := 0;
  v_pending_completion integer := 0;
  v_early_earned integer := 0;
  v_penalties integer := 0;
  v_completed_active boolean :=
    p_completed_at IS NOT NULL
    AND p_completed_at <= p_as_of
    AND p_completed_at > v_cutoff;
  v_item jsonb;
  v_amount bigint;
  v_outcome text;
  v_days integer;
  v_event_at timestamptz;
  v_penalty integer;
BEGIN
  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(p_installments, '[]'::jsonb))
  LOOP
    v_amount := GREATEST(
      COALESCE(public.score_v22_json_bigint(v_item, 'amount_cents'), 0),
      0
    );
    v_outcome := lower(COALESCE(
      public.score_v22_json_text(v_item, 'outcome', 'outcome_type'),
      ''
    ));
    v_days := GREATEST(
      COALESCE(public.score_v22_json_bigint(v_item, 'days_late'), 0)::integer,
      0
    );
    v_event_at := COALESCE(
      public.score_v22_json_timestamptz(v_item, 'outcome_at', 'event_at'),
      'epoch'::timestamptz
    );

    IF v_outcome IN ('early', 'on_time', 'late') AND v_event_at <= p_as_of THEN
      v_paid_cents := v_paid_cents + v_amount;
    END IF;

    IF v_event_at > v_cutoff AND v_event_at <= p_as_of THEN
      IF v_outcome = 'early' THEN
        v_early_earned := v_early_pool;
      ELSIF v_outcome = 'late' THEN
        v_penalty := public.score_v22_late_penalty_points(
          p_agreement_ceiling,
          p_principal_cents,
          v_amount,
          v_days
        );
        v_penalties := v_penalties + v_penalty;
      END IF;
    END IF;
  END LOOP;

  IF COALESCE(p_principal_cents, 0) > 0 THEN
    v_pending_completion := round(
      v_base_reward::numeric
      * LEAST(
          v_paid_cents::numeric / p_principal_cents::numeric,
          1.00::numeric
        )
    )::integer;
  END IF;

  RETURN jsonb_build_object(
    'agreement_ceiling', GREATEST(COALESCE(p_agreement_ceiling, 0), 0),
    'base_completion_reward', v_base_reward,
    'early_bonus_pool', v_early_pool,
    'paid_cents', LEAST(v_paid_cents, GREATEST(COALESCE(p_principal_cents, 0), 0)),
    'principal_cents', GREATEST(COALESCE(p_principal_cents, 0), 0),
    'pending_completion_points', v_pending_completion,
    'pending_early_bonus', v_early_earned,
    'active_penalties', v_penalties,
    'gross_points_earned', v_pending_completion + v_early_earned,
    'projected_net_contribution',
      v_pending_completion + v_early_earned - v_penalties,
    'positive_points_unlocked', v_completed_active,
    'public_score_effect',
      (CASE WHEN v_completed_active
        THEN v_base_reward + v_early_earned
        ELSE 0
      END) - v_penalties,
    'evidence_cutoff', v_cutoff,
    'as_of', p_as_of
  );
END
$function$;

-- --------------------------------------------------------------------------
-- 10. Per-agreement recalculation.
--     This function never updates/deletes contribution rows.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_recalculate_agreement(
  p_score_agreement_id uuid,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_context jsonb;
  v_subject_user_id uuid;
  v_principal_cents bigint;
  v_pair_index integer;
  v_ceiling integer;
  v_early_pool integer;
  v_base_reward integer;

  v_event record;
  v_event_json jsonb;
  v_event_type text;
  v_event_at timestamptz;
  v_payment_id uuid;
  v_payment_json jsonb;
  v_installment_cents bigint;
  v_days_late integer;
  v_penalty_points integer;

  v_completion_event_id uuid;
  v_completion_at timestamptz;
  v_completion_event_type text;
  v_qualifying_early_event_id uuid;
  v_qualifying_early_at timestamptz;
  v_qualifying_early_event_type text;

  v_inserted_penalties integer := 0;
  v_inserted_completion integer := 0;
  v_inserted_early integer := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(
    hashtextextended('score-v2.2:' || p_score_agreement_id::text, 0)
  );

  v_context := public.score_v22_agreement_context(p_score_agreement_id);

  IF NOT public.score_v22_is_personal_iou_domain(
    public.score_v22_context_domain(v_context)
  ) THEN
    RETURN jsonb_build_object(
      'score_agreement_id', p_score_agreement_id,
      'model_version', 'v2.2-shadow',
      'skipped', true,
      'reason', 'non_personal_iou_domain',
      'domain', public.score_v22_context_domain(v_context)
    );
  END IF;

  v_subject_user_id := public.score_v22_context_borrower_id(v_context);
  v_principal_cents := public.score_v22_context_principal_cents(v_context);
  v_pair_index := public.score_v22_same_pair_index(p_score_agreement_id);
  v_ceiling := public.score_v22_ceiling_for_pair_index(
    v_principal_cents,
    v_pair_index
  );
  v_early_pool := round(v_ceiling * 0.20)::integer;
  v_base_reward := v_ceiling - v_early_pool;

  IF v_subject_user_id IS NULL THEN
    RAISE EXCEPTION
      'Cannot recalculate score agreement % without borrower/subject user',
      p_score_agreement_id;
  END IF;

  IF v_principal_cents <= 0 THEN
    RAISE EXCEPTION
      'Cannot recalculate score agreement % without positive principal cents',
      p_score_agreement_id;
  END IF;

  FOR v_event IN
    SELECT e.id, to_jsonb(e) AS event_json
    FROM public.trust_outcome_events AS e
    WHERE public.score_v22_event_score_agreement_id(to_jsonb(e))
          = p_score_agreement_id
      AND public.score_v22_event_at(to_jsonb(e)) <= p_as_of
    ORDER BY public.score_v22_event_at(to_jsonb(e)), e.id
  LOOP
    v_event_json := v_event.event_json;
    v_event_type := public.score_v22_event_type(v_event_json);
    v_event_at := public.score_v22_event_at(v_event_json);

    IF v_event_at = 'epoch'::timestamptz THEN
      RAISE EXCEPTION
        'Score v2.2 cannot process outcome event % without a valid evidence timestamp',
        v_event.id;
    END IF;

    IF v_event_type IN (
      'agreement_completed',
      'iou_completed',
      'loan_completed',
      'agreement_completion'
    ) THEN
      IF v_completion_at IS NULL THEN
        v_completion_event_id := v_event.id;
        v_completion_at := v_event_at;
        v_completion_event_type := v_event_type;
      END IF;

    ELSIF v_event_type IN (
      'payment_paid_early',
      'payment_early'
    ) THEN
      IF v_qualifying_early_at IS NULL THEN
        v_qualifying_early_event_id := v_event.id;
        v_qualifying_early_at := v_event_at;
        v_qualifying_early_event_type := v_event_type;
      END IF;

    ELSIF v_event_type IN (
      'payment_paid_late',
      'payment_late'
    ) THEN
      v_payment_id := public.score_v22_event_payment_id(v_event_json);
      v_payment_json := public.score_v22_payment_json(v_payment_id);
      v_installment_cents := public.score_v22_payment_amount_cents(
        v_payment_json,
        v_event_json
      );
      v_days_late := public.score_v22_days_late(
        v_payment_json,
        v_event_json
      );

      IF v_installment_cents <= 0 THEN
        RAISE EXCEPTION
          'Late outcome event % has no positive installment amount',
          v_event.id;
      END IF;

      IF v_days_late <= 0 THEN
        RAISE EXCEPTION
          'Late outcome event % has no positive days-late evidence',
          v_event.id;
      END IF;

      v_penalty_points := public.score_v22_late_penalty_points(
        v_ceiling,
        v_principal_cents,
        v_installment_cents,
        v_days_late
      );

      IF v_penalty_points > 0 AND public.score_v22_insert_contribution(
        p_score_agreement_id,
        v_event.id,
        v_subject_user_id,
        'payment_late_penalty',
        'penalty',
        v_penalty_points,
        v_event_at,
        v_ceiling,
        v_pair_index,
        jsonb_build_object(
          'model_version', 'v2.2-shadow',
          'rule', 'agreement_ceiling_x_installment_share_x_lateness_severity',
          'agreement_ceiling', v_ceiling,
          'principal_cents', v_principal_cents,
          'installment_cents', v_installment_cents,
          'installment_share',
            round(v_installment_cents::numeric / v_principal_cents::numeric, 8),
          'days_late', v_days_late,
          'severity_rate', public.score_v22_late_penalty_rate(v_days_late),
          'points', v_penalty_points,
          'payment_id', v_payment_id,
          'outcome_event_id', v_event.id
        ),
        v_event_type,
        GREATEST(
          round(
            v_ceiling::numeric
            * LEAST(
                v_installment_cents::numeric
                / v_principal_cents::numeric,
                1.00::numeric
              )
          )::integer,
          1
        )
      ) THEN
        v_inserted_penalties := v_inserted_penalties + 1;
      END IF;
    END IF;
  END LOOP;

  IF v_completion_event_id IS NOT NULL THEN
    IF public.score_v22_insert_contribution(
      p_score_agreement_id,
      v_completion_event_id,
      v_subject_user_id,
      'agreement_completion',
      'reward',
      v_base_reward,
      v_completion_at,
      v_ceiling,
      v_pair_index,
      jsonb_build_object(
        'model_version', 'v2.2-shadow',
        'rule', 'completion_unlocks_base_reward',
        'agreement_ceiling', v_ceiling,
        'base_completion_reward', v_base_reward,
        'early_bonus_pool', v_early_pool,
        'pair_index', v_pair_index,
        'principal_cents', v_principal_cents,
        'outcome_event_id', v_completion_event_id
      ),
      v_completion_event_type,
      v_base_reward
    ) THEN
      v_inserted_completion := 1;
    END IF;

    -- The bonus is linked to the qualifying early event, not the completion
    -- event. Therefore the bonus expires exactly two years after its own
    -- evidence timestamp.
    IF v_qualifying_early_event_id IS NOT NULL
       AND v_qualifying_early_at <= v_completion_at
       AND v_early_pool > 0
       AND public.score_v22_insert_contribution(
         p_score_agreement_id,
         v_qualifying_early_event_id,
         v_subject_user_id,
         'early_payment_bonus',
         'reward',
         v_early_pool,
         v_qualifying_early_at,
         v_ceiling,
         v_pair_index,
         jsonb_build_object(
           'model_version', 'v2.2-shadow',
           'rule', 'any_qualifying_early_installment_earns_capped_bonus_unlocked_at_completion',
           'agreement_ceiling', v_ceiling,
           'early_bonus_pool', v_early_pool,
           'qualifying_early_outcome_event_id', v_qualifying_early_event_id,
           'qualifying_early_outcome_at', v_qualifying_early_at,
           'completion_outcome_event_id', v_completion_event_id,
           'completion_outcome_at', v_completion_at
         ),
         v_qualifying_early_event_type,
         v_early_pool
       ) THEN
      v_inserted_early := 1;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'score_agreement_id', p_score_agreement_id,
    'model_version', 'v2.2-shadow',
    'pair_index', v_pair_index,
    'agreement_ceiling', v_ceiling,
    'base_completion_reward', v_base_reward,
    'early_bonus_pool', v_early_pool,
    'completion_event_id', v_completion_event_id,
    'qualifying_early_event_id', v_qualifying_early_event_id,
    'inserted_penalties', v_inserted_penalties,
    'inserted_completion', v_inserted_completion,
    'inserted_early_bonus', v_inserted_early
  );
END
$function$;

-- --------------------------------------------------------------------------
-- 11. Strictly score-active v2.2 contributions.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.score_v22_effective_contributions
WITH (security_invoker = true)
AS
SELECT
  c.*,
  CASE
    WHEN c.impact_direction = 'penalty' THEN -c.points_awarded
    ELSE c.points_awarded
  END AS signed_points
FROM public.score_v2_contributions AS c
JOIN public.trust_outcome_events AS e
  ON e.id = c.outcome_event_id
WHERE c.model_version = 'v2.2-shadow'
  AND public.score_v22_event_at(to_jsonb(e))
      > now() - interval '2 years';

COMMENT ON VIEW public.score_v22_effective_contributions IS
  'Score v2.2 contributions whose exact linked evidence event is newer than the strict two-year cutoff. At exactly two years old, the contribution is excluded.';

-- --------------------------------------------------------------------------
-- 12. Pending progress and authenticated RPC.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_pending_agreement_progress(
  p_score_agreement_id uuid,
  p_as_of timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_context jsonb;
  v_principal_cents bigint;
  v_pair_index integer;
  v_ceiling integer;
  v_early_pool integer;
  v_base_reward integer;
  v_paid_cents bigint := 0;
  v_pending_completion integer := 0;
  v_early_earned integer := 0;
  v_active_penalties integer := 0;
  v_completion_at timestamptz;
  v_completed_active boolean := false;
  v_cutoff timestamptz := p_as_of - interval '2 years';
BEGIN
  v_context := public.score_v22_agreement_context(p_score_agreement_id);

  IF NOT public.score_v22_is_personal_iou_domain(
    public.score_v22_context_domain(v_context)
  ) THEN
    RAISE EXCEPTION
      'Score agreement % is not a personal IOU domain',
      p_score_agreement_id;
  END IF;

  v_principal_cents := public.score_v22_context_principal_cents(v_context);
  v_pair_index := public.score_v22_same_pair_index(p_score_agreement_id);
  v_ceiling := public.score_v22_ceiling_for_pair_index(
    v_principal_cents,
    v_pair_index
  );
  v_early_pool := round(v_ceiling * 0.20)::integer;
  v_base_reward := v_ceiling - v_early_pool;

  SELECT COALESCE(sum(
    public.score_v22_payment_amount_cents(to_jsonb(p), '{}'::jsonb)
  ), 0)::bigint
  INTO v_paid_cents
  FROM public.payments AS p
  WHERE (
      public.score_v22_json_uuid(
        to_jsonb(p),
        'score_agreement_id'
      ) = p_score_agreement_id
      OR public.score_v22_json_uuid(
          to_jsonb(p),
          'iou_id',
          'agreement_id',
          'source_iou_id'
        ) = public.score_v22_json_uuid(
          v_context -> 'iou',
          'id',
          'iou_id'
        )
    )
    AND (
      public.score_v22_json_timestamptz(
        to_jsonb(p),
        'paid_at',
        'settled_at',
        'completed_at'
      ) IS NOT NULL
      OR lower(COALESCE(
        public.score_v22_json_text(to_jsonb(p), 'status'),
        ''
      )) = 'paid'
    );

  IF v_principal_cents > 0 THEN
    v_pending_completion := round(
      v_base_reward::numeric
      * LEAST(v_paid_cents::numeric / v_principal_cents::numeric, 1.00::numeric)
    )::integer;
  END IF;

  SELECT min(public.score_v22_event_at(to_jsonb(e)))
  INTO v_completion_at
  FROM public.trust_outcome_events AS e
  WHERE public.score_v22_event_score_agreement_id(to_jsonb(e))
        = p_score_agreement_id
    AND public.score_v22_event_type(to_jsonb(e)) IN (
      'agreement_completed',
      'iou_completed',
      'loan_completed',
      'agreement_completion'
    )
    AND public.score_v22_event_at(to_jsonb(e)) <= p_as_of;

  v_completed_active :=
    v_completion_at IS NOT NULL
    AND v_completion_at > v_cutoff;

  IF EXISTS (
    SELECT 1
    FROM public.trust_outcome_events AS e
    WHERE public.score_v22_event_score_agreement_id(to_jsonb(e))
          = p_score_agreement_id
      AND public.score_v22_event_type(to_jsonb(e)) IN (
        'payment_paid_early',
        'payment_early'
      )
      AND public.score_v22_event_at(to_jsonb(e)) > v_cutoff
      AND public.score_v22_event_at(to_jsonb(e)) <= p_as_of
      AND (
        v_completion_at IS NULL
        OR public.score_v22_event_at(to_jsonb(e)) <= v_completion_at
      )
  ) THEN
    v_early_earned := v_early_pool;
  END IF;

  SELECT COALESCE(sum(c.points_awarded), 0)::integer
  INTO v_active_penalties
  FROM public.score_v2_contributions AS c
  JOIN public.trust_outcome_events AS e
    ON e.id = c.outcome_event_id
  WHERE c.score_agreement_id = p_score_agreement_id
    AND c.model_version = 'v2.2-shadow'
    AND c.impact_direction = 'penalty'
    AND public.score_v22_event_at(to_jsonb(e)) > v_cutoff
    AND public.score_v22_event_at(to_jsonb(e)) <= p_as_of;

  RETURN jsonb_build_object(
    'score_agreement_id', p_score_agreement_id,
    'model_version', 'v2.2-shadow',
    'pair_index', v_pair_index,
    'agreement_ceiling', v_ceiling,
    'principal_cents', v_principal_cents,
    'paid_cents', LEAST(v_paid_cents, v_principal_cents),
    'repayment_fraction',
      CASE
        WHEN v_principal_cents > 0
        THEN round(
          LEAST(v_paid_cents::numeric / v_principal_cents::numeric, 1.00::numeric),
          8
        )
        ELSE 0
      END,
    'completion_progress_points', v_pending_completion,
    'completion_reward_max', v_base_reward,
    'early_bonus_earned', v_early_earned,
    'early_bonus_max', v_early_pool,
    'active_penalties', v_active_penalties,
    'gross_points_earned', v_pending_completion + v_early_earned,
    'projected_net_contribution',
      v_pending_completion + v_early_earned - v_active_penalties,
    'current_public_score_effect',
      (CASE WHEN v_completed_active
        THEN v_base_reward + v_early_earned
        ELSE 0
      END) - v_active_penalties,
    'agreement_completed', v_completion_at IS NOT NULL,
    'positive_points_unlocked', v_completed_active,
    'positive_points_unlock_condition',
      CASE
        WHEN v_completed_active
        THEN 'unlocked'
        ELSE 'Positive points unlock when the IOU is completed'
      END,
    'completion_outcome_at', v_completion_at,
    'evidence_cutoff', v_cutoff,
    'as_of', p_as_of
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.get_my_score_v22_agreement_progress(
  p_score_agreement_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_context jsonb;
  v_borrower_id uuid;
  v_lender_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  v_context := public.score_v22_agreement_context(p_score_agreement_id);
  v_borrower_id := public.score_v22_context_borrower_id(v_context);
  v_lender_id := public.score_v22_context_lender_id(v_context);

  IF v_user_id IS DISTINCT FROM v_borrower_id
     AND v_user_id IS DISTINCT FROM v_lender_id THEN
    RAISE EXCEPTION 'Not authorized to view this agreement progress';
  END IF;

  RETURN public.score_v22_pending_agreement_progress(
    p_score_agreement_id,
    now()
  );
END
$function$;

-- --------------------------------------------------------------------------
-- 13. Register v2.2-shadow as the sole shadow model.
--     The block adapts to common registry column names but fails loudly if no
--     model identifier or shadow/status mechanism exists.
-- --------------------------------------------------------------------------
DO $register_model$
DECLARE
  v_id_column text;
  v_status_column text;
  v_has_is_shadow boolean;
  v_has_is_active boolean;
  v_has_description boolean;
  v_has_deprecated_at boolean;
  v_has_activated_at boolean;
  v_columns text := '';
  v_values text := '';
  v_sql text;
  v_shadow_count integer;
  v_source_exists boolean;
  v_target_exists boolean;
  v_separator text := '';
  v_expression text;
  r record;
BEGIN
  SELECT attname
  INTO v_id_column
  FROM pg_attribute
  WHERE attrelid = 'public.trust_model_versions'::regclass
    AND attname IN ('model_version', 'version', 'model_key', 'name')
    AND NOT attisdropped
  ORDER BY CASE attname
    WHEN 'model_version' THEN 1
    WHEN 'version' THEN 2
    WHEN 'model_key' THEN 3
    ELSE 4
  END
  LIMIT 1;

  IF v_id_column IS NULL THEN
    RAISE EXCEPTION
      'trust_model_versions has no supported model identifier column';
  END IF;

  SELECT attname
  INTO v_status_column
  FROM pg_attribute
  WHERE attrelid = 'public.trust_model_versions'::regclass
    AND attname IN ('lifecycle_status', 'status')
    AND NOT attisdropped
  ORDER BY CASE attname
    WHEN 'lifecycle_status' THEN 1
    ELSE 2
  END
  LIMIT 1;

  SELECT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.trust_model_versions'::regclass
      AND attname = 'is_shadow'
      AND NOT attisdropped
  ) INTO v_has_is_shadow;

  SELECT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.trust_model_versions'::regclass
      AND attname = 'is_active'
      AND NOT attisdropped
  ) INTO v_has_is_active;

  SELECT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.trust_model_versions'::regclass
      AND attname = 'description'
      AND NOT attisdropped
  ) INTO v_has_description;

  SELECT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.trust_model_versions'::regclass
      AND attname = 'deprecated_at'
      AND NOT attisdropped
  ) INTO v_has_deprecated_at;

  SELECT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.trust_model_versions'::regclass
      AND attname = 'activated_at'
      AND NOT attisdropped
  ) INTO v_has_activated_at;

  IF NOT v_has_is_shadow AND v_status_column IS NULL THEN
    RAISE EXCEPTION
      'trust_model_versions requires is_shadow or a status column';
  END IF;

  EXECUTE format(
    'SELECT EXISTS ('
    '  SELECT 1 FROM public.trust_model_versions '
    '  WHERE %I IN ($1, $2)'
    ')',
    v_id_column
  )
  INTO v_source_exists
  USING 'v2.1', 'v2.1-shadow';

  IF NOT v_source_exists THEN
    RAISE EXCEPTION
      'Cannot register v2.2-shadow because no v2.1 source model row exists to clone safely';
  END IF;

  -- Clone v2.1 so every existing required registry field is preserved, then
  -- override only the v2.2 identity/lifecycle/rule fields. This avoids making
  -- assumptions about registry columns that are not part of this migration.
  FOR r IN
    SELECT
      a.attname,
      pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
      a.attidentity,
      a.attgenerated,
      d.adbin IS NOT NULL AS has_default,
      EXISTS (
        SELECT 1
        FROM pg_constraint AS pc
        WHERE pc.conrelid = a.attrelid
          AND pc.contype = 'p'
          AND a.attnum = ANY(pc.conkey)
      ) AS is_primary_key
    FROM pg_attribute AS a
    LEFT JOIN pg_attrdef AS d
      ON d.adrelid = a.attrelid
     AND d.adnum = a.attnum
    WHERE a.attrelid = 'public.trust_model_versions'::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped
    ORDER BY a.attnum
  LOOP
    IF r.attgenerated <> '' OR r.attidentity <> '' THEN
      CONTINUE;
    END IF;

    IF r.is_primary_key AND r.attname <> v_id_column THEN
      IF r.has_default THEN
        CONTINUE;
      END IF;

      RAISE EXCEPTION
        'Cannot clone trust model registry: primary-key column % has no default',
        r.attname;
    END IF;

    v_expression := CASE
      WHEN r.attname = v_id_column THEN '$1'
      WHEN v_status_column IS NOT NULL AND r.attname = v_status_column THEN '$2'
      WHEN r.attname = 'is_shadow' THEN 'false'
      WHEN r.attname = 'is_active' THEN 'false'
      WHEN r.attname = 'description' THEN '$3'
      WHEN r.attname IN ('model_name', 'display_name', 'label')
        AND r.attname <> v_id_column
        THEN quote_literal('Score v2.2 Shadow')
      WHEN r.attname = 'deprecated_at' THEN 'NULL'
      WHEN r.attname IN ('activated_at', 'created_at', 'updated_at') THEN 'now()'
      WHEN r.attname = 'negative_outcomes_enabled' THEN 'true'
      WHEN r.attname = 'positive_outcomes_enabled' THEN 'true'
      WHEN r.attname IN ('on_time_fraction', 'payment_fraction') THEN '0.00'
      WHEN r.attname = 'early_fraction' THEN '0.20'
      WHEN r.attname = 'completion_fraction' THEN '0.80'
      WHEN r.attname = 'late_fraction' THEN '1.00'
      WHEN r.attname IN ('config', 'model_config', 'parameters', 'settings')
        AND r.data_type = 'jsonb'
        THEN format(
          '(COALESCE(src.%I, ''{}''::jsonb) || '
          '''{"on_time_fraction":0,"early_fraction":0.2,"completion_fraction":0.8,"negative_outcomes_enabled":true,"late_penalty_bands":{"1_3":0.15,"4_7":0.30,"8_14":0.50,"15_30":0.75,"31_plus":1.00}}''::jsonb)',
          r.attname
        )
      WHEN r.attname IN ('config', 'model_config', 'parameters', 'settings')
        AND r.data_type = 'json'
        THEN format(
          '((COALESCE(src.%I, ''{}''::json)::jsonb || '
          '''{"on_time_fraction":0,"early_fraction":0.2,"completion_fraction":0.8,"negative_outcomes_enabled":true,"late_penalty_bands":{"1_3":0.15,"4_7":0.30,"8_14":0.50,"15_30":0.75,"31_plus":1.00}}''::jsonb)::json)',
          r.attname
        )
      ELSE format('src.%I', r.attname)
    END;

    v_columns := v_columns || v_separator || format('%I', r.attname);
    v_values := v_values || v_separator || v_expression;
    v_separator := ', ';
  END LOOP;

  v_sql := format(
    'INSERT INTO public.trust_model_versions (%s) '
    'SELECT %s '
    'FROM public.trust_model_versions AS src '
    'WHERE src.%I IN ($4, $5) '
    '  AND NOT EXISTS ('
    '    SELECT 1 FROM public.trust_model_versions AS existing '
    '    WHERE existing.%I = $1'
    '  ) '
    'ORDER BY CASE src.%I WHEN $4 THEN 1 ELSE 2 END '
    'LIMIT 1 '
    'ON CONFLICT DO NOTHING',
    v_columns,
    v_values,
    v_id_column,
    v_id_column,
    v_id_column
  );

  EXECUTE v_sql
  USING
    'v2.2-shadow',
    'deprecated',
    'Score v2.2 personal IOU shadow model: completion-gated positives and per-installment late penalties',
    'v2.1',
    'v2.1-shadow';

  EXECUTE format(
    'SELECT EXISTS ('
    '  SELECT 1 FROM public.trust_model_versions WHERE %I = $1'
    ')',
    v_id_column
  )
  INTO v_target_exists
  USING 'v2.2-shadow';

  IF NOT v_target_exists THEN
    RAISE EXCEPTION 'Failed to register v2.2-shadow model row';
  END IF;

  -- Stage the lifecycle switch in two steps so an existing one-shadow
  -- unique index can never see two shadow rows, even transiently.
  IF v_status_column IS NOT NULL THEN
    EXECUTE format(
      'UPDATE public.trust_model_versions '
      'SET %I = $1 '
      'WHERE %I = $2 OR %I IN ($3, $4)',
      v_status_column,
      v_status_column,
      v_id_column
    )
    USING 'deprecated', 'shadow', 'v2.1-shadow', 'v2.1';

    EXECUTE format(
      'UPDATE public.trust_model_versions '
      'SET %I = $1 '
      'WHERE %I = $2',
      v_status_column,
      v_id_column
    )
    USING 'shadow', 'v2.2-shadow';
  END IF;

  IF v_has_is_shadow THEN
    EXECUTE
      'UPDATE public.trust_model_versions '
      'SET is_shadow = false '
      'WHERE is_shadow';

    EXECUTE format(
      'UPDATE public.trust_model_versions '
      'SET is_shadow = true '
      'WHERE %I = $1',
      v_id_column
    )
    USING 'v2.2-shadow';
  END IF;

  IF v_has_is_active THEN
    EXECUTE format(
      'UPDATE public.trust_model_versions '
      'SET is_active = false '
      'WHERE %I IN ($1, $2)',
      v_id_column
    )
    USING 'v2.1-shadow', 'v2.1';

    EXECUTE format(
      'UPDATE public.trust_model_versions '
      'SET is_active = true '
      'WHERE %I = $1',
      v_id_column
    )
    USING 'v2.2-shadow';
  END IF;

  IF v_has_deprecated_at THEN
    EXECUTE format(
      'UPDATE public.trust_model_versions '
      'SET deprecated_at = CASE '
      '  WHEN %I = $1 THEN NULL '
      '  WHEN %I IN ($2, $3) THEN COALESCE(deprecated_at, now()) '
      '  ELSE deprecated_at '
      'END '
      'WHERE %I IN ($1, $2, $3)',
      v_id_column,
      v_id_column,
      v_id_column
    )
    USING 'v2.2-shadow', 'v2.1-shadow', 'v2.1';
  END IF;

  IF v_has_is_shadow THEN
    EXECUTE
      'SELECT count(*) FROM public.trust_model_versions WHERE is_shadow'
    INTO v_shadow_count;
  ELSE
    EXECUTE format(
      'SELECT count(*) FROM public.trust_model_versions WHERE %I = $1',
      v_status_column
    )
    INTO v_shadow_count
    USING 'shadow';
  END IF;

  IF v_shadow_count <> 1 THEN
    RAISE EXCEPTION
      'Expected exactly one shadow model after v2.2 registration; found %',
      v_shadow_count;
  END IF;
END
$register_model$;

-- Enforce one shadow row at the registry level when the schema supports it.
DO $shadow_unique$
DECLARE
  v_has_is_shadow boolean;
  v_status_column text;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.trust_model_versions'::regclass
      AND attname = 'is_shadow'
      AND NOT attisdropped
  ) INTO v_has_is_shadow;

  SELECT attname
  INTO v_status_column
  FROM pg_attribute
  WHERE attrelid = 'public.trust_model_versions'::regclass
    AND attname IN ('lifecycle_status', 'status')
    AND NOT attisdropped
  ORDER BY CASE attname
    WHEN 'lifecycle_status' THEN 1
    ELSE 2
  END
  LIMIT 1;

  IF v_has_is_shadow THEN
    EXECUTE
      'CREATE UNIQUE INDEX IF NOT EXISTS trust_model_versions_one_shadow_uidx '
      'ON public.trust_model_versions ((1)) WHERE is_shadow';
  ELSIF v_status_column IS NOT NULL THEN
    EXECUTE format(
      'CREATE UNIQUE INDEX IF NOT EXISTS trust_model_versions_one_shadow_uidx '
      'ON public.trust_model_versions ((1)) WHERE %I = ''shadow''',
      v_status_column
    );
  END IF;
END
$shadow_unique$;

-- --------------------------------------------------------------------------
-- 14. Trigger dispatch.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.score_v22_dispatch_outcome_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event jsonb := to_jsonb(NEW);
  v_type text;
  v_score_agreement_id uuid;
BEGIN
  v_type := public.score_v22_event_type(v_event);

  IF v_type NOT IN (
    'payment_paid_early',
    'payment_early',
    'payment_paid_on_time',
    'payment_on_time',
    'payment_paid_late',
    'payment_late',
    'agreement_completed',
    'iou_completed',
    'loan_completed',
    'agreement_completion'
  ) THEN
    RETURN NEW;
  END IF;

  v_score_agreement_id :=
    public.score_v22_event_score_agreement_id(v_event);

  IF v_score_agreement_id IS NULL THEN
    RAISE EXCEPTION
      'Score v2.2 could not resolve score agreement for outcome event %',
      NEW.id;
  END IF;

  PERFORM public.score_v22_recalculate_agreement(
    v_score_agreement_id,
    public.score_v22_event_at(v_event)
  );

  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS trg_score_v22_dispatch_outcome_event
  ON public.trust_outcome_events;

CREATE TRIGGER trg_score_v22_dispatch_outcome_event
  AFTER INSERT ON public.trust_outcome_events
  FOR EACH ROW
  EXECUTE FUNCTION public.score_v22_dispatch_outcome_event();

-- --------------------------------------------------------------------------
-- 15. Backfill from immutable existing outcomes.
-- --------------------------------------------------------------------------
DO $backfill$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id
    FROM public.score_agreements
    ORDER BY id
  LOOP
    PERFORM public.score_v22_recalculate_agreement(r.id, now());
  END LOOP;
END
$backfill$;

-- --------------------------------------------------------------------------
-- 16. Permissions.
-- --------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.score_v22_agreement_context(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_same_pair_index(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_agreement_ceiling(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_event_score_agreement_id(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_payment_json(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_insert_contribution(
  uuid, uuid, uuid, text, text, integer, timestamptz, integer, integer, jsonb,
  text, integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_recalculate_agreement(uuid, timestamptz)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_pending_agreement_progress(uuid, timestamptz)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_score_v22_agreement_progress(uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_dispatch_outcome_event()
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.score_v22_block_contribution_mutation()
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_my_score_v22_agreement_progress(uuid)
  TO authenticated;

-- Final invariant.
DO $final_invariant$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*)
  INTO v_count
  FROM public.score_v2_contributions
  WHERE model_version IN ('v2.1-shadow', 'v2.1');

  -- This SELECT intentionally does not mutate v2.1. It documents that history
  -- is still present and reachable after the migration.
  RAISE NOTICE 'Preserved % v2.1 contribution rows unchanged', v_count;
END
$final_invariant$;
