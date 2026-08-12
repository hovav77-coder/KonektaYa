#!/usr/bin/env node
/**
 * KonektaYa · Respaldo completo de la base de datos
 * ---------------------------------------------------------------
 * Baja TODAS las tablas + las cuentas de auth a archivos JSON con
 * fecha, en tu computadora. El plan gratuito de Supabase NO hace
 * copias de seguridad, así que esto es la única red que hay.
 *
 * USO:
 *   node scripts/backup.js
 *
 * ANTES DE LA PRIMERA VEZ — crea el archivo `.env.local` en la raíz
 * del proyecto con estas dos líneas (sin comillas):
 *
 *   SUPABASE_URL=https://agjzczxxawojicpxbiuu.supabase.co
 *   SUPABASE_SERVICE_ROLE_KEY=<la service_role key>
 *
 * La key se saca de Supabase → Project Settings → API Keys →
 * `service_role`. OJO: esa key salta TODAS las reglas de seguridad
 * (lee y escribe cualquier cosa). Por eso:
 *   - `.env.local` ya está en .gitignore: NUNCA se sube al repositorio.
 *   - No la pegues en chats, capturas ni correos.
 *   - Si alguna vez se filtra, se rota desde ese mismo panel.
 *
 * Los respaldos quedan en `backups/`, que también está ignorado por
 * git y excluido del despliegue: contienen nombres, teléfonos y
 * correos de personas reales y no pueden acabar publicados.
 */

const fs = require("fs");
const path = require("path");
const https = require("https");

const RAIZ = path.join(__dirname, "..");

// Tablas del esquema (supabase/*.sql). Las 4 de publicaciones se crean
// en un bucle en 2b-schema.sql, por eso no aparecen en un `create table`.
const TABLAS = [
  "properties", "searches", "vehicle_offers", "vehicle_searches",
  "profiles", "wallets", "unlocks", "paypal_orders",
  "coupons", "coupon_redemptions",
  "interest_requests", "contact_requests", "match_notifications",
  "match_config", "app_config",
];

const PAGINA = 1000; // tope de PostgREST: hay que paginar o se corta en silencio

function cargarEnv() {
  const env = { ...process.env };
  const archivo = path.join(RAIZ, ".env.local");
  if (fs.existsSync(archivo)) {
    fs.readFileSync(archivo, "utf8").split(/\r?\n/).forEach((linea) => {
      const l = linea.trim();
      if (!l || l.startsWith("#")) return;
      const i = l.indexOf("=");
      if (i > 0) env[l.slice(0, i).trim()] = l.slice(i + 1).trim().replace(/^["']|["']$/g, "");
    });
  }
  return env;
}

function pedir(url, headers) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      { host: u.host, path: u.pathname + u.search, method: "GET", headers, timeout: 60000 },
      (res) => {
        const trozos = [];
        res.on("data", (d) => trozos.push(d));
        res.on("end", () => {
          const cuerpo = Buffer.concat(trozos).toString("utf8");
          if (res.statusCode < 200 || res.statusCode >= 300) {
            return reject(new Error(`HTTP ${res.statusCode}: ${cuerpo.slice(0, 300)}`));
          }
          try { resolve(JSON.parse(cuerpo)); } catch (e) { reject(new Error("respuesta no es JSON: " + cuerpo.slice(0, 200))); }
        });
      }
    );
    req.on("error", reject);
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
    req.end();
  });
}

// Descarga una tabla entera, paginando. Sin `order` el orden no es
// determinista entre páginas y se pueden repetir/perder filas.
async function bajarTabla(base, headers, tabla) {
  const filas = [];
  for (let desde = 0; ; desde += PAGINA) {
    const url = `${base}/rest/v1/${tabla}?select=*&order=created_at.asc&limit=${PAGINA}&offset=${desde}`;
    let pagina;
    try {
      pagina = await pedir(url, headers);
    } catch (e) {
      // Tablas sin created_at (match_config, app_config): reintentar sin orden.
      if (/created_at/.test(String(e.message))) {
        pagina = await pedir(`${base}/rest/v1/${tabla}?select=*&limit=${PAGINA}&offset=${desde}`, headers);
      } else throw e;
    }
    filas.push(...pagina);
    if (pagina.length < PAGINA) break;
  }
  return filas;
}

