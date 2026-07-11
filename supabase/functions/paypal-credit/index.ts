// KonektaYa · Edge Function `paypal-credit`
// Crea y captura órdenes de PayPal y acredita el saldo SOLO cuando PayPal
// confirma el pago (verificado en el servidor con el Secret). Idempotente.
//
// Secrets requeridos (Supabase → Edge Functions → Secrets):
//   PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_ENV (sandbox|live)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(o: unknown, s = 200) {
  return new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
}

function paypalBase() {
  return (Deno.env.get("PAYPAL_ENV") || "sandbox") === "live"
    ? "https://api-m.paypal.com"
    : "https://api-m.sandbox.paypal.com";
}

async function paypalToken() {
  const id = Deno.env.get("PAYPAL_CLIENT_ID")!;
  const secret = Deno.env.get("PAYPAL_SECRET")!;
  const r = await fetch(`${paypalBase()}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: "Basic " + btoa(`${id}:${secret}`),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  const d = await r.json();
  if (!d.access_token) throw new Error("PayPal auth falló");
  return d.access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const authHeader = req.headers.get("Authorization") || "";

    const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: ud } = await userClient.auth.getUser();
    const user = ud?.user;
    if (!user) return json({ error: "No autenticado" }, 401);

    const admin = createClient(url, service);
    const body = await req.json();
    const action = body.action;
    const token = await paypalToken();

    if (action === "create") {
      let amount = Number(body.amount) || 0;
      amount = Math.min(2000, Math.max(1, Math.round(amount * 100) / 100));
      const r = await fetch(`${paypalBase()}/v2/checkout/orders`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          intent: "CAPTURE",
          purchase_units: [{ amount: { currency_code: "USD", value: amount.toFixed(2) } }],
        }),
      });
      const d = await r.json();
      if (!d.id) return json({ error: "No se pudo crear la orden", detail: d }, 400);
      return json({ id: d.id });
    }

    if (action === "capture") {
      const orderID = String(body.orderID || "");
      if (!orderID) return json({ error: "Falta orderID" }, 400);

      // Idempotencia: si esta orden ya se acreditó, no volver a acreditar.
      const { data: prev } = await admin.from("paypal_orders").select("order_id").eq("order_id", orderID).maybeSingle();
      if (prev) {
        const { data: w } = await admin.from("wallets").select("balance").eq("user_id", user.id).maybeSingle();
        return json({ ok: true, alreadyCredited: true, credited: 0, balance: Number(w?.balance || 0) });
      }

      const r = await fetch(`${paypalBase()}/v2/checkout/orders/${orderID}/capture`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      });
      const d = await r.json();
      const capture = d?.purchase_units?.[0]?.payments?.captures?.[0];
      if (d.status !== "COMPLETED" || !capture || capture.status !== "COMPLETED") {
        return json({ error: "El pago no está completo", detail: d }, 402);
      }
      const amount = Number(capture.amount?.value || 0);
      if (!(amount > 0)) return json({ error: "Monto inválido" }, 400);

      // Registrar la orden (idempotencia) y acreditar el saldo
      const ins = await admin.from("paypal_orders").insert({ order_id: orderID, user_id: user.id, amount });
      if (ins.error && !String(ins.error.message).includes("duplicate")) {
        return json({ error: "No se pudo registrar la orden", detail: ins.error.message }, 500);
      }
      if (ins.error) {
        // carrera: ya insertada por otra petición → no doble acreditar
        const { data: w } = await admin.from("wallets").select("balance").eq("user_id", user.id).maybeSingle();
        return json({ ok: true, alreadyCredited: true, credited: 0, balance: Number(w?.balance || 0) });
      }
      const { data: w } = await admin.from("wallets").select("balance").eq("user_id", user.id).maybeSingle();
      const newBal = Number(w?.balance || 0) + amount;
      await admin.from("wallets").upsert({ user_id: user.id, balance: newBal, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
      return json({ ok: true, credited: amount, balance: newBal });
    }

    return json({ error: "Acción no soportada" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
