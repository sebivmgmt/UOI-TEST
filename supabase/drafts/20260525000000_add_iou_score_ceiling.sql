-- ─────────────────────────────────────────────────────────────────────────────
-- Migration: add_iou_score_ceiling
-- Created:   2026-05-25
-- Purpose:   Enforce a per-IOU lifetime score contribution ceiling.
--
--            Each IOU earns a maximum number of trust points determined by
--            principal amount and term length (logarithmic scaling). Once a
--            borrower has earned that ceiling from a specific loan, further
--            on-time or early payment score events from that IOU are discarded.
--            Strike and penalty events (delta ≤ 0) are never metered.
--
-- Design:
--   ious.score_ceiling     — maximum positive points this IOU can contribute.
--                            Set when status → 'open'. Never decreases.
--   ious.score_contributed — running total of positive points earned so far.
--                            Incremented atomically by the score_events trigger.
--   score_events.iou_id    — nullable link back to the originating IOU.
--                            NULL = system event (strike, exposure); no ceiling.
--
-- Backward compatibility:
--   score_contributed defaults to 0 for all existing IOUs. Legacy score events
--   lack iou_id (they predate this column) and are therefore not metered.
--   The ceiling applies only to new events that supply iou_id on insert.
--   No existing earned score is retroactively removed.
--
-- Ceiling sample values:
--   $20   1-month  →  16 pts        $20   12-month  →  21 pts
--   $100  12-month →  33 pts
--   $500  12-month →  44 pts
--   $2k   12-month →  54 pts        $2k   36-month  →  60 pts
--   $10k  12-month →  65 pts        $10k  36-month  →  73 pts
--
-- Requires: PostgreSQL 14+ (CREATE OR REPLACE TRIGGER).
--           Supabase runs PostgreSQL 15 — satisfied.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. Ceiling columns on ious ───────────────────────────────────────────────
--
-- score_ceiling:     maximum positive score points this IOU may contribute.
--                    0 until the IOU is activated (status = 'open').
-- score_contributed: running total of positive points already earned.
--                    Incremented by the score_events enforcement trigger.
--
-- Both columns default to 0. NOT NULL ensures comparisons never return NULL.

ALTER TABLE public.ious
  ADD COLUMN IF NOT EXISTS score_ceiling     integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS score_contributed integer NOT NULL DEFAULT 0;


-- ── 2. Check constraint: score_contributed ≤ score_ceiling ──────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_constraint
    WHERE conname = 'ious_score_contributed_lte_ceiling'
  ) THEN
    ALTER TABLE public.ious
      ADD CONSTRAINT ious_score_contributed_lte_ceiling
        CHECK (score_contributed <= score_ceiling OR score_ceiling = 0);
  END IF;
END;
$$;


-- ── 3. iou_id column on score_events and score_history ──────────────────────
--
-- Nullable. NULL = system event (strike, exposure, adjustment) with no IOU link.
-- ON DELETE SET NULL: if an IOU is hard-deleted, events become unlinked but
-- are not dropped (score history should survive the IOU lifecycle).

ALTER TABLE public.score_events
  ADD COLUMN IF NOT EXISTS iou_id uuid
    REFERENCES public.ious(id) ON DELETE SET NULL;

-- score_history is a fallback/legacy table; same column added for consistency.
ALTER TABLE public.score_history
  ADD COLUMN IF NOT EXISTS iou_id uuid
    REFERENCES public.ious(id) ON DELETE SET NULL;


-- ── 4. Ceiling calculation function ─────────────────────────────────────────
--
-- Pure calculation; declared IMMUTABLE so the planner may inline or cache it.
-- Uses Postgres log() which is log base-10.
--
-- Formula:
--   raw = 12 × log10(principal_dollars) × (1 + log10(term_months) / 3)
--   ceiling = GREATEST(5, LEAST(150, ROUND(raw)))
--
-- Rationale:
--   log10 scaling means doubling the loan size adds a fixed increment (~3.6 pts
--   per decade of loan amount), not a proportional jump. Whales cannot leap
--   ahead, but larger loans still matter more than tiny ones.
--   The 5-point floor prevents zero or negative ceilings for $1–$9 loans.
--   The 150-point hard cap stays within the 700-point lending-unlock headroom.
--
-- Called by the activation trigger (§5) and the backfill statement (§6).