// Las cuentas viven en auth.users, que NO se puede leer por PostgREST.
async function bajarCuentas(base, key) {
  const cuentas = [];
  for (let p = 1; ; p++) {
    const r = await pedir(`${base}/auth/v1/admin/users?page=${p}&per_page=200`, {
      apikey: key, Authorization: "Bearer " + key,
    });
    const lote = Array.isArray(r) ? r : r.users || [];
    cuentas.push(...lote);
    if (lote.length < 200) break;
  }
  // Solo lo necesario para reconstruir: nada de tokens ni hashes.
  return cuentas.map((u) => ({
    id: u.id, email: u.email, phone: u.phone,
    created_at: u.created_at, last_sign_in_at: u.last_sign_in_at,
    email_confirmed_at: u.email_confirmed_at,
    providers: (u.app_metadata && u.app_metadata.providers) || [],
    user_metadata: u.user_metadata || {},
  }));
}

(async () => {
  const env = cargarEnv();
  const base = (env.SUPABASE_URL || "").replace(/\/+$/, "");
  const key = env.SUPABASE_SERVICE_ROLE_KEY || "";

  if (!base || !key) {
    console.error("\n✘ Faltan credenciales.\n");
    console.error("Crea el archivo `.env.local` en la raíz del proyecto con:\n");
    console.error("  SUPABASE_URL=https://agjzczxxawojicpxbiuu.supabase.co");
    console.error("  SUPABASE_SERVICE_ROLE_KEY=<la service_role key>\n");
    console.error("La key está en Supabase → Project Settings → API Keys → service_role.");
    console.error("Ese archivo ya está en .gitignore: no se sube al repositorio.\n");
    process.exit(1);
  }

  const headers = { apikey: key, Authorization: "Bearer " + key, Accept: "application/json" };
  const ahora = new Date();
  const sello = ahora.toISOString().slice(0, 16).replace("T", "_").replace(":", "");
  const destino = path.join(RAIZ, "backups", sello);
  fs.mkdirSync(destino, { recursive: true });

  console.log("\nKonektaYa · respaldo");
  console.log("destino: backups/" + sello + "\n");

  const resumen = { fecha: ahora.toISOString(), origen: base, tablas: {}, errores: {} };
  let totalFilas = 0;

  for (const tabla of TABLAS) {
    try {
      const filas = await bajarTabla(base, headers, tabla);
      fs.writeFileSync(path.join(destino, tabla + ".json"), JSON.stringify(filas, null, 2));
      resumen.tablas[tabla] = filas.length;
      totalFilas += filas.length;
      console.log("  ✔ " + tabla.padEnd(20) + String(filas.length).padStart(6) + " filas");
    } catch (e) {
      resumen.errores[tabla] = String(e.message);
      console.log("  ✘ " + tabla.padEnd(20) + " ERROR: " + String(e.message).slice(0, 90));
    }
  }

  try {
    const cuentas = await bajarCuentas(base, key);
    fs.writeFileSync(path.join(destino, "_auth_users.json"), JSON.stringify(cuentas, null, 2));
    resumen.tablas._auth_users = cuentas.length;
    totalFilas += cuentas.length;
    console.log("  ✔ " + "_auth_users".padEnd(20) + String(cuentas.length).padStart(6) + " cuentas");
  } catch (e) {
    resumen.errores._auth_users = String(e.message);
    console.log("  ✘ _auth_users          ERROR: " + String(e.message).slice(0, 90));
  }

  resumen.totalFilas = totalFilas;
  fs.writeFileSync(path.join(destino, "_resumen.json"), JSON.stringify(resumen, null, 2));

  const fallos = Object.keys(resumen.errores).length;
  console.log("\n" + (fallos ? "⚠ " : "✔ ") + totalFilas + " registros guardados en backups/" + sello);
  if (fallos) {
    console.log("  " + fallos + " tabla(s) con error — revisa _resumen.json antes de confiar en este respaldo.");
    process.exit(1);
  }
  console.log("  Corre esto ANTES de cualquier SQL que modifique datos.\n");
})().catch((e) => {
  console.error("\n✘ Falló el respaldo:", e.message, "\n");
  process.exit(1);
});
