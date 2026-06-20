-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: create_legal_acceptances_v3
-- Created:   2026-05-24
-- Purpose:   Append-only, idempotent consent ledger for platform-level
--            Terms of Service and Privacy Policy acceptance.
--            Scoped to pre-IOU consent. Does not touch iou_acceptance_audit.
--
-- Safe to run once via Supabase migration tooling.
-- All DDL statements are guarded against double-run where Postgres allows it.
-- Functions and trigger are CREATE OR REPLACE (unconditionally idempotent).
-- Constraints and policies use existence checks (see notes below).
--
-- Requires: PostgreSQL 14+ (CREATE OR REPLACE TRIGGER).
--           Supabase runs PostgreSQL 15 — this requirement is satisfied.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. Table ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.legal_acceptances (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid        NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  document_type    text        NOT NULL,
  document_version text        NOT NULL,
  document_hash    text        NULL,
  accepted_at      timestamptz NOT NULL DEFAULT now(),
  context          text        NOT NULL,
  related_iou_id   uuid        NULL REFERENCES public.ious(id) ON DELETE SET NULL,
  platform         text        NULL,
  app_version      text        NULL,
  device_metadata  jsonb       NULL,
  metadata         jsonb       NULL,
  created_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.legal_acceptances IS
  'Append-only consent ledger for platform Terms of Service and Privacy Policy. '
  'Separate from iou_acceptance_audit (signed IOU agreements). '
  'Do not UPDATE or DELETE rows. See trigger: legal_acceptances_block_mutation_trg.';


-- ── 2. Check constraints and unique constraint ────────────────────────────────
--
-- ALTER TABLE ... ADD CONSTRAINT has no IF NOT EXISTS syntax in Postgres.
-- Guards are implemented via pg_constraint existence checks inside a DO block.
-- Constraint names are table-prefixed to avoid any cross-table collision.

DO $$
BEGIN

  IF NOT EXISTS (
    SELECT FROM pg_constraint WHERE conname = 'legal_acceptances_document_type_check'
  ) THEN
    ALTER TABLE public.legal_acceptances
      ADD CONSTRAINT legal_acceptances_document_type_check
        CHECK (document_type IN ('terms_of_service', 'privacy_policy'));
  END IF;

  IF NOT EXISTS (
    SELECT FROM pg_constraint WHERE conname = 'legal_acceptances_context_check'
  ) THEN
    ALTER TABLE public.legal_acceptances
      ADD CONSTRAINT legal_acceptances_context_check
        CHECK (context IN ('new_iou_flow', 'signup', 're_acceptance', 'settings'));
  END IF;

  IF NOT EXISTS (
    SELECT FROM pg_constraint WHERE conname = 'legal_acceptances_document_version_nonempty'
  ) THEN
    ALTER TABLE public.legal_acceptances
      ADD CONSTRAINT legal_acceptances_document_version_nonempty
        CHECK (trim(document_version) <> '');
  END IF;

  -- Uniqueness key: one acceptance per (user, document type, document version,
  -- usage context). related_iou_id is trace metadata only — not part of identity.
  -- Terms/Privacy is platform-level consent, not per-loan.
  IF NOT EXISTS (
    SELECT FROM pg_constraint WHERE conname = 'legal_acceptances_unique_acceptance'
  ) THEN
    ALTER TABLE public.legal_acceptances
      ADD CONSTRAINT legal_acceptances_unique_acceptance
        UNIQUE (user_id, document_type, document_version, context);
  END IF;

END;
$$;


-- ── 3. Row-level security ─────────────────────────────────────────────────────
--
-- ENABLE ROW LEVEL SECURITY is idempotent — safe on double-run.

ALTER TABLE public.legal_acceptances ENABLE ROW LEVEL SECURITY;

-- SELECT: authenticated users see only their own rows.
-- No INSERT policy — all client writes go through record_legal_acceptance
--   (SECURITY DEFINER), which bypasses RLS. Direct client inserts are blocked.
-- No UPDATE policy.
-- No DELETE policy.
--
-- DROP IF EXISTS + CREATE is the standard idempotent policy pattern.

DROP POLICY IF EXISTS "legal_acceptances_own_select" ON public.legal_acceptances;
CREATE POLICY "legal_acceptances_own_select"
  ON public.legal_acceptances
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());


