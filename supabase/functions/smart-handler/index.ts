// supabase/functions/send-phone-code/index.ts
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function sevenDigit() {
  return String(Math.floor(1000000 + Math.random() * 9000000));
}

serve(async (req) => {
  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
    const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // identify the logged-in user from the incoming Authorization header
    const auth = req.headers.get("Authorization") || "";
    const userClient = createClient(SUPABASE_URL, ANON, {
      global: { headers: { Authorization: auth } },
    });
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });

    const { phone } = await req.json();
    if (!phone) return new Response(JSON.stringify({ error: "phone required" }), { status: 400 });

    const code = sevenDigit();

    // write attempt using service role (bypass RLS)
    const svc = createClient(SUPABASE_URL, SERVICE);
    const { error: insErr } = await svc.from("phone_verifications").insert({
      user_id: user.id,
      phone,
      code,
      expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
    });
    if (insErr) return new Response(JSON.stringify({ error: insErr.message }), { status: 500 });

    // DEV MODE: return the code so you can test without SMS
    return new Response(JSON.stringify({ ok: true, devCode: code }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: e?.message ?? String(e) }), { status: 500 });
  }
});