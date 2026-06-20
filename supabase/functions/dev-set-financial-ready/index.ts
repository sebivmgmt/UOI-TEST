import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// dev-set-financial-ready
//
// DEV-ONLY explicit fixture tool that marks the authenticated @iou.llc test
// account financially ready for product testing (IOUs, payments, Score v2).
//
// Security contract:
//   1. Bearer token required.
//   2. JWT validated via anon-key client before SERVICE_ROLE_KEY is read.
//   3. Fails unless SUPABASE_URL belongs exactly to colkilearqxuyldzjutw.
//   4. Fails unless ALLOW_DEV_FINANCIAL_FIXTURES=true.
//   5. Fails unless the authenticated user's email ends in @iou.llc.
//   6. Updates only the authenticated user's own profile row.
//   7. Does not fabricate or overwrite real provider identifiers
//      (dwolla_customer_id, plaid_account_id, access tokens, etc.).
//   8. Uses .select().single() after update so a zero-row match is an error.
//
// Must never be deployed to CURRENT/LIVE (clxfsghyasjmfoxmhpxv).
// The project-URL check at step 3 is the server-side enforcement of this.
// ---------------------------------------------------------------------------

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const DEV_PROJECT_ID = "colkilearqxuyldzjutw";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // ── 1. Require Bearer token ────────────────────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(
      JSON.stringify({ ok: false, error: "Unauthorized" }),
      { status: 401, headers: corsHeaders }
    );
  }
  const token = authHeader.replace("Bearer ", "").trim();

  // ── 2. Read public env vars (no sensitive keys yet) ────────────────────────
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return new Response(
      JSON.stringify({ ok: false, error: "Server error" }),
      { status: 500, headers: corsHeaders }
    );
  }

  // ── 3. Fail unless SUPABASE_URL belongs to the DEV project ────────────────
  if (!SUPABASE_URL.includes(DEV_PROJECT_ID)) {
    return new Response(
      JSON.stringify({ ok: false, error: "This fixture is not available in this environment." }),
      { status: 403, headers: corsHeaders }
    );
  }

  // ── 4. Fail unless ALLOW_DEV_FINANCIAL_FIXTURES=true ──────────────────────
  const fixtureEnabled = Deno.env.get("ALLOW_DEV_FINANCIAL_FIXTURES");
  if (fixtureEnabled !== "true") {
    return new Response(
      JSON.stringify({ ok: false, error: "Dev financial fixtures are not enabled." }),
      { status: 403, headers: corsHeaders }
    );
  }

  // ── 5. Validate JWT — authenticated user identity ─────────────────────────
  const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const {
    data: { user },
    error: userError,
  } = await authClient.auth.getUser(token);

  if (userError || !user) {
    return new Response(
      JSON.stringify({ ok: false, error: "Unauthorized" }),
      { status: 401, headers: corsHeaders }
    );
  }

  // ── 6. Fail unless email ends in @iou.llc ─────────────────────────────────
  if (!user.email?.endsWith("@iou.llc")) {
    return new Response(
      JSON.stringify({ ok: false, error: "Not authorized for this account." }),
      { status: 403, headers: corsHeaders }
    );
  }

  // ── 7. Auth confirmed — now read SERVICE_ROLE_KEY ─────────────────────────
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SERVICE_ROLE_KEY) {
    return new Response(
      JSON.stringify({ ok: false, error: "Server error" }),
      { status: 500, headers: corsHeaders }
    );
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── 8. Write fixture values to the authenticated user's profile ───────────
  // Only ACH-readiness and display-safe bank metadata are set.
  // Real provider identifiers (dwolla_customer_id, plaid_account_id, etc.)
  // are never touched.
  const { data: updatedProfile, error: updateError } = await supabase
    .from("profiles")
    .update({
      ach_status: "ready",
      bank_linked: true,
      plaid_linked: true,
      bank_provider: "dev_fixture",
      bank_name: "DEV Test Bank",
      bank_account_mask: "0000",
      account_mask: "0000",
    })
    .eq("id", user.id)
    .select("ach_status, bank_provider, bank_linked, plaid_linked")
    .single();

  if (updateError) {
    console.error("[dev-set-financial-ready] profile update failed", {
      userId_suffix: user.id.slice(-6),
      message: updateError.message,
      code: (updateError as any).code ?? null,
    });
    return new Response(
      JSON.stringify({ ok: false, error: "Profile update failed.", stage: "update" }),
      { status: 500, headers: corsHeaders }
    );
  }

  // Confirm all four readiness fields actually persisted.
  // Zero-row update surfaces as PGRST116 from .single() above.
  if (
    updatedProfile?.ach_status !== "ready" ||
    updatedProfile?.bank_provider !== "dev_fixture" ||
    updatedProfile?.bank_linked !== true ||
    updatedProfile?.plaid_linked !== true
  ) {
    console.error("[dev-set-financial-ready] profile update did not persist", {
      userId_suffix: user.id.slice(-6),
      ach_status: updatedProfile?.ach_status ?? null,
      bank_provider: updatedProfile?.bank_provider ?? null,
      bank_linked: updatedProfile?.bank_linked ?? null,
      plaid_linked: updatedProfile?.plaid_linked ?? null,
    });
    return new Response(
      JSON.stringify({
        ok: false,
        error: "Profile update did not persist. Please retry.",
        stage: "update",
      }),
      { status: 500, headers: corsHeaders }
    );
  }

  console.log("[dev-set-financial-ready] fixture applied", {
    userId_suffix: user.id.slice(-6),
    ach_status: updatedProfile.ach_status,
    bank_provider: updatedProfile.bank_provider,
    bank_linked: updatedProfile.bank_linked,
    plaid_linked: updatedProfile.plaid_linked,
  });

  return new Response(
    JSON.stringify({
      ok: true,
      fixture: true,
      ach_status: updatedProfile.ach_status,
      bank_provider: updatedProfile.bank_provider,
      bank_linked: updatedProfile.bank_linked,
      plaid_linked: updatedProfile.plaid_linked,
    }),
    { status: 200, headers: corsHeaders }
  );
});
