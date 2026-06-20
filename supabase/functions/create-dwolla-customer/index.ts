import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function toBasicAuth(key: string, secret: string) {
  const raw = `${key}:${secret}`;
  const bytes = new TextEncoder().encode(raw);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return "Basic " + btoa(binary);
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

async function safeJson(res: Response) {
  const text = await res.text();
  try {
    return text ? JSON.parse(text) : null;
  } catch {
    return { raw: text };
  }
}

function splitFullName(fullName: string) {
  const trimmed = fullName.trim().replace(/\s+/g, " ");
  const parts = trimmed.split(" ");
  const firstName = parts[0] || "";
  const lastName = parts.slice(1).join(" ") || "User";
  return { firstName, lastName };
}

function normalizeDobToIso(value: string) {
  const raw = value.trim();

  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    return raw;
  }

  const mdy = raw.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  if (mdy) {
    const [, mm, dd, yyyy] = mdy;
    return `${yyyy}-${mm}-${dd}`;
  }

  throw new Error("DOB must be MM/DD/YYYY or YYYY-MM-DD");
}

function inferIdentityStatus(dwollaStatus: string | null) {
  const status = (dwollaStatus || "").toLowerCase();

  if (status === "verified") return "verified";
  if (status === "retry") return "retry";
  if (status === "document") return "document";
  if (status === "kba") return "kba";
  if (status === "suspended") return "suspended";
  if (status === "deactivated") return "deactivated";
  if (status === "unverified") return "unverified";

  return status || "submitted";
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let stage = "start";

  try {
    stage = "env";

    const DWOLLA_KEY = Deno.env.get("DWOLLA_KEY");
    const DWOLLA_SECRET = Deno.env.get("DWOLLA_SECRET");
    const DWOLLA_ENV = Deno.env.get("DWOLLA_ENV") ?? "sandbox";
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!DWOLLA_KEY || !DWOLLA_SECRET) {
      throw new Error("Missing Dwolla credentials");
    }

    if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
      throw new Error("Missing Supabase credentials");
    }

    const dwollaBase =
      DWOLLA_ENV === "production"
        ? "https://api.dwolla.com"
        : "https://api-sandbox.dwolla.com";

    stage = "auth-user";

    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      throw new Error("Missing auth");
    }

    const token = authHeader.replace("Bearer ", "").trim();

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(token);

    if (userError || !user) {
      throw new Error("Invalid user");
    }

    stage = "load-profile";

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select(`
        id,
        full_name,
        email,
        phone,
        dob,
        address_1,
        address_2,
        city,
        state,
        postal_code,
        ssn_last_4,
        dwolla_customer_id,
        dwolla_customer_status,
        identity_status
      `)
      .eq("id", user.id)
      .single();

    if (profileError || !profile) {
      throw new Error("Profile not found");
    }

    if (
      !profile.full_name ||
      !profile.email ||
      !profile.dob ||
      !profile.address_1 ||
      !profile.city ||
      !profile.state ||
      !profile.postal_code ||
      !profile.ssn_last_4
    ) {
      throw new Error("Missing identity fields");
    }

    const { firstName, lastName } = splitFullName(profile.full_name);
    const dateOfBirth = normalizeDobToIso(profile.dob);
    const ssn = String(profile.ssn_last_4).replace(/\D/g, "");

    if (ssn.length !== 4 && ssn.length !== 9) {
      throw new Error("SSN must be last 4 or full 9 digits");
    }

    stage = "dwolla-auth";

    const authRes = await fetch(`${dwollaBase}/token`, {
      method: "POST",
      headers: {
        Authorization: toBasicAuth(DWOLLA_KEY, DWOLLA_SECRET),
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
      },
      body: "grant_type=client_credentials",
    });

    const authData = await safeJson(authRes);

    if (!authRes.ok || !authData?.access_token) {
      throw new Error(`Dwolla auth failed: ${JSON.stringify(authData)}`);
    }

    const accessToken = authData.access_token;

    // Normalize E.164 phone (+17703137707) to the 10-digit format Dwolla requires.
    // The stored profile phone is preserved as-is; only the Dwolla payload uses this.
    const phoneDigits = String(profile.phone ?? "").replace(/\D/g, "");
    const dwollaPhone =
      phoneDigits.length === 11 && phoneDigits.startsWith("1")
        ? phoneDigits.slice(1)
        : phoneDigits;
    if (!/^\d{10}$/.test(dwollaPhone)) {
      return jsonResponse(
        {
          ok: false,
          stage: "validate-phone",
          error: "A valid 10-digit US phone number is required.",
        },
        400,
      );
    }

    let dwollaCustomerId = profile.dwolla_customer_id ?? null;
    let dwollaStatus = profile.dwolla_customer_status ?? null;

    if (!dwollaCustomerId) {
      stage = "create-customer";

      const customerRes = await fetch(`${dwollaBase}/customers`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/vnd.dwolla.v1.hal+json",
          Accept: "application/vnd.dwolla.v1.hal+json",
        },
        body: JSON.stringify({
          firstName,
          lastName,
          email: profile.email,
          phone: dwollaPhone,
          type: "personal",
          address1: profile.address_1,
          address2: profile.address_2 || undefined,
          city: profile.city,
          state: profile.state,
          postalCode: profile.postal_code,
          dateOfBirth,
          ssn,
        }),
      });

      const customerBody = await safeJson(customerRes);
      const location = customerRes.headers.get("location");

      if (!customerRes.ok || !location) {
        throw new Error(
          `Dwolla customer create failed: ${JSON.stringify(customerBody)}`
        );
      }

      dwollaCustomerId = location.split("/").pop() ?? null;

      if (!dwollaCustomerId) {
        throw new Error("Dwolla customer created but no id was returned");
      }

      const statusRes = await fetch(`${dwollaBase}/customers/${dwollaCustomerId}`, {
        method: "GET",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          Accept: "application/vnd.dwolla.v1.hal+json",
        },
      });

      const statusBody = await safeJson(statusRes);

      if (!statusRes.ok) {
        throw new Error(
          `Dwolla customer retrieve failed: ${JSON.stringify(statusBody)}`
        );
      }

      dwollaStatus =
        typeof statusBody?.status === "string" ? statusBody.status : "submitted";
    } else {
      stage = "retrieve-existing-customer";

      const statusRes = await fetch(`${dwollaBase}/customers/${dwollaCustomerId}`, {
        method: "GET",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          Accept: "application/vnd.dwolla.v1.hal+json",
        },
      });

      const statusBody = await safeJson(statusRes);

      if (!statusRes.ok) {
        throw new Error(
          `Dwolla customer retrieve failed: ${JSON.stringify(statusBody)}`
        );
      }

      dwollaStatus =
        typeof statusBody?.status === "string" ? statusBody.status : dwollaStatus;
    }

    stage = "save-profile";

    const identityStatus = inferIdentityStatus(dwollaStatus);

    const updatePayload: Record<string, unknown> = {
      dwolla_customer_id: dwollaCustomerId,
      dwolla_customer_status: dwollaStatus,
      identity_status: identityStatus,
    };

    if (identityStatus === "verified") {
      updatePayload.identity_verified_at = new Date().toISOString();
    }

    const { error: saveError } = await supabase
      .from("profiles")
      .update(updatePayload)
      .eq("id", user.id);

    if (saveError) {
      throw new Error(saveError.message);
    }

    stage = "success";

    return new Response(
      JSON.stringify({
        ok: true,
        stage,
        dwollaCustomerId,
        dwollaCustomerStatus: dwollaStatus,
        identityStatus,
      }),
      {
        status: 200,
        headers: corsHeaders,
      }
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({
        error: err?.message ?? "Unknown error",
        stage,
      }),
      {
        status: 500,
        headers: corsHeaders,
      }
    );
  }
});