CREATE OR REPLACE FUNCTION public.calculate_iou_score_ceiling(
  p_principal_cents bigint,
  p_term_months     integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT GREATEST(5, LEAST(150,
    ROUND(
      12.0
      * log(GREATEST(1.0, p_principal_cents::numeric / 100.0))
      * (1.0 + log(GREATEST(1.0, p_term_months::numeric)) / 3.0)
    )::integer
  ));
$$;


-- ── 5. Trigger: auto-set ceiling on IOU activation ──────────────────────────
--
-- Fires BEFORE INSERT OR UPDATE on ious.
-- Sets score_ceiling and resets score_contributed when status transitions to
-- 'open' for the first time. Re-activation of an already-open row is a no-op.
--
-- score_ceiling is intentionally not recalculated on amendments — the ceiling
-- established at activation is the ceiling for the lifetime of the IOU.

CREATE OR REPLACE FUNCTION public.iou_set_score_ceiling()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'open'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'open')
  THEN
    NEW.score_ceiling     := public.calculate_iou_score_ceiling(
                               NEW.principal_cents::bigint,
                               NEW.term_months::integer
                             );
    NEW.score_contributed := 0;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER iou_score_ceiling_trg
  BEFORE INSERT OR UPDATE ON public.ious
  FOR EACH ROW
  EXECUTE FUNCTION public.iou_set_score_ceiling();


-- ── 6. Backfill: calculate ceilings for all existing IOUs ───────────────────
--
-- Applies the ceiling formula to every existing row that has not yet been set
-- (score_ceiling = 0) and has the required fields. score_contributed stays 0
-- for all existing rows — legacy events have no iou_id and are not metered.

UPDATE public.ious
SET score_ceiling = public.calculate_iou_score_ceiling(
                      principal_cents::bigint,
                      term_months::integer
                    )
WHERE score_ceiling = 0
  AND principal_cents IS NOT NULL
  AND term_months     IS NOT NULL
  AND term_months     > 0;


-- ── 7. Trigger: enforce ceiling on score_events insert ──────────────────────
--
-- Fires BEFORE INSERT on score_events.
-- The trigger either passes the event through, clamps its delta to remaining
-- headroom, or cancels the insert entirely (RETURN NULL) if the ceiling is
-- already exhausted.
--
-- Ceiling enforcement rules:
--   iou_id IS NULL  → system event; no ceiling → pass through.
--   delta ≤ 0       → penalty or strike; never metered → pass through.
--   headroom = 0    → ceiling exhausted; discard this reward event.
--   delta > headroom → clamp delta to headroom; update contributed; insert.
--   delta ≤ headroom → pass through; update contributed; insert.
--
-- Atomicity: SELECT ... FOR UPDATE on the ious row serializes concurrent
-- score events for the same IOU, preventing over-attribution under load.
--
-- SECURITY DEFINER: the UPDATE on ious.score_contributed must succeed
-- regardless of the calling role's RLS grants. The function owner (postgres)
-- has unconditional UPDATE access. SET search_path = '' prevents injection.

CREATE OR REPLACE FUNCTION public.score_event_enforce_ceiling()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ceiling     integer;
  v_contributed integer;
  v_headroom    integer;
BEGIN
  -- System events (no IOU link) and penalty/strike events bypass the ceiling.
  IF NEW.iou_id IS NULL OR NEW.delta IS NULL OR NEW.delta <= 0 THEN
    RETURN NEW;
  END IF;

  -- Lock the IOU row to serialize concurrent reward events for the same loan.
  SELECT score_ceiling, score_contributed
    INTO v_ceiling, v_contributed
    FROM public.ious
   WHERE id = NEW.iou_id
     FOR UPDATE;

  IF NOT FOUND THEN
    -- IOU missing (FK violation would have already failed); pass through.
    RETURN NEW;
  END IF;

  -- score_ceiling = 0 means the IOU has not been activated yet.
  -- Pass through rather than silently blocking pre-activation events.
  IF v_ceiling = 0 THEN
    RETURN NEW;
  END IF;

  v_headroom := v_ceiling - v_contributed;

  IF v_headroom <= 0 THEN
    -- Ceiling exhausted: discard this reward event entirely.
    -- The insert is cancelled; no score change, no history row.
    RETURN NULL;
  END IF;

  IF NEW.delta > v_headroom THEN
    -- Partial headroom remaining: clamp delta to what's left.
    NEW.delta := v_headroom;
  END IF;

  -- Advance the contributed counter atomically with this event insertion.
  UPDATE public.ious
     SET score_contributed = score_contributed + NEW.delta
   WHERE id = NEW.iou_id;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER score_event_ceiling_trg
  BEFORE INSERT ON public.score_events
  FOR EACH ROW
  EXECUTE FUNCTION public.score_event_enforce_ceiling();


-- ── 8. Permissions ────────────────────────────────────────────────────────────
--
-- calculate_iou_score_ceiling is an internal utility.
-- Revoke the default PUBLIC grant; allow authenticated callers and service_role
-- (e.g. Edge Functions) to call it directly for display or preview purposes.
-- The trigger functions are not callable directly — no grant needed.

REVOKE EXECUTE
  ON FUNCTION public.calculate_iou_score_ceiling(bigint, integer)
  FROM PUBLIC;

GRANT EXECUTE
  ON FUNCTION public.calculate_iou_score_ceiling(bigint, integer)
  TO authenticated, service_role;
