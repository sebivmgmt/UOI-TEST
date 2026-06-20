import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { resolvePlaidConfig } from "../_shared/plaidConfig.ts";

// ---------------------------------------------------------------------------
// dwolla-attach-funding-source
//
// Auth ordering:
//   1. Require valid Bearer header → 401
//   2. Read SUPABASE_URL + SUPABASE_ANON_KEY only
//   3. Create auth-only client (anon key)
//   4. auth.getUser(token) → 401 on invalid/expired JWT
//   5. Only after getUser() succeeds: read SERVICE_ROLE_KEY and create
//      service-role client for database operations
//
// Idempotency path (existing dwolla_funding_source_id):
//   1. Fetch the funding source from Dwolla and confirm it exists
//   2. Confirm its customer link matches the authenticated user's dwolla_customer_id
//   3. Confirm its status is not "removed"
//   4. Only then: reconcile profile to ach_status='ready' and return confirmed result
//
// Ready-state preservation:
//   Before writing ach_status='not_ready', check whether the user already has
//   a confirmed connection on a different bank account. If so, preserve the
//   existing ready state rather than downgrading it.
//
// Security:
//   - Config errors never reach unauthenticated callers.
//   - SERVICE_ROLE_KEY is not read until the caller is confirmed.
//   - User identity derived from JWT only — never from the request body.
//   - ach_status='ready' written only after confirmed Dwolla success.
// ---------------------------------------------------------------------------

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function toBasicAuth(key: string, secret: string): string {
  const raw = `${key}:${secret}`;
  const bytes = new TextEncoder().encode(raw);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return "Basic " + btoa(binary);
}

async function safeJson(res: Response): Promise<any> {
  const text = await res.text();
  try {
    return text ? JSON.parse(text) : null;
  } catch {
    return { raw: text };
  }
}

