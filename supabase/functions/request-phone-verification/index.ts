import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// request-phone-verification
//
// Creates a phone verification row and (in production) dispatches an SMS OTP.
// The matching RPC public.verify_phone_code(in_code, in_phone) consumes the
// code and sets phone_verified / phone_verified_at on the caller's profile.
//
// Environment secrets (set per Supabase project):
//   ALLOW_DEV_PHONE_OTP      "true" in the DEV project only.
//                            Inserts fixed code 7777777 and returns it in the
//                            response. Must never be set in the production
//                            project.
//   SMS_PROVIDER_CONFIGURED  "true" when a real SMS provider is wired.
//                            Until then, all non-dev requests fail closed.
//
// Security:
//   - User identity derived from Authorization JWT — never from a client
//     field.
//   - phone_verifications is INSERT-only via service role here. Clients have
//     no table privileges (enforced in DB).
//   - profiles.phone is updated via service role so the client never writes
//     that column directly.
//   - The OTP code is never returned in production.
//   - A random 6-digit code is generated via Web Crypto in production. The
//     fixed dev code 7777777 is used only when ALLOW_DEV_PHONE_OTP=true.
// ---------------------------------------------------------------------------

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const DEV_OTP = "7777777";
const CODE_DIGITS = 6;
const CODE_TTL_MINUTES = 10;

// Normalize a raw phone string to E.164.
// Supports:
//   +1XXXXXXXXXX  →  +1XXXXXXXXXX  (international already formatted)
//   XXXXXXXXXX    →  +1XXXXXXXXXX  (10-digit US, assumes +1 prefix)
//   1XXXXXXXXXX   →  +1XXXXXXXXXX  (11-digit starting with 1)
// Returns null for any unrecognised format.
function normalizeToE164(raw: string): string | null {
  const trimmed = raw.trim();
  const digits = trimmed.replace(/\D/g, "");

  if (trimmed.startsWith("+")) {
    // Caller supplied an explicit country code — keep as-is if length is plausible.
    if (digits.length >= 7 && digits.length <= 15) return "+" + digits;
    return null;
  }

  if (digits.length === 10) return "+1" + digits;
  if (digits.length === 11 && digits.startsWith("1")) return "+" + digits;

  return null;
}

// Generate a cryptographically random numeric OTP with the given digit count.
function generateOtp(digits: number): string {
  const max = Math.pow(10, digits);
  const arr = new Uint32Array(1);
  crypto.getRandomValues(arr);
  return (arr[0] % max).toString().padStart(digits, "0");
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
    const ALLOW_DEV_PHONE_OTP = Deno.env.get("ALLOW_DEV_PHONE_OTP") === "true";
    const SMS_PROVIDER_CONFIGURED = Deno.env.get("SMS_PROVIDER_CONFIGURED") === "true";

    if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
      throw new Error("Missing Supabase credentials");
    }

    // Fail closed if neither dev mode nor a real SMS provider is available.
    if (!ALLOW_DEV_PHONE_OTP && !SMS_PROVIDER_CONFIGURED) {
      return new Response(
        JSON.stringify({
          error:
            "SMS verification is not yet available. Please contact support at support@iou.llc.",
          code: "SMS_UNAVAILABLE",
          ok: false,
          stage,
        }),
        { status: 503, headers: corsHeaders }
      );
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

    // ── 3. Parse and validate phone ────────────────────────────────────────
    stage = "parse";

    const body = await req.json().catch(() => ({}));
    const rawPhone = typeof body?.phone === "string" ? body.phone : "";

    const phone = normalizeToE164(rawPhone);

    if (!phone) {
      return new Response(
        JSON.stringify({
          error: "Invalid phone number. Please enter a valid number including area code.",
          ok: false,
          stage,
        }),
        { status: 422, headers: corsHeaders }
      );
    }

    // ── 4. Save normalized phone to profile (server-authoritative write) ───
    // The client never writes profiles.phone directly. This function updates
    // it here so the stored phone matches exactly what is being verified.
    stage = "save-phone";

    const { error: phoneUpdateError } = await supabase
      .from("profiles")
      .update({ phone })
      .eq("id", user.id);

    if (phoneUpdateError) {
      throw new Error(`Could not save phone: ${phoneUpdateError.message}`);
    }

    // ── 5. Generate OTP ────────────────────────────────────────────────────
    stage = "generate-otp";

    // Dev path: use fixed known code so testers don't need a real phone.
    // Production path: cryptographically random code, sent via SMS.
    const otp = ALLOW_DEV_PHONE_OTP ? DEV_OTP : generateOtp(CODE_DIGITS);
    const expiresAt = new Date(Date.now() + CODE_TTL_MINUTES * 60 * 1000).toISOString();

    // ── 6. Insert verification row (service role only) ─────────────────────
    stage = "insert-verification";

    const { error: insertError } = await supabase
      .from("phone_verifications")
      .insert({
        user_id: user.id,
        phone,
        code: otp,
        expires_at: expiresAt,
      });

    if (insertError) {
      throw new Error(`Could not create verification: ${insertError.message}`);
    }

    // ── 7. Dispatch SMS (production only) ──────────────────────────────────
    if (SMS_PROVIDER_CONFIGURED) {
      // Wire in the real SMS provider here (Twilio, AWS SNS, etc.) when
      // SMS_PROVIDER_CONFIGURED=true is set in the production project.
      // Until then this path is unreachable (the 503 guard above blocks it).
      stage = "send-sms";
      throw new Error(
        "Server configuration error: SMS_PROVIDER_CONFIGURED is true but no provider is implemented."
      );
    }

    stage = "success";

    // DEV diagnostic: log enough to confirm what was stored without exposing
    // production OTPs. In production ALLOW_DEV_PHONE_OTP is false so the
    // extended fields are never emitted.
    console.log("[request-phone-verification] verification created", {
      userId: user.id,
      isDevMode: ALLOW_DEV_PHONE_OTP,
      ...(ALLOW_DEV_PHONE_OTP && {
        normalizedPhone: phone,
        codeLength: otp.length,
        expiresAt,
      }),
    });

    // In production the OTP is never returned — it is delivered only via SMS.
    // In dev mode (ALLOW_DEV_PHONE_OTP=true) the code is returned so the
    // development build can display it without a real SMS provider.
    return new Response(
      JSON.stringify({
        ok: true,
        stage,
        ...(ALLOW_DEV_PHONE_OTP && { dev_code: otp }),
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (err: any) {
    console.error("[request-phone-verification] failed", {
      stage,
      message: err?.message ?? null,
    });

    return new Response(
      JSON.stringify({
        error: err?.message ?? "Unknown error",
        stage,
        ok: false,
      }),
      { status: 500, headers: corsHeaders }
    );
  }
});
