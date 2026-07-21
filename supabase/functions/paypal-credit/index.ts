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

// ITBMS (Panamá) sobre las recargas: se cobra base + 7%; la billetera recibe la base.
const ITBMS_PCT = 7;

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

    // Kill switch global (app_config.payments_enabled): si los pagos están apagados,
    // no se crea ni se captura NINGUNA orden. Fail closed: sin tabla/fila => apagado.
    const { data: appCfg } = await admin.from("app_config").select("payments_enabled").eq("id", 1).maybeSingle();
    if (!appCfg || appCfg.payments_enabled !== true) {
      return json({ error: "Los pagos están desactivados por el momento." }, 403);
    }

    const body = await req.json();
    const action = body.action;
    const token = await paypalToken();

    if (action === "create") {
      // body.amount = BASE del crédito. Se cobra base + ITBMS 7% (Panamá); el
      // crédito acreditado será la base. El total lo calcula el SERVIDOR.
      let amount = Number(body.amount) || 0;
      amount = Math.min(2000, Math.max(1, Math.round(amount * 100) / 100));
      const total = Math.round(amount * (100 + ITBMS_PCT)) / 100;
      const r = await fetch(`${paypalBase()}/v2/checkout/orders`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          intent: "CAPTURE",
          purchase_units: [{ amount: { currency_code: "USD", value: total.toFixed(2) } }],
        }),
      });
      const d = await r.json();
      if (!d.id) return json({ error: "No se pudo crear la orden", detail: d }, 400);
      // Ligar la orden al usuario que la creó (solo él podrá capturarla).
      await admin.from("paypal_orders").insert({ order_id: d.id, user_id: user.id, amount: 0, status: "created" });
      return json({ id: d.id });
    }

    if (action === "capture") {
      const orderID = String(body.orderID || "");
      if (!orderID) return json({ error: "Falta orderID" }, 400);

      // La orden debe existir y pertenecer al usuario que la creó.
      const { data: order } = await admin.from("paypal_orders").select("order_id,user_id,status").eq("order_id", orderID).maybeSingle();
      if (!order) return json({ error: "Orden desconocida" }, 404);
      if (order.user_id !== user.id) return json({ error: "Esta orden no pertenece a tu cuenta" }, 403);
      if (order.status === "credited") {
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
      const paid = Number(capture.amount?.value || 0);
      if (!(paid > 0)) return json({ error: "Monto inválido" }, 400);

      // El pago incluye ITBMS 7%: base = pagado / 1.07 (es lo que entra a la billetera).
      const base = Math.round((paid / (1 + ITBMS_PCT / 100)) * 100) / 100;
      if (!(base > 0)) return json({ error: "Monto inválido" }, 400);

      // Bono por paquete de broker. Se decide EN EL SERVIDOR (no se confía en el cliente
      // para el monto): el flag body.pkg solo OPTA al bono, y el % sale de esta tabla
      // según la BASE realmente pagada (sin ITBMS). Debe coincidir con brokerPackages
      // del cliente (Starter 50/+10%, Pro 150/+20%, Elite 400/+30%).
      const PKG_BONUS: Record<number, number> = { 50: 10, 150: 20, 400: 30 };
      const pct = (body.pkg === true && PKG_BONUS[Math.round(base)] != null) ? PKG_BONUS[Math.round(base)] : 0;
      const credited = pct ? Math.round(base * (1 + pct / 100)) : base;

      // Marcar como acreditada SOLO si seguía en 'created' (gana una sola petición).
      // paypal_orders.amount = lo que PAGÓ (para el recibo); la wallet recibe `credited` (con bono).
      const { data: claimed } = await admin
        .from("paypal_orders")
        .update({ amount: paid, status: "credited" })
        .eq("order_id", orderID)
        .eq("status", "created")
        .select("order_id");
      if (!claimed || !claimed.length) {
        const { data: w } = await admin.from("wallets").select("balance").eq("user_id", user.id).maybeSingle();
        return json({ ok: true, alreadyCredited: true, credited: 0, balance: Number(w?.balance || 0) });
      }
      // Crédito ATÓMICO en Postgres. Si falla, REVERTIMOS el estado a 'created'
      // para poder reintentar: si no, la orden quedaría marcada 'credited' pero
      // sin sumar el saldo (dinero cobrado y no acreditado, sin reintento posible).
      const { data: newBal, error: credErr } = await admin.rpc("wallet_credit", { p_user: user.id, p_amount: credited });
      if (credErr) {
        await admin.from("paypal_orders").update({ status: "created" }).eq("order_id", orderID).eq("status", "credited");
        return json({ error: "No se pudo acreditar. Intenta de nuevo.", detail: credErr.message }, 500);
      }
      return json({ ok: true, credited, balance: Number(newBal || 0) });
    }

    return json({ error: "Acción no soportada" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
