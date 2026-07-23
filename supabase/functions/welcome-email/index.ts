// KonektaYa · Edge Function `welcome-email`
// Envía el correo de bienvenida UNA sola vez por cuenta (Google o email+código).
// La app lo invoca en cada login; aquí se decide: reclamo atómico de
// profiles.welcomed_at (update ... where welcomed_at is null) ANTES de enviar,
// así dos llamadas simultáneas no duplican el correo. Si Resend falla se
// revierte la marca para que el próximo login lo reintente.
// Requiere: columna welcomed_at (supabase/2t-welcome.sql) + secret RESEND_API_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

// El nombre viene del usuario: SIEMPRE escapado antes de entrar al HTML.
function escapeHtml(v: unknown) {
  return String(v == null ? "" : v)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function welcomeHtml(nameSafe: string) {
  const saludo = nameSafe ? `¡Bienvenido, ${nameSafe}! 🎉` : "¡Bienvenido! 🎉";
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f7fb;margin:0;padding:24px 0;font-family:Arial,Helvetica,sans-serif;">
  <tr><td align="center">
    <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="width:480px;max-width:92%;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 10px 30px rgba(15,42,74,0.10);">
      <tr><td style="background:#0a2f55;padding:22px 32px;">
        <img src="https://www.konektaya.com/logo-email.png" width="40" height="40" alt="" style="vertical-align:middle;border-radius:10px;margin-right:12px;" />
        <span style="font-size:24px;font-weight:800;color:#ffffff;letter-spacing:-0.5px;vertical-align:middle;">Konekta<span style="color:#f2833f;">Ya</span></span>
      </td></tr>
      <tr><td style="padding:34px 32px 8px;">
        <h1 style="margin:0 0 14px;font-size:22px;color:#0f2a4a;">${saludo}</h1>
        <p style="margin:0 0 20px;font-size:15px;line-height:1.6;color:#334155;">
          Tu cuenta en <strong>KonektaYa</strong> está lista. Somos el punto de encuentro de propiedades y vehículos en Panamá: tú publicas o buscas, y nuestro matching de IA hace el resto.
        </p>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 22px;">
          <tr><td style="background:#f4f7fb;border-radius:12px;padding:14px 16px;">
            <p style="margin:0 0 10px;font-size:14px;line-height:1.55;color:#334155;">🏠 <strong>Publica gratis</strong> tu propiedad o vehículo — sin comisión.</p>
            <p style="margin:0 0 10px;font-size:14px;line-height:1.55;color:#334155;">🔎 <strong>Registra tu búsqueda</strong> y el matching de IA te cruza con lo que ya está publicado.</p>
            <p style="margin:0;font-size:14px;line-height:1.55;color:#334155;">🤝 <strong>Conecta directo</strong>: cuando hay interés real, desbloqueas el contacto y cierran entre ustedes.</p>
          </td></tr>
        </table>
        <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 24px;">
          <tr><td align="center" bgcolor="#e05b2a" style="border-radius:12px;">
            <a href="https://www.konektaya.com" target="_blank" style="display:inline-block;padding:14px 30px;font-size:15px;font-weight:800;color:#ffffff;text-decoration:none;border-radius:12px;">Ir a KonektaYa</a>
          </td></tr>
        </table>
        <p style="margin:0 0 24px;font-size:13px;line-height:1.6;color:#64748b;">
          ¿Dudas? Escríbenos por WhatsApp al <a href="https://wa.me/50764905233" style="color:#b4530f;">+507 6490-5233</a> — respondemos personas, no robots.
        </p>
      </td></tr>
      <tr><td style="border-top:1px solid #eef2f7;padding:20px 32px;">
        <p style="margin:0;font-size:12px;line-height:1.6;color:#94a3b8;">KonektaYa · Conectamos oferta y necesidad de propiedades y vehículos en Panamá.<br>Recibes este correo porque creaste una cuenta en konektaya.com. Este es un correo automático, por favor no respondas.</p>
      </td></tr>
    </table>
  </td></tr>
</table>`;
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
    if (!user || !user.email) return json({ error: "No autenticado" }, 401);

    const admin = createClient(url, service);

    // Reclamo atómico: marca welcomed_at SOLO si aún es null. Si otra llamada
    // simultánea ganó (0 filas), salimos sin enviar — cero duplicados.
    const { data: claimed, error: claimErr } = await admin
      .from("profiles")
      .update({ welcomed_at: new Date().toISOString() })
      .eq("id", user.id)
      .is("welcomed_at", null)
      .select("id, name")
      .maybeSingle();
    if (claimErr) return json({ error: claimErr.message }, 500);
    if (!claimed) return json({ ok: true, already: true });

    const rawName = String(claimed.name || user.user_metadata?.name || "").trim();
    const first = rawName.split(/\s+/)[0] || "";
    const nameSafe = escapeHtml(first);

    // Envío por Resend (mismo saneo de la key que notify-matches).
    const key = (Deno.env.get("RESEND_API_KEY") || "").replace(/[^\x21-\x7E]/g, "");
    const from = (Deno.env.get("NOTIFY_FROM") || "KonektaYa <avisos@konektaya.com>").replace(/[^\x20-\x7E]/g, "");
    let sendError = "";
    if (!key) {
      sendError = "RESEND_API_KEY no configurado";
    } else {
      try {
        const res = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { "Authorization": "Bearer " + key, "Content-Type": "application/json" },
          body: JSON.stringify({
            from,
            to: [user.email],
            subject: nameSafe ? `🎉 ¡Bienvenido a KonektaYa, ${first}!` : "🎉 ¡Bienvenido a KonektaYa!",
            html: welcomeHtml(nameSafe),
          }),
        });
        if (!res.ok) sendError = "Resend " + res.status + ": " + (await res.text());
      } catch (e) {
        sendError = String(e?.message || e);
      }
    }

    if (sendError) {
      // Revertir la marca: el próximo login reintenta. (Riesgo teórico de doble
      // envío en una carrera de reintentos; preferible a no enviar nunca.)
      await admin.from("profiles").update({ welcomed_at: null }).eq("id", user.id);
      return json({ error: sendError }, 500);
    }

    return json({ ok: true, sent: true });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
