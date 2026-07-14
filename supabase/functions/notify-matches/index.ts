// KonektaYa · Edge Function `notify-matches`
// Cuando alguien publica una oferta o una búsqueda, este servicio recalcula el
// match con la MISMA fórmula del scorer (el navegador NO decide destinatarios) y
// envía un email por Resend a los dueños de la contraparte que hacen match, sin
// revelar el contacto (eso sigue siendo de pago). Dedupe por (publicación,
// destinatario) para no reenviar el mismo aviso. service_role lo inyecta Supabase.

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

const MAX_EMAILS = 50; // tope por publicación para evitar abuso / costo

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

// -------- Helpers de matching (portados de `unlock`) --------
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

// -------- Email (Resend) --------
function matchEmailHtml(vertical: string, recipientIsSearcher: boolean, name: string) {
  const cosa = vertical === "vehiculo" ? "vehículo" : "inmueble";
  const linea = recipientIsSearcher
    ? `Se publicó un <strong>${cosa}</strong> que coincide con lo que estás buscando.`
    : `Alguien está buscando un <strong>${cosa}</strong> que coincide con lo que ofreces.`;
  const hola = name ? `Hola ${name},` : "Hola,";
  return `<!doctype html><html><body style="margin:0;background:#eef3fa;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#0f2a4a">
  <div style="max-width:520px;margin:0 auto;padding:24px">
    <div style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 10px 30px rgba(15,42,74,.08)">
      <div style="background:linear-gradient(135deg,#0a2f55,#0f2a4a);color:#fff;padding:26px 24px">
        <div style="font-size:22px;font-weight:800">🎯 Tienes una nueva oportunidad</div>
        <div style="color:#bcd4ee;font-size:14px;margin-top:4px">KonektaYa · Panamá</div>
      </div>
      <div style="padding:24px">
        <p style="font-size:15px;line-height:1.6;margin:0 0 12px">${hola}</p>
        <p style="font-size:15px;line-height:1.6;margin:0 0 18px">${linea}</p>
        <a href="https://konektaya.com" style="display:inline-block;background:#e05b2a;color:#fff;text-decoration:none;font-weight:800;padding:13px 22px;border-radius:12px;font-size:15px">Ver en Mi panel</a>
        <p style="font-size:13px;color:#64748b;line-height:1.6;margin:18px 0 0">Entra a tu panel para revisar el match. El contacto se revela al desbloquear la oportunidad.</p>
      </div>
    </div>
    <p style="font-size:12px;color:#94a3b8;text-align:center;margin:16px 0 0">Recibiste este correo porque tienes una publicación activa en KonektaYa.</p>
  </div></body></html>`;
}

