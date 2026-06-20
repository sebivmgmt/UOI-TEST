import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// search-counterparty
//
// Authenticated full-text profile search used by:
//   - SearchUsersScreen   (recent-contacts search bar)
//   - NewIouScreen        (borrower/lender picker)
//   - NewLoan             (borrower/lender picker)
//   - TrustReportScreen   (counterparty search for sharing a trust report)
//
// Security contract:
//   - JWT authentication required. User is derived from the Authorization
//     header — never from a client-supplied field.
//   - Service-role Supabase client used after JWT validation.
//   - Internally matches on: full_name, display_name, email, phone_digits,
//     iou_hash (case-insensitive prefix/contains search).
//   - Response NEVER includes: email, phone, phone_verified, phone_digits,
//     bank_linked, plaid_linked, ach_status, bank_provider, account_mask,
//     dwolla_*, plaid_account_id, plaid_institution_name, identity_status,
//     identity_verified_at, dob, address_*, ssn_last_4, score_cap,
//     lifetime_score_cap, score_last_updated_at, or any PII.
//   - Results are limited to RESULT_LIMIT rows.
//   - Minimum query length of MIN_QUERY_LEN is enforced.
//   - Caller's own profile is excluded from results.
//
// Safe response shape (per result):
//   id           string   — UUID
//   display_name string   — Display name (display_name ?? full_name)
//   full_name    string   — Full legal-format name (may be null)
//   iou_hash     string   — @handle for deep linking (may be null)
//   avatar_url   string   — Profile photo (may be null)
//   iou_score    number   — Aggregate trust score (may be null)
// ---------------------------------------------------------------------------

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const MIN_QUERY_LEN = 2;
const RESULT_LIMIT = 10;

// Strip characters that could interfere with PostgREST filter syntax.
// Keeps: letters, digits, spaces, @, ., -, _, +
// Strips: , ( ) \ | & ! and control chars
function sanitizeQuery(raw: string): string {
  return raw
    .replace(/[,()\\|&!]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
}

// Escape ILIKE wildcard characters in the user-supplied string so they are
// treated as literals inside the pattern, not as matching operators.
function escapeLike(s: string): string {
  return s.replace(/%/g, "\\%").replace(/_/g, "\\_");
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let stage = "start";

  try {
    // ── 1. Resolve environment ─────────────────────────────────────────────
    stage = "env";

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
      throw new Error("Missing Supabase credentials");
    }

    // ── 2. Authenticate caller from JWT ────────────────────────────────────
    stage = "auth";

    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      throw new Error("Missing auth");
    }
    const token = authHeader.replace("Bearer ", "").trim();

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(token);

    if (userError || !user) {
      throw new Error("Invalid user");
    }

    // ── 3. Parse and validate query ────────────────────────────────────────
    stage = "parse";

    const body = await req.json().catch(() => ({}));
    const rawQuery = typeof body?.query === "string" ? body.query : "";
    const query = sanitizeQuery(rawQuery);

    if (query.length < MIN_QUERY_LEN) {
      return new Response(
        JSON.stringify({
          results: [],
          ok: true,
          stage,
          hint: `Query must be at least ${MIN_QUERY_LEN} characters.`,
        }),
        { status: 200, headers: corsHeaders }
      );
    }

    // ── 4. Build search ───────────────────────────────────────────────────
    // Match against display-safe and lookup columns. Sensitive columns
    // (email, phone, phone_digits) are used for matching only — they are
    // never included in the SELECT or returned to the caller.
    stage = "search";

    const escaped = escapeLike(query);
    const pattern = `%${escaped}%`;

    // iou_hash supports exact-prefix search (e.g. "@johnd")
    const hashPattern = query.startsWith("@") ? `${escaped}%` : `%${escaped}%`;

    // Build OR filter for all searchable columns.
    // phone_digits is matched as digits-only to handle formatted input.
    const digits = query.replace(/\D/g, "");
    const filterParts: string[] = [
      `full_name.ilike.${pattern}`,
      `display_name.ilike.${pattern}`,
      `email.ilike.${pattern}`,
      `iou_hash.ilike.${hashPattern}`,
    ];

    if (digits.length >= MIN_QUERY_LEN) {
      filterParts.push(`phone_digits.ilike.${`%${escapeLike(digits)}%`}`);
    }

    const { data, error: searchError } = await supabase
      .from("profiles")
      // Only safe, non-PII display fields are selected.
      // Sensitive columns are deliberately excluded even if they matched.
      .select("id, full_name, display_name, iou_hash, avatar_url, iou_score")
      .or(filterParts.join(","))
      .neq("id", user.id)
      .limit(RESULT_LIMIT);

    if (searchError) {
      throw new Error(`Search failed: ${searchError.message}`);
    }

    // ── 5. Shape safe response ────────────────────────────────────────────
    stage = "shape";

    const results = (data ?? []).map((row: any) => ({
      id: row.id as string,
      display_name: (row.display_name ?? row.full_name ?? null) as string | null,
      full_name: (row.full_name ?? null) as string | null,
      iou_hash: (row.iou_hash ?? null) as string | null,
      avatar_url: (row.avatar_url ?? null) as string | null,
      iou_score: typeof row.iou_score === "number" ? row.iou_score : null,
    }));

    stage = "success";

    return new Response(
      JSON.stringify({ results, ok: true, stage }),
      { status: 200, headers: corsHeaders }
    );
  } catch (err: any) {
    console.error("[search-counterparty] failed", {
      stage,
      message: err?.message ?? null,
    });

    return new Response(
      JSON.stringify({
        error: err?.message ?? "Unknown error",
        results: [],
        stage,
        ok: false,
      }),
      { status: 500, headers: corsHeaders }
    );
  }
});
