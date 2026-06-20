import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { resolvePlaidConfig } from "../_shared/plaidConfig.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // ── Step 1: Require valid Bearer header ────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: corsHeaders,
    });
  }
  const token = authHeader.replace("Bearer ", "").trim();

  // ── Step 2: Read SUPABASE_URL and SUPABASE_ANON_KEY ───────────────────
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return new Response(JSON.stringify({ error: "Server error" }), {
      status: 500,
      headers: corsHeaders,
    });
  }

  // ── Step 3: Create auth-only client (anon key) ─────────────────────────
  // JWT validation does not require elevated privileges. The anon key is
  // sufficient. The service-role key is not read here.
  const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── Step 4: Validate JWT — return 401 on failure ──────────────────────
  const {
    data: { user },
    error: userError,
  } = await authClient.auth.getUser(token);

  if (userError || !user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: corsHeaders,
    });
  }

  // ── Authenticated. SERVICE_ROLE_KEY is not needed: this function has no
  //    database operations. user.id is passed to Plaid only. ────────────
  let stage = "start";

  try {
    stage = "env";

    const { env, clientId, secret, baseUrl } = resolvePlaidConfig();
    const PLAID_CLIENT_NAME = Deno.env.get("PLAID_CLIENT_NAME") ?? "IOU";

    console.log("[create-link-token] plaid environment resolved", {
      plaid_env: env,
      base_url: baseUrl,
    });

    stage = "create-link-token";

    const linkTokenRes = await fetch(`${baseUrl}/link/token/create`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Plaid-Version": "2020-09-14",
      },
      body: JSON.stringify({
        client_id: clientId,
        secret,
        client_name: PLAID_CLIENT_NAME,
        user: { client_user_id: user.id },
        products: ["auth"],
        country_codes: ["US"],
        language: "en",
      }),
    });

    const linkTokenData = await linkTokenRes.json().catch(() => null);

    if (!linkTokenRes.ok || !linkTokenData?.link_token) {
      // Log safe fields only — error_type, error_code, request_id are not secrets.
      console.error("[create-link-token] Plaid rejected link token request", {
        plaid_status: linkTokenRes.status,
        error_type: linkTokenData?.error_type ?? null,
        error_code: linkTokenData?.error_code ?? null,
        error_message: linkTokenData?.error_message ?? null,
        request_id: linkTokenData?.request_id ?? null,
        display_message: linkTokenData?.display_message ?? null,
      });
      throw new Error(
        `Plaid link token creation failed: ${JSON.stringify(linkTokenData)}`
      );
    }

    stage = "success";

    return new Response(
      JSON.stringify({ link_token: linkTokenData.link_token }),
      { status: 200, headers: corsHeaders }
    );
  } catch (err: any) {
    console.error("[create-link-token] failed", {
      stage,
      message: err?.message ?? null,
    });

    return new Response(
      JSON.stringify({ error: err?.message ?? "Unknown error", stage }),
      { status: 500, headers: corsHeaders }
    );
  }
});