-- ── 4. Append-only trigger ────────────────────────────────────────────────────
--
-- Blocks UPDATE and DELETE for ALL roles, including service_role and postgres.
-- The trigger fires at the database engine level — RLS alone is not sufficient
-- because service_role bypasses RLS.
--
-- If a data correction or GDPR/account anonymization is ever required, the
-- procedure is:
--   1. DROP this trigger in the Supabase SQL editor.
--   2. Perform the intervention with a documented justification entry in a
--      separate administrative log.
--   3. Immediately recreate this trigger.
-- This must never become a normal application code path.
--
-- CREATE OR REPLACE FUNCTION is unconditionally idempotent.

CREATE OR REPLACE FUNCTION public.legal_acceptances_block_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION
    'legal_acceptances is an append-only consent ledger. '
    'UPDATE and DELETE are not permitted on this table. '
    'Consent records must not be mutated after creation. '
    'If a correction or anonymization is required, contact the database '
    'administrator and follow the documented administrative procedure.';
  RETURN NULL;
END;
$$;

-- CREATE OR REPLACE TRIGGER is idempotent (PostgreSQL 14+, Supabase runs 15).
-- Named table-specifically to be unambiguous in pg_trigger, Supabase dashboard,
-- and audit logs.

CREATE OR REPLACE TRIGGER legal_acceptances_block_mutation_trg
  BEFORE UPDATE OR DELETE ON public.legal_acceptances
  FOR EACH ROW
  EXECUTE FUNCTION public.legal_acceptances_block_mutation();


-- ── 5. RPC: record_legal_acceptance ──────────────────────────────────────────
--
-- Inserts a new consent row, or returns the existing row if one already exists
-- for (user_id, document_type, document_version, context). Idempotent.
--
-- accepted_at is always now() server-side. The caller cannot supply it.
-- user_id is always auth.uid() from the JWT. The caller cannot forge it.
--
-- ON CONFLICT DO NOTHING is atomic at the DB engine level — no race window.
-- If a conflict occurs (duplicate tap, retry), the existing row id is returned.
--
-- Returns jsonb: { id, inserted, document_type, document_version, context }
--   inserted: true  → new row created (first acceptance)
--   inserted: false → existing row returned (repeat call — treat as success)
--
-- SECURITY DEFINER: runs as function owner to bypass RLS for the idempotency
-- SELECT after a conflict. All security boundaries are enforced internally.
-- SET search_path = '' (strictest): prevents search-path injection. All table
-- and function references in this body are fully schema-qualified.
-- auth.uid() is already schema-qualified and resolves correctly with empty path.
--
-- CREATE OR REPLACE FUNCTION is unconditionally idempotent.

