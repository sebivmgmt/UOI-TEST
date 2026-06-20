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

async function safeJson(res: Response) {
  const text = await res.text();
  try {
    return text ? JSON.parse(text) : null;
  } catch {
    return { raw: text };
  }
}

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
  // JWT validation does not require elevated privileges.
  // SERVICE_ROLE_KEY is not read until after getUser() succeeds.
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

  // ── Step 5: Authentication succeeded — now read SERVICE_ROLE_KEY ───────
  // The service-role key is only accessed after the caller is confirmed.
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SERVICE_ROLE_KEY) {
    return new Response(JSON.stringify({ error: "Server error" }), {
      status: 500,
      headers: corsHeaders,
    });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  let stage = "start";

  try {
    stage = "env";

    const { env, clientId, secret, baseUrl } = resolvePlaidConfig();

    console.log("[exchange-token] plaid environment resolved", {
      plaid_env: env,
      base_url: baseUrl,
    });

    stage = "parse-body";

    const body = await req.json().catch(() => ({}));
    const public_token =
      typeof body?.public_token === "string" ? body.public_token.trim() : "";
    const institution_name =
      typeof body?.institution_name === "string" ? body.institution_name : null;
    const metadata_accounts = Array.isArray(body?.metadata_accounts)
      ? body.metadata_accounts
      : [];

    if (!public_token) {
      throw new Error("Missing public_token");
    }

    stage = "plaid-exchange";

    const exchangeRes = await fetch(`${baseUrl}/item/public_token/exchange`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        client_id: clientId,
        secret,
        public_token,
      }),
    });

    const exchangeData = await safeJson(exchangeRes);

    if (!exchangeRes.ok || !exchangeData?.access_token) {
      throw new Error(
        `Plaid token exchange failed: ${JSON.stringify(exchangeData)}`
      );
    }

    const access_token: string = exchangeData.access_token;
    const item_id: string = exchangeData.item_id;

    stage = "save-plaid-item";

    const { error: itemError } = await supabase
      .from("plaid_items")
      .upsert(
        {
          user_id: user.id,
          item_id,
          access_token,
          institution_name,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "item_id" }
      );

    if (itemError) {
      throw new Error(`Failed to save plaid item: ${itemError.message}`);
    }

    stage = "map-accounts";

    const accounts = metadata_accounts
      .map((acct: any) => ({
        plaid_account_id: acct.id ?? acct.plaid_account_id ?? null,
        account_name: acct.name ?? acct.account_name ?? null,
        official_name: acct.official_name ?? null,
        mask: acct.mask ?? null,
        type: acct.type ?? null,
        subtype: acct.subtype ?? null,
        verification_status: acct.verification_status ?? null,
        is_active: true,
      }))
      .filter((a: any) => Boolean(a.plaid_account_id));

    stage = "save-bank-accounts";

    // Persist account rows server-side. The client must not write to bank_accounts
    // directly; this is the only authoritative write path. dwolla-attach-funding-source
    // depends on these rows existing before it runs.
    if (accounts.length > 0) {
      const bankAccountRows = accounts.map((acct: any) => ({
        user_id: user.id,
        plaid_item_id: item_id,
        plaid_account_id: acct.plaid_account_id,
        account_name: acct.account_name,
        official_name: acct.official_name,
        mask: acct.mask,
        type: acct.type,
        subtype: acct.subtype,
        verification_status: acct.verification_status,
        is_active: acct.is_active !== false,
        institution_name: institution_name,
        updated_at: new Date().toISOString(),
      }));

      const { error: bankAccountError } = await supabase
        .from("bank_accounts")
        .upsert(bankAccountRows, { onConflict: "plaid_account_id" });

      if (bankAccountError) {
        throw new Error(`Failed to save bank accounts: ${bankAccountError.message}`);
      }
    }

    stage = "success";

    return new Response(JSON.stringify({ item_id, accounts }), {
      status: 200,
      headers: corsHeaders,
    });
  } catch (err: any) {
    console.error("[exchange-token] failed", {
      stage,
      message: err?.message ?? null,
    });

    return new Response(
      JSON.stringify({ error: err?.message ?? "Unknown error", stage }),
      { status: 500, headers: corsHeaders }
    );
  }
});
