import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// dev-complete-ach-payment
//
// DEV-ONLY fixture that simulates Dwolla ACH settlement for a payment that
// is already in status='processing' / payment_method='ach'.
//
// Security contract:
//   1.  Bearer token required.
//   2.  JWT validated via anon-key client before SERVICE_ROLE_KEY is read.
//   3.  Fails unless SUPABASE_URL belongs exactly to colkilearqxuyldzjutw.
//   4.  Fails unless ALLOW_DEV_FINANCIAL_FIXTURES=true.
//   5.  Fails unless the authenticated user's email ends in @iou.llc.
//   6.  Accepts only { payment_id: uuid } from the client.
//   7.  Verifies the caller is the borrower for that payment before using
//       the service role.
//   8.  Verifies status='processing' and payment_method='ach'.
//   9.  Verifies bank_provider='dev_fixture' and ach_status='ready'.
//  10.  Generates the transfer reference server-side (dev-ach-<uuid>).
//  11.  Calls complete_ach_payment via the service-role client.
//  12.  Validates the returned row: status='paid', payment_method='ach',
//       paid_at present.
//  13.  Returns actual row values, not hardcoded strings.
//
// Logging uses structured DEV-safe fields only (id suffixes, statuses, booleans).
// Never logs tokens, emails, full UUIDs, bank details, or credentials.
//
// Must never be deployed to CURRENT/LIVE (clxfsghyasjmfoxmhpxv).
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

  let stage = "init";

  // ── 1. Require Bearer token ────────────────────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(
      JSON.stringify({ ok: false, error: "Unauthorized", stage }),
      { status: 401, headers: corsHeaders }
    );
  }
  const token = authHeader.replace("Bearer ", "").trim();

  // ── 2. Read public env vars (no sensitive keys yet) ────────────────────────
  stage = "env";
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return new Response(
      JSON.stringify({ ok: false, error: "Server error", stage }),
      { status: 500, headers: corsHeaders }
    );
  }

  // ── 3. Fail unless SUPABASE_URL belongs to DEV project ────────────────────
  stage = "project-guard";
  if (!SUPABASE_URL.includes(DEV_PROJECT_ID)) {
    return new Response(
      JSON.stringify({ ok: false, error: "Not available in this environment.", stage }),
      { status: 403, headers: corsHeaders }
    );
  }

  // ── 4. Fail unless ALLOW_DEV_FINANCIAL_FIXTURES=true ──────────────────────
  stage = "fixture-guard";
  if (Deno.env.get("ALLOW_DEV_FINANCIAL_FIXTURES") !== "true") {
    return new Response(
      JSON.stringify({ ok: false, error: "Dev financial fixtures are not enabled.", stage }),
      { status: 403, headers: corsHeaders }
    );
  }

  // ── 5. Validate JWT — resolve authenticated user ───────────────────────────
  stage = "auth";
  const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const {
    data: { user },
    error: userError,
  } = await authClient.auth.getUser(token);

  if (userError || !user) {
    return new Response(
      JSON.stringify({ ok: false, error: "Unauthorized", stage }),
      { status: 401, headers: corsHeaders }
    );
  }

  // ── 6. Fail unless email ends in @iou.llc ─────────────────────────────────
  stage = "email-guard";
  if (!user.email?.endsWith("@iou.llc")) {
    return new Response(
      JSON.stringify({ ok: false, error: "Not authorized for this account.", stage }),
      { status: 403, headers: corsHeaders }
    );
  }

  // ── 7. Parse request body — accept only payment_id ────────────────────────
  stage = "parse-body";
  let paymentId: string | null = null;
  try {
    const body = await req.json();
    paymentId = typeof body?.payment_id === "string" ? body.payment_id.trim() : null;
  } catch {
    return new Response(
      JSON.stringify({ ok: false, error: "Invalid request body.", stage }),
      { status: 400, headers: corsHeaders }
    );
  }
  if (!paymentId) {
    return new Response(
      JSON.stringify({ ok: false, error: "payment_id is required.", stage }),
      { status: 400, headers: corsHeaders }
    );
  }

  // ── Auth confirmed — now read SERVICE_ROLE_KEY ─────────────────────────────
  stage = "service-role-init";
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SERVICE_ROLE_KEY) {
    return new Response(
      JSON.stringify({ ok: false, error: "Server error", stage }),
      { status: 500, headers: corsHeaders }
    );
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── Fetch payment and verify borrower is caller ────────────────────────────
  stage = "payment-fetch";
  const { data: paymentRow, error: paymentError } = await supabase
    .from("payments")
    .select("id, iou_id, status, payment_method, paid_at")
    .eq("id", paymentId)
    .single();

  if (paymentError || !paymentRow) {
    console.error("[dev-complete-ach-payment] payment not found", {
      payment_id_suffix: paymentId.slice(-6),
      user_id_suffix: user.id.slice(-6),
      error: paymentError?.message ?? null,
      stage,
    });
    return new Response(
      JSON.stringify({ ok: false, error: "Payment not found.", stage }),
      { status: 404, headers: corsHeaders }
    );
  }

  // ── Fetch IOU to verify borrower identity ─────────────────────────────────
  stage = "iou-fetch";
  const { data: iouRow, error: iouError } = await supabase
    .from("ious")
    .select("id, borrower_id")
    .eq("id", paymentRow.iou_id)
    .single();

  if (iouError || !iouRow) {
    console.error("[dev-complete-ach-payment] iou not found", {
      payment_id_suffix: paymentId.slice(-6),
      user_id_suffix: user.id.slice(-6),
      stage,
    });
    return new Response(
      JSON.stringify({ ok: false, error: "IOU not found.", stage }),
      { status: 404, headers: corsHeaders }
    );
  }

  // ── 7 (continued). Verify caller is borrower ──────────────────────────────
  stage = "borrower-verify";
  if (iouRow.borrower_id !== user.id) {
    console.error("[dev-complete-ach-payment] caller is not borrower", {
      payment_id_suffix: paymentId.slice(-6),
      user_id_suffix: user.id.slice(-6),
      stage,
    });
    return new Response(
      JSON.stringify({ ok: false, error: "Not authorized for this payment.", stage }),
      { status: 403, headers: corsHeaders }
    );
  }

  // ── 8. Verify status=processing and payment_method=ach ────────────────────
  stage = "status-verify";
  if (paymentRow.status !== "processing" || paymentRow.payment_method !== "ach") {
    console.error("[dev-complete-ach-payment] payment not in processing/ach state", {
      payment_id_suffix: paymentId.slice(-6),
      user_id_suffix: user.id.slice(-6),
      status: paymentRow.status,
      payment_method: paymentRow.payment_method,
      has_paid_at: !!paymentRow.paid_at,
      stage,
    });
    return new Response(
      JSON.stringify({
        ok: false,
        error: `Payment is not processing via ACH (status=${paymentRow.status}, method=${paymentRow.payment_method ?? "null"}).`,
        stage,
        status: paymentRow.status,
        payment_method: paymentRow.payment_method,
      }),
      { status: 409, headers: corsHeaders }
    );
  }

  // ── 9. Verify borrower profile: bank_provider=dev_fixture, ach_status=ready ─
  stage = "profile-verify";
  const { data: profileRow, error: profileError } = await supabase
    .from("profiles")
    .select("ach_status, bank_provider")
    .eq("id", user.id)
    .single();

  if (profileError || !profileRow) {
    console.error("[dev-complete-ach-payment] profile not found", {
      user_id_suffix: user.id.slice(-6),
      stage,
    });
    return new Response(
      JSON.stringify({ ok: false, error: "Profile not found.", stage }),
      { status: 404, headers: corsHeaders }
    );
  }

  if (profileRow.ach_status !== "ready" || profileRow.bank_provider !== "dev_fixture") {
    console.error("[dev-complete-ach-payment] profile not dev_fixture/ready", {
      user_id_suffix: user.id.slice(-6),
      ach_status: profileRow.ach_status,
      bank_provider: profileRow.bank_provider,
      stage,
    });
    return new Response(
      JSON.stringify({
        ok: false,
        error: "Profile must have bank_provider=dev_fixture and ach_status=ready.",
        stage,
        ach_status: profileRow.ach_status,
        bank_provider: profileRow.bank_provider,
      }),
      { status: 403, headers: corsHeaders }
    );
  }

  // ── 10. Generate transfer reference server-side ────────────────────────────
  stage = "transfer-ref-gen";
  const transferRef = `dev-ach-${crypto.randomUUID()}`;

  // ── 11. Call complete_ach_payment via service-role client ──────────────────
  stage = "complete-ach-payment";
  const { data: completedData, error: completeError } = await supabase.rpc(
    "complete_ach_payment",
    {
      p_payment_id: paymentId,
      p_transfer_id: transferRef,
    }
  );

  if (completeError) {
    console.error("[dev-complete-ach-payment] complete_ach_payment rpc failed", {
      payment_id_suffix: paymentId.slice(-6),
      user_id_suffix: user.id.slice(-6),
      message: completeError.message,
      code: (completeError as any).code ?? null,
      stage,
    });
    return new Response(
      JSON.stringify({
        ok: false,
        error: completeError.message,
        stage,
      }),
      { status: 500, headers: corsHeaders }
    );
  }

  // ── 12. Validate returned row ──────────────────────────────────────────────
  stage = "result-verify";
  const completedRow = Array.isArray(completedData)
    ? (completedData[0] ?? null)
    : completedData;

  if (
    !completedRow ||
    completedRow.status !== "paid" ||
    completedRow.payment_method !== "ach" ||
    !completedRow.paid_at
  ) {
    console.error("[dev-complete-ach-payment] result did not confirm paid", {
      payment_id_suffix: paymentId.slice(-6),
      user_id_suffix: user.id.slice(-6),
      status: completedRow?.status ?? null,
      payment_method: completedRow?.payment_method ?? null,
      has_paid_at: !!completedRow?.paid_at,
      stage,
    });
    return new Response(
      JSON.stringify({
        ok: false,
        error: "Payment completion did not confirm paid status.",
        stage,
        status: completedRow?.status ?? null,
        payment_method: completedRow?.payment_method ?? null,
        paid_at: completedRow?.paid_at ?? null,
      }),
      { status: 500, headers: corsHeaders }
    );
  }

  // ── 13. Return actual row values ───────────────────────────────────────────
  console.log("[dev-complete-ach-payment] payment completed", {
    payment_id_suffix: paymentId.slice(-6),
    user_id_suffix: user.id.slice(-6),
    status: completedRow.status,
    payment_method: completedRow.payment_method,
    has_paid_at: true,
    stage: "done",
  });

  return new Response(
    JSON.stringify({
      ok: true,
      stage: "done",
      status: completedRow.status,
      payment_method: completedRow.payment_method,
      paid_at: completedRow.paid_at,
      tx_ref: completedRow.tx_ref ?? null,
    }),
    { status: 200, headers: corsHeaders }
  );
});