CREATE OR REPLACE FUNCTION public.record_legal_acceptance(
  p_document_type    text,
  p_document_version text,
  p_context          text,
  p_related_iou_id   uuid  DEFAULT NULL,
  p_platform         text  DEFAULT NULL,
  p_app_version      text  DEFAULT NULL,
  p_device_metadata  jsonb DEFAULT NULL,
  p_metadata         jsonb DEFAULT NULL,
  p_document_hash    text  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id   uuid;
  v_id        uuid;
  v_inserted  boolean;
  v_clean_ver text;
BEGIN
  -- auth.uid() reads from the session JWT claim.
  -- In a service_role context (no JWT), this returns NULL — the function
  -- raises and cannot be used. Service-role writes use direct table access.
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'record_legal_acceptance: caller is not authenticated';
  END IF;

  -- Input validation. These mirror the table CHECK constraints and provide
  -- clear error messages before the INSERT is attempted.
  IF p_document_type NOT IN ('terms_of_service', 'privacy_policy') THEN
    RAISE EXCEPTION 'record_legal_acceptance: invalid document_type "%"', p_document_type;
  END IF;

  IF p_context NOT IN ('new_iou_flow', 'signup', 're_acceptance', 'settings') THEN
    RAISE EXCEPTION 'record_legal_acceptance: invalid context "%"', p_context;
  END IF;

  IF p_document_version IS NULL OR trim(p_document_version) = '' THEN
    RAISE EXCEPTION 'record_legal_acceptance: document_version must not be empty';
  END IF;

  v_clean_ver := trim(p_document_version);

  -- Atomic insert. ON CONFLICT DO NOTHING handles concurrent duplicate calls
  -- without a race window. The unique constraint
  -- legal_acceptances_unique_acceptance is the enforcement point.
  -- If the conflict fires, RETURNING returns nothing (v_id stays NULL).
  INSERT INTO public.legal_acceptances (
    user_id,          document_type,     document_version,  document_hash,
    accepted_at,      context,           related_iou_id,    platform,
    app_version,      device_metadata,   metadata
  ) VALUES (
    v_user_id,        p_document_type,   v_clean_ver,       p_document_hash,
    now(),            p_context,         p_related_iou_id,  p_platform,
    p_app_version,    p_device_metadata, p_metadata
  )
  ON CONFLICT (user_id, document_type, document_version, context) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    -- New row inserted.
    v_inserted := true;
  ELSE
    -- Conflict: row already exists. Fetch its id.
    -- This SELECT runs after the INSERT is known to have been skipped,
    -- so the row is guaranteed to exist at this point.
    SELECT id INTO v_id
    FROM public.legal_acceptances
    WHERE user_id          = v_user_id
      AND document_type    = p_document_type
      AND document_version = v_clean_ver
      AND context          = p_context;
    v_inserted := false;
  END IF;

  RETURN jsonb_build_object(
    'id',               v_id,
    'inserted',         v_inserted,
    'document_type',    p_document_type,
    'document_version', v_clean_ver,
    'context',          p_context
  );
END;
$$;


-- ── 6. RPC: has_current_legal_acceptance ─────────────────────────────────────
--
-- Returns whether the calling user has accepted both current document versions.
-- The frontend calls this at Legal step entry to detect stale or missing consent.
--
-- Returns jsonb: { all_current, has_terms, has_privacy, missing }
--   all_current: true  → both versions accepted, Legal step can be skipped
--   missing: []string  → document types still requiring acceptance (targeted UI)
--
-- Both EXISTS queries use the unique constraint index on
-- (user_id, document_type, document_version) prefix — no full table scan.
--
-- SECURITY DEFINER + SET search_path = '' for the same reasons as above.

CREATE OR REPLACE FUNCTION public.has_current_legal_acceptance(
  p_terms_version   text,
  p_privacy_version text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id     uuid;
  v_has_terms   boolean := false;
  v_has_privacy boolean := false;
  v_missing     text[]  := '{}';
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'has_current_legal_acceptance: caller is not authenticated';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.legal_acceptances
    WHERE user_id          = v_user_id
      AND document_type    = 'terms_of_service'
      AND document_version = p_terms_version
  ) INTO v_has_terms;

  SELECT EXISTS (
    SELECT 1 FROM public.legal_acceptances
    WHERE user_id          = v_user_id
      AND document_type    = 'privacy_policy'
      AND document_version = p_privacy_version
  ) INTO v_has_privacy;

  IF NOT v_has_terms   THEN v_missing := array_append(v_missing, 'terms_of_service'); END IF;
  IF NOT v_has_privacy THEN v_missing := array_append(v_missing, 'privacy_policy');   END IF;

  RETURN jsonb_build_object(
    'all_current', v_has_terms AND v_has_privacy,
    'has_terms',   v_has_terms,
    'has_privacy', v_has_privacy,
    'missing',     to_jsonb(v_missing)
  );
END;
$$;


-- ── 7. Permissions ────────────────────────────────────────────────────────────
--
-- Postgres grants EXECUTE to PUBLIC by default for new functions.
-- REVOKE removes that default. GRANT gives authenticated role explicit access.
-- anon role (unauthenticated Supabase requests) is not granted — it cannot call
-- either function. Even if it did, auth.uid() would return NULL and the function
-- raises immediately.
-- service_role is not granted. Service-role scripts use direct table access
-- (bypassing RLS), not these RPCs. The RPCs require a valid JWT (auth.uid()).
-- REVOKE and GRANT are idempotent — safe on double-run.

REVOKE EXECUTE
  ON FUNCTION public.record_legal_acceptance(text, text, text, uuid, text, text, jsonb, jsonb, text)
  FROM PUBLIC;

REVOKE EXECUTE
  ON FUNCTION public.has_current_legal_acceptance(text, text)
  FROM PUBLIC;

GRANT EXECUTE
  ON FUNCTION public.record_legal_acceptance(text, text, text, uuid, text, text, jsonb, jsonb, text)
  TO authenticated;

GRANT EXECUTE
  ON FUNCTION public.has_current_legal_acceptance(text, text)
  TO authenticated;