async function sendResendEmail(to: string, vertical: string, recipientIsSearcher: boolean, name: string) {
  // La API key debe ir en el header sin caracteres invisibles (espacios, saltos
  // de línea, comillas raras que se cuelan al pegar) o fetch falla con "not a
  // valid ByteString". Dejamos solo ASCII imprimible sin espacios.
  const key = (Deno.env.get("RESEND_API_KEY") || "").replace(/[^\x21-\x7E]/g, "");
  if (!key) throw new Error("RESEND_API_KEY no configurado");
  const from = (Deno.env.get("NOTIFY_FROM") || "KonektaYa <avisos@konektaya.com>").replace(/[^\x20-\x7E]/g, "");
  const cosa = vertical === "vehiculo" ? "vehículo" : "inmueble";
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify({
      from,
      to: [to],
      subject: `🎯 Nueva oportunidad de ${cosa} en KonektaYa`,
      html: matchEmailHtml(vertical, recipientIsSearcher, name),
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

    // Publicante bloqueado por el admin → no se avisa (su publicación no matchea).
    const { data: me } = await admin.from("profiles").select("blocked").eq("id", user.id).maybeSingle();
    if (me?.blocked) return json({ ok: true, notified: 0, skipped: "blocked" });

    const body = await req.json();
    const vertical = body.vertical === "vehiculo" ? "vehiculo" : "inmueble";
    const kind = body.kind === "search" ? "search" : "offer";
    const id = body.id;
    if (!id) return json({ error: "Falta id" }, 400);

    const offerTable = vertical === "vehiculo" ? "vehicle_offers" : "properties";
    const searchTable = vertical === "vehiculo" ? "vehicle_searches" : "searches";
    const newTable = kind === "offer" ? offerTable : searchTable;
    const counterTable = kind === "offer" ? searchTable : offerTable;

    // Publicación nueva (debe ser del usuario que llama).
    const { data: fresh } = await admin.from(newTable).select("id,owner_id,data,active").eq("id", id).maybeSingle();
    if (!fresh) return json({ error: "Publicación no encontrada" }, 404);
    if (fresh.owner_id !== user.id) return json({ error: "Solo el dueño puede disparar avisos" }, 403);
    if (fresh.active === false) return json({ ok: true, notified: 0, skipped: "inactive" });

    // Solo avisamos al PROPIETARIO (dueño de la oferta/propiedad): cuando entra una
    // BÚSQUEDA nueva que coincide con su publicación. Al publicar una oferta, el
    // propietario ya ve sus resultados en vivo, así que ahí no mandamos correos.
    if (kind !== "search") return json({ ok: true, notified: 0, skipped: "solo-propietario" });

    // Config global (fallback a defaults).
    let config: any = DEFAULT_CONFIG;
    const { data: cfgRow } = await admin.from("match_config").select("config").eq("id", 1).maybeSingle();
    if (cfgRow?.config?.inmuebles) config = cfgRow.config;
    const c = vertical === "vehiculo" ? config.vehiculos : config.inmuebles;
    const umbral = Number(c.umbral) || 70;
    const calc = vertical === "vehiculo" ? calcVehiculoScore : calcInmuebleScore;

    // Contrapartes activas de OTROS usuarios.
    const { data: counterparts, error: cpErr } = await admin
      .from(counterTable).select("id,owner_id,data")
      .eq("active", true).neq("owner_id", user.id).limit(2000);
    console.log("notify-matches:start", { vertical, kind, id, umbral, counterparts: (counterparts || []).length, cpErr: cpErr?.message });

    // Mejor score por destinatario (un usuario puede tener varias publicaciones).
    const best = new Map<string, number>();
    const count = new Map<string, number>();
    for (const cp of (counterparts || [])) {
      const score = kind === "offer"
        ? calc(fresh.data, cp.data, c)     // nueva oferta vs búsqueda existente
        : calc(cp.data, fresh.data, c);    // oferta existente vs nueva búsqueda
      if (score < umbral) continue;
      const rid = cp.owner_id;
      best.set(rid, Math.max(best.get(rid) || 0, score));
      count.set(rid, (count.get(rid) || 0) + 1);
    }
    const recipientIds = [...best.keys()];
    console.log("notify-matches:scored", { recipients: recipientIds.length, bestScores: [...best.values()] });
    if (!recipientIds.length) return json({ ok: true, notified: 0 });

    // Perfiles: email, nombre, bloqueo y preferencia de avisos.
    const { data: profs } = await admin
      .from("profiles").select("id,email,name,blocked,notify_matches").in("id", recipientIds);
    const profById = new Map((profs || []).map((p: any) => [p.id, p]));

    const recipientIsSearcher = kind === "offer"; // si publiqué una oferta, la contraparte busca
    let notified = 0;
    for (const rid of recipientIds) {
      if (notified >= MAX_EMAILS) break;
      const p: any = profById.get(rid);
      if (!p || !p.email) continue;
      if (p.blocked) continue;
      if (p.notify_matches === false) continue;

      // Dedupe atómico: si ya existe el aviso (publicación+destinatario), no reenvía.
      const { data: inserted, error: insErr } = await admin
        .from("match_notifications")
        .upsert(
          { publication_id: String(id), recipient_id: rid, vertical, kind,
            best_score: Math.round(best.get(rid) || 0), matched_count: count.get(rid) || 1 },
          { onConflict: "publication_id,recipient_id", ignoreDuplicates: true }
        )
        .select("id");
      if (insErr) { console.warn("match_notifications insert", insErr.message); continue; }
      if (!inserted || !inserted.length) continue; // ya se había avisado

      try {
        await sendResendEmail(p.email, vertical, recipientIsSearcher, String(p.name || "").split(/\s+/)[0] || "");
        notified++;
        console.log("notify-matches:sent", { to: p.email });
      } catch (e) {
        // Falló el envío: borramos el registro para permitir reintento en la próxima publicación.
        await admin.from("match_notifications").delete().eq("publication_id", String(id)).eq("recipient_id", rid);
        console.warn("sendResendEmail:error", { to: p.email, err: String((e as Error)?.message || e) });
      }
    }

    console.log("notify-matches:done", { notified, candidates: recipientIds.length });
    return json({ ok: true, notified, candidates: recipientIds.length });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
