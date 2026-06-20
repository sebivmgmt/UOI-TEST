// Canonical Plaid environment resolution for all IOU Edge Functions.
//
// Required secrets — set per Supabase project in Dashboard → Settings → Edge Functions:
//   PLAID_ENV                  "sandbox" | "production"
//   PLAID_CLIENT_ID_SANDBOX    sandbox client id          (dev project only)
//   PLAID_SECRET_SANDBOX       sandbox secret             (dev project only)
//   PLAID_CLIENT_ID_PRODUCTION production client id       (production project only)
//   PLAID_SECRET_PRODUCTION    production secret          (production project only)
//
// Security invariants:
//   - PLAID_ENV must be set explicitly. Missing or invalid values throw immediately.
//   - Production credentials are never used in sandbox mode.
//   - Sandbox credentials are never used in production mode.
//   - No credential fallbacks across environments.
//   - No credential values are logged or returned to callers.

export type PlaidEnv = "sandbox" | "production";

export type ResolvedPlaidConfig = {
  env: PlaidEnv;
  clientId: string;
  secret: string;
  baseUrl: string;
};

export function resolvePlaidConfig(): ResolvedPlaidConfig {
  const rawPlaidEnv = Deno.env.get("PLAID_ENV");

  if (!rawPlaidEnv) {
    throw new Error(
      'Server configuration error: PLAID_ENV is not set. Set it to "sandbox" or "production".'
    );
  }

  if (rawPlaidEnv !== "sandbox" && rawPlaidEnv !== "production") {
    throw new Error(
      `Server configuration error: PLAID_ENV must be "sandbox" or "production", got "${rawPlaidEnv}".`
    );
  }

  const env: PlaidEnv = rawPlaidEnv;

  let clientId: string | undefined;
  let secret: string | undefined;

  if (env === "production") {
    clientId = Deno.env.get("PLAID_CLIENT_ID_PRODUCTION");
    secret = Deno.env.get("PLAID_SECRET_PRODUCTION");
    if (!clientId) {
      throw new Error("Server configuration error: PLAID_CLIENT_ID_PRODUCTION is not set.");
    }
    if (!secret) {
      throw new Error("Server configuration error: PLAID_SECRET_PRODUCTION is not set.");
    }
  } else {
    clientId = Deno.env.get("PLAID_CLIENT_ID_SANDBOX");
    secret = Deno.env.get("PLAID_SECRET_SANDBOX");
    if (!clientId) {
      throw new Error("Server configuration error: PLAID_CLIENT_ID_SANDBOX is not set.");
    }
    if (!secret) {
      throw new Error("Server configuration error: PLAID_SECRET_SANDBOX is not set.");
    }
  }

  const baseUrl =
    env === "production" ? "https://production.plaid.com" : "https://sandbox.plaid.com";

  return { env, clientId, secret, baseUrl };
}