function resolveDwollaConfig(): { env: "sandbox" | "production"; base: string } {
  const raw = Deno.env.get("DWOLLA_ENV");

  if (!raw) {
    throw new Error(
      'Server configuration error: DWOLLA_ENV is not set. Set it to "sandbox" or "production".'
    );
  }
  if (raw === "production") {
    return { env: "production", base: "https://api.dwolla.com" };
  }
  if (raw === "sandbox") {
    return { env: "sandbox", base: "https://api-sandbox.dwolla.com" };
  }
  throw new Error(
    `Server configuration error: DWOLLA_ENV must be "sandbox" or "production", got "${raw}".`
  );
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
  const authClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── Step 4: Validate JWT — return 401 on failure ──────────────────────
  const { data: { user }, error: userError } = await authClient.auth.getUser(token);
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
    // ── A. Resolve and validate environments ───────────────────────────
    stage = "env";

    const plaid = resolvePlaidConfig();
    const dwolla = resolveDwollaConfig();

    if (plaid.env !== dwolla.env) {
      throw new Error(
        `Server configuration error: Plaid environment (${plaid.env}) and ` +
          `Dwolla environment (${dwolla.env}) do not match. ` +
          `Both must be "sandbox" or both must be "production".`
      );
    }

    console.log("[dwolla-attach-funding-source] environments resolved", {
      plaid_env: plaid.env,
      dwolla_env: dwolla.env,
    });

    const DWOLLA_KEY = Deno.env.get("DWOLLA_KEY");
    const DWOLLA_SECRET = Deno.env.get("DWOLLA_SECRET");
    if (!DWOLLA_KEY || !DWOLLA_SECRET) throw new Error("Missing Dwolla credentials");

    // ── B. Parse and validate request body ────────────────────────────
    stage = "parse-body";

    const body = await req.json().catch(() => ({}));
    const plaid_account_id =
      typeof body?.plaid_account_id === "string" ? body.plaid_account_id.trim() : "";
    if (!plaid_account_id) throw new Error("Missing plaid_account_id");

    // ── C. Load caller's profile ──────────────────────────────────────
    // plaid_account_id is included to support ready-state preservation:
    // if profile.plaid_account_id differs from the one being attached and
    // ach_status is 'ready', an existing confirmed connection must not be
    // downgraded by a failed attempt on a new account.
    stage = "profile";

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("id, dwolla_customer_id, dwolla_customer_status, ach_status, plaid_account_id")
      .eq("id", user.id)
      .single();

    if (profileError || !profile) throw new Error("Profile not found");

    // ── D. Dwolla auth ────────────────────────────────────────────────
    stage = "dwolla-auth";

    const dwollaAuthRes = await fetch(`${dwolla.base}/token`, {
      method: "POST",
      headers: {
        Authorization: toBasicAuth(DWOLLA_KEY, DWOLLA_SECRET),
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
      },
      body: "grant_type=client_credentials",
    });

    const dwollaAuthData = await safeJson(dwollaAuthRes);
    if (!dwollaAuthRes.ok || !dwollaAuthData?.access_token) {
      throw new Error(`Dwolla auth failed: ${JSON.stringify(dwollaAuthData)}`);
    }

    const dwollaAccessToken: string = dwollaAuthData.access_token;

    // ── E. Create or reuse Dwolla customer ───────────────────────────
    stage = "dwolla-customer";

    let dwollaCustomerId: string | null = profile.dwolla_customer_id ?? null;

    if (!dwollaCustomerId) {
      const createCustomerRes = await fetch(`${dwolla.base}/customers`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${dwollaAccessToken}`,
          "Content-Type": "application/vnd.dwolla.v1.hal+json",
          Accept: "application/vnd.dwolla.v1.hal+json",
        },
        body: JSON.stringify({
          firstName: "IOU",
          lastName: "User",
          email: user.email,
          type: "unverified",
        }),
      });

      const createCustomerBody = await safeJson(createCustomerRes);
      const customerLocation = createCustomerRes.headers.get("location");

      if (!createCustomerRes.ok || !customerLocation) {
        throw new Error(
          `Dwolla customer create failed: ${JSON.stringify(createCustomerBody)}`
        );
      }

      dwollaCustomerId = customerLocation.split("/").pop() ?? null;
      if (!dwollaCustomerId) throw new Error("Dwolla customer create returned no id");

      const { error: saveCustomerError } = await supabase
        .from("profiles")
        .update({
          dwolla_customer_id: dwollaCustomerId,
          dwolla_customer_status: "created",
        })
        .eq("id", user.id);

      if (saveCustomerError) throw new Error(saveCustomerError.message);
    }

    // ── F. Load selected bank account and Plaid item (ownership check) ─
    stage = "selected-bank-account";

    const { data: bankAccount, error: bankAccountError } = await supabase
      .from("bank_accounts")
      .select(
        "id, plaid_item_id, plaid_account_id, account_name, official_name, " +
        "mask, institution_name, dwolla_funding_source_id"
      )
      .eq("user_id", user.id)
      .eq("plaid_account_id", plaid_account_id)
      .single();

    if (bankAccountError || !bankAccount) {
      throw new Error("Selected bank account row not found");
    }

    stage = "plaid-item";

    const { data: plaidItem, error: plaidItemError } = await supabase
      .from("plaid_items")
      .select("item_id, access_token, institution_name")
      .eq("user_id", user.id)
      .eq("item_id", bankAccount.plaid_item_id)
      .single();

    if (plaidItemError || !plaidItem?.access_token) {
      throw new Error("No Plaid access token found for selected account");
    }

    // ── G. Idempotency: existing funding source ───────────────────────
    // A prior run may have attached a funding source but failed to update the
    // profile. Before reconciling, validate the stored funding source against
    // Dwolla: confirm it exists, belongs to this user's customer, and is not removed.
    if (bankAccount.dwolla_funding_source_id) {
      stage = "existing-funding-source-validation";

      const fsValidateRes = await fetch(
        `${dwolla.base}/funding-sources/${bankAccount.dwolla_funding_source_id}`,
        {
          method: "GET",
          headers: {
            Authorization: `Bearer ${dwollaAccessToken}`,
            Accept: "application/vnd.dwolla.v1.hal+json",
          },
        }
      );

      if (!fsValidateRes.ok) {
        console.error("[dwolla-attach-funding-source] existing funding source not found on Dwolla", {
          userId: user.id,
          fundingSourceId: bankAccount.dwolla_funding_source_id,
          status: fsValidateRes.status,
        });
        return new Response(
          JSON.stringify({
            ok: false,
            stage: "existing-funding-source-validation",
            error: `Existing funding source not reachable (HTTP ${fsValidateRes.status}). Remove and re-link your bank account.`,
          }),
          { status: 500, headers: corsHeaders }
        );
      }

      const fsData = await safeJson(fsValidateRes);

      // Confirm the funding source belongs to this user's Dwolla customer.
      const customerHref = fsData?._links?.customer?.href ?? "";
      const linkedCustomerId = customerHref.split("/").pop() ?? "";
      if (!linkedCustomerId || linkedCustomerId !== dwollaCustomerId) {
        console.error("[dwolla-attach-funding-source] funding source customer mismatch", {
          userId: user.id,
          expectedCustomer: dwollaCustomerId,
          linkedCustomer: linkedCustomerId,
        });
        return new Response(
          JSON.stringify({
            ok: false,
            stage: "existing-funding-source-validation",
            error: "Existing funding source belongs to a different customer. Contact support.",
          }),
          { status: 500, headers: corsHeaders }
        );
      }

      // Confirm the funding source has not been removed.
      if (fsData?.status === "removed") {
        console.error("[dwolla-attach-funding-source] existing funding source is removed", {
          userId: user.id,
          fundingSourceId: bankAccount.dwolla_funding_source_id,
        });
        return new Response(
          JSON.stringify({
            ok: false,
            stage: "existing-funding-source-validation",
            error: "Existing funding source has been removed. Remove and re-link your bank account.",
          }),
          { status: 500, headers: corsHeaders }
        );
      }

      // Validation passed. Reconcile the profile to the confirmed ready state.
      stage = "profile-reconcile";

      const institutionName =
        plaidItem.institution_name ?? bankAccount.institution_name ?? null;

      const { data: reconciledProfile, error: reconcileError } = await supabase
        .from("profiles")
        .update({
          ach_status: "ready",
          bank_linked: true,
          plaid_linked: true,
          plaid_account_id: plaid_account_id,
          plaid_institution_name: institutionName,
          bank_name: institutionName,
          bank_provider: "Plaid",
          bank_account_mask: bankAccount.mask ?? null,
          account_mask: bankAccount.mask ?? null,
        })
        .eq("id", user.id)
        .select("ach_status")
        .single();

      if (reconcileError) {
        console.error("[dwolla-attach-funding-source] profile reconcile failed", {
          userId_suffix: user.id.slice(-6),
          message: reconcileError.message,
          code: (reconcileError as any).code ?? null,
        });
        return new Response(
          JSON.stringify({
            ok: false,
            stage: "profile-reconcile",
            retryable: true,
            error: "Profile reconciliation failed. Retry to complete setup.",
          }),
          { status: 500, headers: corsHeaders }
        );
      }

      if (reconciledProfile?.ach_status !== "ready") {
        console.error("[dwolla-attach-funding-source] profile reconcile wrote wrong status", {
          userId_suffix: user.id.slice(-6),
          actual_ach_status: reconciledProfile?.ach_status ?? null,
        });
        return new Response(
          JSON.stringify({
            ok: false,
            stage: "profile-reconcile",
            retryable: true,
            error: "Profile reconciliation did not persist. Please retry.",
          }),
          { status: 500, headers: corsHeaders }
        );
      }

      console.log("[dwolla-attach-funding-source] funding source validated and profile reconciled", {
        userId_suffix: user.id.slice(-6),
        fundingSourceId: bankAccount.dwolla_funding_source_id,
        fundingSourceStatus: fsData?.status,
        confirmed_ach_status: reconciledProfile.ach_status,
      });

      return new Response(
        JSON.stringify({
          ok: true,
          stage: "already-attached",
          ach_status: "ready",
          dwollaCustomerId,
          fundingSourceId: bankAccount.dwolla_funding_source_id,
        }),
        { status: 200, headers: corsHeaders }
      );
    }

    // ── H. New attachment path — ready-state preservation ────────────
    // Before writing not_ready on any failure below, verify that the user's
    // currently registered bank account is still valid on Dwolla. A profile
    // field comparison alone is not sufficient: the funding source must exist
    // on Dwolla, belong to this user's customer, and not be removed.
    let hasExistingValidConnection = false;

    if (
      profile.ach_status === "ready" &&
      profile.plaid_account_id !== null &&
      profile.plaid_account_id !== plaid_account_id
    ) {
      // 1. Load the existing confirmed bank account row.
      const { data: existingBankAccount } = await supabase
        .from("bank_accounts")
        .select("dwolla_funding_source_id")
        .eq("user_id", user.id)
        .eq("plaid_account_id", profile.plaid_account_id)
        .single();

      const existingFundingSourceId =
        existingBankAccount?.dwolla_funding_source_id ?? null;

      // 2. Require a non-null funding source ID.
      if (existingFundingSourceId) {
        // 3. Fetch the funding source from Dwolla.
        const existingFsRes = await fetch(
          `${dwolla.base}/funding-sources/${existingFundingSourceId}`,
          {
            method: "GET",
            headers: {
              Authorization: `Bearer ${dwollaAccessToken}`,
              Accept: "application/vnd.dwolla.v1.hal+json",
            },
          }
        );

        if (existingFsRes.ok) {
          const existingFsData = await safeJson(existingFsRes);

          // 4. Confirm customer link matches this user's dwollaCustomerId.
          const existingCustomerHref =
            existingFsData?._links?.customer?.href ?? "";
          const existingLinkedCustomerId =
            existingCustomerHref.split("/").pop() ?? "";

          // 5. Confirm status is not removed or otherwise unusable.
          const existingStatus = existingFsData?.status ?? "";

          if (
            existingLinkedCustomerId === dwollaCustomerId &&
            existingStatus !== "removed" &&
            existingStatus !== ""
          ) {
            hasExistingValidConnection = true;
          }
        }
      }
    }

    // ── I. Create Plaid processor token ──────────────────────────────
    stage = "processor-token";

    const processorRes = await fetch(`${plaid.baseUrl}/processor/token/create`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Plaid-Version": "2020-09-14",
      },
      body: JSON.stringify({
        client_id: plaid.clientId,
        secret: plaid.secret,
        access_token: plaidItem.access_token,
        account_id: plaid_account_id,
        processor: "dwolla",
      }),
    });

    const processorData = await safeJson(processorRes);

    if (!processorRes.ok || !processorData?.processor_token) {
      console.error("[dwolla-attach-funding-source] processor token failed", {
        plaid_status: processorRes.status,
        error_type: processorData?.error_type ?? null,
        error_code: processorData?.error_code ?? null,
        error_message: processorData?.error_message ?? null,
        request_id: processorData?.request_id ?? null,
        display_message: processorData?.display_message ?? null,
      });
      if (!hasExistingValidConnection) {
        await supabase
          .from("profiles")
          .update({ ach_status: "not_ready" })
          .eq("id", user.id);
      }
      throw new Error(`Processor token failed: ${JSON.stringify(processorData)}`);
    }

    console.log("[dwolla-attach-funding-source] processor token created", {
      plaid_status: processorRes.status,
      has_token: true,
    });

    const processor_token: string = processorData.processor_token;

    // ── J. Attach funding source to Dwolla customer ───────────────────
    stage = "funding-source";

    const fundingSourceName =
      bankAccount.official_name || bankAccount.account_name || "IOU Bank Account";

    const fsRes = await fetch(`${dwolla.base}/customers/${dwollaCustomerId}/funding-sources`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${dwollaAccessToken}`,
        "Content-Type": "application/vnd.dwolla.v1.hal+json",
        Accept: "application/vnd.dwolla.v1.hal+json",
      },
      body: JSON.stringify({
        plaidToken: processor_token,
        name: fundingSourceName,
      }),
    });

    const fsBody = await safeJson(fsRes);
    const fsLocation = fsRes.headers.get("location");

    if (!fsRes.ok || !fsLocation) {
      console.error("[dwolla-attach-funding-source] funding source create failed", {
        dwolla_status: fsRes.status,
        code: fsBody?.code ?? null,
        message: fsBody?.message ?? null,
        embedded_errors: fsBody?._embedded?.errors ?? null,
      });
      if (!hasExistingValidConnection) {
        await supabase
          .from("profiles")
          .update({ ach_status: "not_ready" })
          .eq("id", user.id);
      }
      throw new Error(`Funding source create failed: ${JSON.stringify(fsBody)}`);
    }

    console.log("[dwolla-attach-funding-source] funding source created", {
      dwolla_status: fsRes.status,
      has_location: !!fsLocation,
    });

    const fundingSourceId = fsLocation.split("/").pop() ?? null;
    if (!fundingSourceId) {
      if (!hasExistingValidConnection) {
        await supabase
          .from("profiles")
          .update({ ach_status: "not_ready" })
          .eq("id", user.id);
      }
      throw new Error("Funding source created but no id returned");
    }

    // ── K. Persist funding source to bank_accounts ────────────────────
    stage = "save-db";

    const { error: saveFsError } = await supabase
      .from("bank_accounts")
      .update({
        dwolla_funding_source_url: fsLocation,
        dwolla_funding_source_id: fundingSourceId,
        dwolla_funding_source_status: "attached",
        updated_at: new Date().toISOString(),
      })
      .eq("user_id", user.id)
      .eq("plaid_account_id", plaid_account_id);

    if (saveFsError) throw new Error(saveFsError.message);

    // ── L. Server-authoritative readiness update ──────────────────────
    // Funding source confirmed. Only now is the profile marked ready.
    // If this write fails: return ok:false retryable:true. The next retry
    // enters the idempotency path (dwolla_funding_source_id is now set),
    // validates the funding source on Dwolla, and performs reconciliation.
    stage = "profile-ready";

    const institutionName =
      plaidItem.institution_name ?? bankAccount.institution_name ?? null;

    const { data: updatedProfile, error: profileUpdateError } = await supabase
      .from("profiles")
      .update({
        ach_status: "ready",
        bank_linked: true,
        plaid_linked: true,
        plaid_account_id: plaid_account_id,
        plaid_institution_name: institutionName,
        bank_name: institutionName,
        bank_provider: "Plaid",
        bank_account_mask: bankAccount.mask ?? null,
        account_mask: bankAccount.mask ?? null,
      })
      .eq("id", user.id)
      .select("ach_status")
      .single();

    if (profileUpdateError) {
      console.error("[dwolla-attach-funding-source] profile ready update failed", {
        userId_suffix: user.id.slice(-6),
        message: profileUpdateError.message,
        code: (profileUpdateError as any).code ?? null,
      });
      return new Response(
        JSON.stringify({
          ok: false,
          stage: "profile-ready",
          retryable: true,
          error: "Payment account attached but profile update failed. Retry to complete setup.",
        }),
        { status: 500, headers: corsHeaders }
      );
    }

    if (updatedProfile?.ach_status !== "ready") {
      console.error("[dwolla-attach-funding-source] profile ready update wrote wrong status", {
        userId_suffix: user.id.slice(-6),
        actual_ach_status: updatedProfile?.ach_status ?? null,
      });
      return new Response(
        JSON.stringify({
          ok: false,
          stage: "profile-ready",
          retryable: true,
          error: "Payment account attached but profile status was not updated. Please retry.",
        }),
        { status: 500, headers: corsHeaders }
      );
    }

    console.log("[dwolla-attach-funding-source] profile marked ready", {
      userId_suffix: user.id.slice(-6),
      confirmed_ach_status: updatedProfile.ach_status,
    });

    stage = "success";

    return new Response(
      JSON.stringify({
        ok: true,
        stage,
        ach_status: "ready",
        dwollaCustomerId,
        fundingSourceId,
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (err: any) {
    console.error("[dwolla-attach-funding-source] failed", {
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
