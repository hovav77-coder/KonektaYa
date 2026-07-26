// KonektaYa · Edge Function `unlock`
// Desbloqueo seguro: recalcula el precio con la MISMA fórmula del matching
// (el navegador no puede falsear el monto), aplica el tope por publicación,
// descuenta el saldo del servidor, registra el desbloqueo y devuelve el
// contacto del interesado. Todo con service_role (inyectado por Supabase).

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

// -------- Config por defecto (fallback si match_config está vacío) --------
const DEFAULT_CONFIG = {
  inmuebles: {
    umbral: 70, presupuestoMinPct: 75, metrajeMinPct: 80, metrajeMaxPct: 125,
    base: 30, puntosClienteFinal: 15, puntosBroker: 12, puntosBrokerAnonimo: 8,
    puntosCalle: 10, distanciaCalleM: 500, distanciaZonaM: 2000, puntosPh: 15, metrajeCercaPct: 10, puntosMetrajeCerca: 10, puntosMetrajeLejos: 6,
    puntosPrecioA: 15, puntosPrecioB: 11, puntosPrecioC: 8,
    puntosEquipamiento: 5, puntosEstacionamiento: 3, puntosDeposito: 2,
    pisoPh: 85, pisoPhEquipCliente: 95, pisoBroker: 75, pisoClienteFinal: 70,
    topeSinPh: 84, topeEquipDistinto: 94, topeBroker: 95, topeBrokerAnonimo: 85,
    topePublicacion: 100, cicloDias: 60, diasAvisoVencimiento: 5,
    precios: { AAA: 100, AA: 75, A: 50, BBB: 25, BB: 10, B: 5 },
  },
  vehiculos: {
    umbral: 70, presupuestoMinPct: 75, puntosTipo: 10, puntosMarca: 20,
    puntosModeloExacto: 15, puntosModeloSimilar: 8, puntosModeloIndiferente: 8,
    puntosPrecioA: 20, puntosPrecioB: 13, puntosPrecioC: 8,
    puntosAnio: 10, puntosAnioParcial: 5, anioTolerancia: 3,
    puntosKmA: 15, puntosKmB: 10, puntosTransmision: 5, puntosCombustible: 5,
    topeSinMarca: 65, topeModeloSimilar: 79, topeModeloNinguno: 65, topeSinPrecio: 65, topeBroker: 95,
    topePublicacion: 25, cicloDias: 60, diasAvisoVencimiento: 5,
    precios: { AAA: 20, AA: 15, A: 10, BBB: 5, BB: 3, B: 1 },
  },
};

// -------- Helpers de matching (portados de la app) --------
const DIACRITICS = /[̀-ͯ]/g;
const norm = (v: unknown) =>
  String(v == null ? "" : v).trim().toLowerCase().normalize("NFD").replace(DIACRITICS, "");

const propSupportsOp = (p: any, op: string) => p.operation === "ambos" || p.operation === op;
const propPriceForOp = (p: any, op: string) =>
  op === "alquiler" ? Number(p.rentalPrice || 0) : op === "venta" ? Number(p.salePrice || 0) : 0;
const hasDesiredPh = (s: any) => Boolean(String(s?.desiredPh || "").trim());
const normalizePh = (v: unknown) =>
  norm(v).replace(/\b(ph|p\s*h|p\.h\.|edificio|torre|residencial)\b/g, "").replace(/[^a-z0-9]/g, "");
function isSamePh(p: any, s: any) {
  if (!hasDesiredPh(s)) return false;
  const a = normalizePh(p.phName || ""), b = normalizePh(s.desiredPh || "");
  if (!a || !b) return false;
  return a === b || a.includes(b) || b.includes(a);
}
function interestedQuality(s: any, c: any) {
  if (s.role === "cliente final") return c.puntosClienteFinal;
  if (s.finalClientPrivacy === "anonymous") return c.puntosBrokerAnonimo;
  return c.puntosBroker;
}

function haversineMeters(lat1: number, lng1: number, lat2: number, lng2: number) {
  const R = 6371000, rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad, dLng = (lng2 - lng1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// Coincidencia de calle/barriada (2F): texto igual, mismo place_id o distancia.
function streetsMatchSrv(p: any, s: any, c: any) {
  const a = norm(p.streetOrNeighborhood || "");
  const b = norm(s.desiredStreetOrNeighborhood || "");
  if (a && a === b) return true;
  if (p.streetPlaceId && s.desiredStreetPlaceId && String(p.streetPlaceId) === String(s.desiredStreetPlaceId)) return true;
  const lat1 = Number(p.streetLat), lng1 = Number(p.streetLng);
  const lat2 = Number(s.desiredStreetLat), lng2 = Number(s.desiredStreetLng);
  if ((lat1 || lng1) && (lat2 || lng2) && isFinite(lat1) && isFinite(lng1) && isFinite(lat2) && isFinite(lng2)) {
    return haversineMeters(lat1, lng1, lat2, lng2) <= (Number(c.distanciaCalleM) || 500);
  }
  return false;
}

// "Misma zona" por ubicacion real (reemplaza el filtro de zona por texto).
function locationWithinZoneSrv(property: any, search: any, c: any) {
  if (isSamePh(property, search) || streetsMatchSrv(property, search, c)) return true;
  const pLat = Number(property.streetLat), pLng = Number(property.streetLng);
  const sLat = Number(search.desiredStreetLat), sLng = Number(search.desiredStreetLng);
  const bothGeo = isFinite(pLat) && isFinite(pLng) && (pLat || pLng) && isFinite(sLat) && isFinite(sLng) && (sLat || sLng);
  if (bothGeo) return haversineMeters(pLat, pLng, sLat, sLng) <= (Number(c.distanciaZonaM) || 2000);
  const pz = norm(property.zone), sz = norm(search.desiredZone);
  if (pz && sz) return pz === sz;
  return true;
}

function calcInmuebleScore(property: any, search: any, c: any) {
  if (!propSupportsOp(property, search.desiredOperation)) return 0;
  const matchPrice = propPriceForOp(property, search.desiredOperation);
  if (matchPrice <= 0) return 0;
  if (property.propertyType !== search.propertyType) return 0;
  if (!locationWithinZoneSrv(property, search, c)) return 0;
  const budget = Number(search.maxBudget || 0);
  if (!budget || matchPrice > budget * (100 / c.presupuestoMinPct)) return 0;
  const minSize = Number(search.minSizeM2 || 0);
  const size = Number(property.sizeM2 || 0);
  if (minSize && (size < minSize * (c.metrajeMinPct / 100) || size > minSize * (c.metrajeMaxPct / 100))) return 0;

  const samePh = isSamePh(property, search);
  const sameStreet = samePh || streetsMatchSrv(property, search, c);
  const desiredEquip = String(search.desiredEquipment || "").trim();
  const equipSpecified = Boolean(desiredEquip) && desiredEquip !== "indiferente";
  const equipMatches = equipSpecified && property.equipment === search.desiredEquipment;
  const desiredParking = Number(search.desiredParkingSpaces || 0);
  const parkingMatches = desiredParking > 0 && Number(property.parkingSpaces || 0) >= desiredParking;
  const storageWanted = search.desiredStorage === "si";
  const storageMatches = storageWanted && property.storage === "si";
  const equipSat = !equipSpecified || equipMatches;
  const parkingSat = desiredParking <= 0 || parkingMatches;
  const storageSat = !storageWanted || storageMatches;
  const near = 1 - c.metrajeCercaPct / 100, far = 1 + c.metrajeCercaPct / 100;
  const sizeNear = !minSize || (size >= minSize * near && size <= minSize * far);

  let score = c.base + interestedQuality(search, c);
  if (sameStreet) score += c.puntosCalle;
  if (samePh) score += c.puntosPh;
  score += sizeNear ? c.puntosMetrajeCerca : c.puntosMetrajeLejos;
  score += matchPrice <= budget * 1.1 ? c.puntosPrecioA : matchPrice <= budget * 1.2 ? c.puntosPrecioB : c.puntosPrecioC;
  if (equipSat) score += c.puntosEquipamiento;
  if (parkingSat) score += c.puntosEstacionamiento;
  if (storageSat) score += c.puntosDeposito;

  if (samePh) score = Math.max(score, c.pisoPh);
  if (samePh && equipMatches && search.role === "cliente final") score = Math.max(score, c.pisoPhEquipCliente);
  if (search.role === "broker") score = Math.max(score, c.pisoBroker);
  if (search.role === "cliente final") score = Math.max(score, c.pisoClienteFinal);

  if (matchPrice > budget * 1.1 || !sizeNear) score = Math.min(score, 99);
  if (!samePh) score = Math.min(score, c.topeSinPh);
  if (equipSpecified && !equipMatches) score = Math.min(score, c.topeEquipDistinto);
  if (search.role === "broker") score = Math.min(score, search.finalClientPrivacy === "anonymous" ? c.topeBrokerAnonimo : c.topeBroker);
  return Math.min(score, 100);
}

const modelCompat = (offerModel: string, desiredModel: string) => {
  const o = norm(offerModel), d = norm(desiredModel);
  if (!o || !d) return 0;
  if (o === d) return 15;
  if (d.includes(o) || o.includes(d)) return 7;
  const words = d.split(/\s+/).filter((w) => w.length > 2 && !["similar", "parecido"].includes(w));
  return words.some((w) => o.includes(w)) ? 7 : 0;
};
const vehPrice = (offer: any) => Number(offer.salePrice || offer.rentalPrice || 0);

function calcVehiculoScore(offer: any, search: any, c: any) {
  let score = 0;
  const factors: any = {};
  factors.type = norm(offer.vehicleType || "") === norm(search.vehicleType || "");
  if (factors.type) score += c.puntosTipo;
  factors.brand = norm(offer.brand) === norm(search.desiredBrand);
  if (factors.brand) score += c.puntosMarca;
  const modelIndiff = !search.desiredModel || norm(search.desiredModel) === "indiferente";
  const ms = modelIndiff ? 0 : modelCompat(offer.model, search.desiredModel);
  factors.model = modelIndiff ? "indiferente" : ms === 15 ? "exact" : ms > 0 ? "similar" : "none";
  if (factors.model === "exact") score += c.puntosModeloExacto;
  else if (factors.model === "similar") score += c.puntosModeloSimilar;
  else if (factors.model === "indiferente") score += c.puntosModeloIndiferente;
  const price = vehPrice(offer), budget = Number(search.maxBudget || 0);
  const limit = 100 / c.presupuestoMinPct;
  if (price > 0 && budget > 0 && price <= budget * 1.1) { factors.price = true; score += c.puntosPrecioA; }
  else if (price > 0 && budget > 0 && price <= budget * 1.2) { factors.price = true; score += c.puntosPrecioB; }
  else if (price > 0 && budget > 0 && price <= budget * limit) { factors.price = true; score += c.puntosPrecioC; }
  else factors.price = false;
  const oy = Number(offer.year || 0), my = Number(search.minYear || 0);
  if (oy >= my) score += c.puntosAnio;
  else if (oy >= my - c.anioTolerancia) score += c.puntosAnioParcial;
  const mileage = Number(offer.mileage || 0), maxM = Number(search.maxMileage || 0) || Infinity;
  if (mileage <= maxM * 1.1) score += c.puntosKmA;
  else if (mileage <= maxM * 1.2) score += c.puntosKmB;
  if (search.transmission === "indiferente" || offer.transmission === search.transmission) score += c.puntosTransmision;
  if (search.fuel === "indiferente" || offer.fuel === search.fuel) score += c.puntosCombustible;
  if (!factors.brand) score = Math.min(score, c.topeSinMarca);
  if (factors.model === "similar") score = Math.min(score, c.topeModeloSimilar);
  if (factors.model === "none") score = Math.min(score, c.topeModeloNinguno);
  if (!factors.price) score = Math.min(score, c.topeSinPrecio);
  if (search.role === "broker") score = Math.min(score, c.topeBroker);
  return Math.min(100, score);
}

function priceFromScore(score: number, c: any) {
  const p = c.precios;
  if (score >= 100) return p.AAA;
  if (score >= 95) return p.AA;
  if (score >= 90) return p.A;
  if (score >= 85) return p.BBB;
  if (score >= 80) return p.BB;
  if (score >= c.umbral) return p.B;
  return 0;
}

// -------- Aviso por email al buscador (revelado mutuo) via Resend --------
// Los datos del que pagó van ENMASCARADOS en el email (el correo es un canal
// inseguro: se reenvía/almacena fuera de la app). El contacto completo se ve
// solo dentro de Mi panel, detrás del login (bloque "Ya conectados").
function maskName(name: string) {
  const words = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (!words.length) return "";
  return words.map((w) => w.slice(0, 2) + "•".repeat(Math.min(5, Math.max(2, w.length - 2)))).join(" ");
}
function maskPhone(phone: string) {
  const digits = String(phone || "").replace(/\D/g, "");
  if (!digits) return "";
  if (digits.length <= 4) return "••••";
  return digits.slice(0, 3) + "•".repeat(Math.max(2, digits.length - 5)) + digits.slice(-2);
}
function maskEmail(email: string) {
  const e = String(email || "").trim();
  const at = e.indexOf("@");
  if (at <= 0) return e ? "•••" : "";
  const local = e[0] + "•".repeat(Math.min(6, Math.max(3, at - 1)));
  // Ocultar también el dominio (no revelar la empresa, ej. @imrsa.com). Se deja
  // la 1a letra + el TLD para que siga leyéndose como un email: "h••••@i••••.com".
  const domain = e.slice(at + 1);
  const dot = domain.lastIndexOf(".");
  const domMask = dot > 0
    ? domain[0] + "•".repeat(Math.min(5, Math.max(2, dot - 1))) + domain.slice(dot)
    : (domain[0] || "") + "•••";
  return local + "@" + domMask;
}
function unlockNoticeHtml(searcherName: string, ownerName: string, ownerPhone: string, ownerEmail: string, vertical: string) {
  // Escapar TODO dato de usuario: el dueño controla su nombre/teléfono sin sanear
  // y este correo sale desde el dominio de confianza → sin esto podría inyectar
  // HTML/enlaces de phishing en el cuerpo del email al buscador.
  const esc = (s: string) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
  const cosa = vertical === "vehiculo" ? "vehículo" : "inmueble";
  const hola = searcherName ? `Hola ${esc(searcherName)},` : "Hola,";
  const oName = esc(maskName(ownerName)) || "Un interesado";
  const telMask = maskPhone(ownerPhone);
  const mailMask = maskEmail(ownerEmail);
  const tel = telMask ? `<div style="font-size:14px;margin:3px 0"><strong>Tel:</strong> ${esc(telMask)}</div>` : "";
  const mail = mailMask ? `<div style="font-size:14px;margin:3px 0"><strong>Email:</strong> ${esc(mailMask)}</div>` : "";
  return `<!doctype html><html><body style="margin:0;background:#eef3fa;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#0f2a4a">
  <div style="max-width:520px;margin:0 auto;padding:24px">
    <div style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 10px 30px rgba(15,42,74,.08)">
      <div style="background:linear-gradient(135deg,#0a2f55,#0f2a4a);color:#fff;padding:26px 24px">
        <div style="font-size:21px;font-weight:800">🔓 Un interesado desbloqueó tu contacto</div>
        <div style="color:#bcd4ee;font-size:14px;margin-top:4px">KonektaYa · Panamá</div>
      </div>
      <div style="padding:24px">
        <p style="font-size:15px;line-height:1.6;margin:0 0 12px">${hola}</p>
        <p style="font-size:15px;line-height:1.6;margin:0 0 16px">Alguien interesado en tu búsqueda de <strong>${cosa}</strong> pagó por ver tus datos y ya puede escribirte:</p>
        <div style="background:#f8fbff;border:1px solid #e6edf5;border-radius:12px;padding:14px 16px;margin:0 0 18px">
          <div style="font-size:16px;font-weight:800;color:#0a2f55">${oName}</div>
          ${tel}${mail}
          <div style="font-size:12.5px;color:#64748b;margin-top:8px">🔒 Por tu seguridad, el contacto completo se muestra solo dentro de tu panel.</div>
        </div>
        <a href="https://konektaya.com" style="display:inline-block;background:#e05b2a;color:#fff;text-decoration:none;font-weight:800;padding:13px 22px;border-radius:12px;font-size:15px">Ver su contacto en Mi panel</a>
        <p style="font-size:13px;color:#64748b;line-height:1.6;margin:18px 0 0">¿No quieres más contactos? Entra a tu panel y <strong>pausa tu búsqueda</strong>: dejarás de aparecer y nadie podrá desbloquear tu contacto.</p>
      </div>
    </div>
    <p style="font-size:12px;color:#94a3b8;text-align:center;margin:16px 0 0">Recibiste este correo porque tienes una búsqueda activa en KonektaYa.</p>
  </div></body></html>`;
}

async function sendUnlockNotice(to: string, searcherName: string, ownerName: string, ownerPhone: string, ownerEmail: string, vertical: string) {
  const key = (Deno.env.get("RESEND_API_KEY") || "").replace(/[^\x21-\x7E]/g, "");
  if (!key) throw new Error("RESEND_API_KEY no configurado");
  const from = (Deno.env.get("NOTIFY_FROM") || "KonektaYa <avisos@konektaya.com>").replace(/[^\x20-\x7E]/g, "");
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify({
      from,
      to: [to],
      subject: "🔓 Un interesado desbloqueó tu contacto en KonektaYa",
      html: unlockNoticeHtml(searcherName, ownerName, ownerPhone, ownerEmail, vertical),
    }),
  });
  if (!res.ok) throw new Error("Resend " + res.status + ": " + (await res.text()));
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

    // Usuario bloqueado por el admin no puede desbloquear contactos.
    const { data: me } = await admin.from("profiles").select("blocked").eq("id", user.id).maybeSingle();
    if (me?.blocked) return json({ error: "Tu cuenta está bloqueada. Contacta al administrador de KonektaYa." }, 403);

    const body = await req.json();
    const vertical = body.vertical === "vehiculo" ? "vehiculo" : "inmueble";
    const offerId = body.offerId, searchId = body.searchId;
    if (!offerId || !searchId) return json({ error: "Faltan offerId/searchId" }, 400);

    const offerTable = vertical === "vehiculo" ? "vehicle_offers" : "properties";
    const searchTable = vertical === "vehiculo" ? "vehicle_searches" : "searches";

    const [{ data: offer }, { data: search }] = await Promise.all([
      admin.from(offerTable).select("id,owner_id,data,cycle_start,active").eq("id", offerId).maybeSingle(),
      admin.from(searchTable).select("id,owner_id,data").eq("id", searchId).maybeSingle(),
    ]);
    if (!offer || !search) return json({ error: "Publicación no encontrada" }, 404);
    if (offer.owner_id !== user.id) return json({ error: "Solo el dueño de la publicación puede desbloquear" }, 403);
    // No auto-desbloqueo: no tiene sentido pagar por tu propio contacto (y el
    // motor del cliente ya no muestra auto-matches; esto es defensa en profundidad).
    if (offer.owner_id === search.owner_id) return json({ error: "No puedes desbloquear tu propia publicación." }, 400);

    // Config global (fallback a defaults)
    let config: any = DEFAULT_CONFIG;
    const { data: cfgRow } = await admin.from("match_config").select("config").eq("id", 1).maybeSingle();
    if (cfgRow?.config?.inmuebles) config = cfgRow.config;
    const c = vertical === "vehiculo" ? config.vehiculos : config.inmuebles;

    const score = vertical === "vehiculo"
      ? calcVehiculoScore(offer.data, search.data, c)
      : calcInmuebleScore(offer.data, search.data, c);
    const fullPrice = priceFromScore(score, c);
    if (!fullPrice) return json({ error: "Este match no califica para desbloqueo." }, 400);

    // ¿ya desbloqueado?
    const { data: existing } = await admin.from("unlocks").select("id,price")
      .eq("unlocker_id", user.id).eq("offer_id", offerId).eq("search_id", searchId).maybeSingle();

    // Publicación dada de baja o archivada: no se puede desbloquear (defensa en
    // servidor; antes esto solo lo validaba el cliente). Se revisa la columna
    // active Y data.archived (una publicación archivada por 2m conserva el flag).
    if (offer.active === false || (offer.data && offer.data.archived === true)) {
      return json({ error: "Esta publicación no está activa." }, 400);
    }
    // Tope por publicación en el ciclo actual. El inicio de ciclo sale de la
    // COLUMNA cycle_start (controlada por el servidor), NO de offer.data (editable
    // por el dueño → antes podía congelarse para desbloquear gratis para siempre).
    // Falla CERRADO: sin cycle_start no se desbloquea (la columna es NOT NULL + hay
    // trigger, pero si por cualquier motivo faltara, NO dejamos pasar gratis).
    if (!offer.cycle_start) {
      return json({ error: "Publicación sin ciclo válido; el dueño debe renovarla." }, 400);
    }
    const cap = Number(c.topePublicacion) || 0;
    let cicloDias = Number(c.cicloDias);
    if (!Number.isFinite(cicloDias) || cicloDias <= 0) cicloDias = 60;
    const cycleStart = offer.cycle_start;
    if (Date.now() > new Date(cycleStart).getTime() + cicloDias * 86400000) {
      return json({ error: "La publicación venció. El dueño debe renovarla para volver a recibir contactos." }, 400);
    }
    let alreadyPaid = 0;
    const { data: priors } = await admin.from("unlocks").select("price,created_at").eq("unlocker_id", user.id).eq("offer_id", offerId);
    (priors || []).forEach((p: any) => {
      if (new Date(p.created_at) >= new Date(cycleStart)) alreadyPaid += Number(p.price || 0);
    });
    let charge = cap ? Math.max(0, Math.min(fullPrice, cap - alreadyPaid)) : fullPrice;
    if (existing) charge = 0;

    // Cobro ATÓMICO en Postgres (wallet_debit falla con SALDO_INSUFICIENTE si no alcanza).
    let newBalance = 0;
    if (existing) {
      const { data: wallet } = await admin.from("wallets").select("balance").eq("user_id", user.id).maybeSingle();
      newBalance = Number(wallet?.balance || 0);
    } else {
      const { data: bal, error: debitErr } = await admin.rpc("wallet_debit", { p_user: user.id, p_amount: charge });
      if (debitErr) {
        if (String(debitErr.message).includes("SALDO_INSUFICIENTE")) {
          return json({ error: "Saldo insuficiente", need: charge }, 402);
        }
        return json({ error: "No se pudo cobrar", detail: debitErr.message }, 500);
      }
      newBalance = Number(bal || 0);
      const ins = await admin.from("unlocks").insert({
        unlocker_id: user.id, vertical, offer_id: offerId, search_id: searchId,
        counterpart_id: search.owner_id, price: charge,
      });
      if (ins.error) {
        // Carrera: otro request idéntico ganó el insert → devolver lo cobrado y tratar como ya-desbloqueado.
        if (charge > 0) {
          const { data: refunded } = await admin.rpc("wallet_credit", { p_user: user.id, p_amount: charge });
          newBalance = Number(refunded || newBalance + charge);
        }
        const { data: prof0 } = await admin.from("profiles").select("name,phone,email").eq("id", search.owner_id).maybeSingle();
        return json({ ok: true, alreadyUnlocked: true, score, charge: 0, balance: newBalance, contact: prof0 || null });
      }
    }

    const { data: prof } = await admin.from("profiles").select("name,phone,email,notify_matches").eq("id", search.owner_id).maybeSingle();

    // Aviso al BUSCADOR (transparencia + revelado mutuo): SOLO en desbloqueos nuevos
    // (no re-avisa si ya estaba desbloqueado), no bloquea la respuesta si el email
    // falla, y respeta la preferencia notify_matches del buscador.
    if (!existing && prof?.email && prof.notify_matches !== false) {
      try {
        const { data: ownerProf } = await admin.from("profiles").select("name,phone,email").eq("id", user.id).maybeSingle();
        await sendUnlockNotice(
          prof.email, String(prof.name || "").split(/\s+/)[0] || "",
          ownerProf?.name || "", ownerProf?.phone || "", ownerProf?.email || "", vertical
        );
      } catch (e) { console.warn("sendUnlockNotice", String((e as Error)?.message || e)); }
    }

    return json({ ok: true, alreadyUnlocked: Boolean(existing), score, charge: existing ? 0 : charge, balance: newBalance, contact: prof || null });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
