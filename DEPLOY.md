# KonektaYa — Guía de despliegue

Dominio: **konektaya.com** · Hosting: **Vercel** · Base de datos (Fase 2): **Supabase**

El proyecto es hoy un sitio estático: un solo `index.html` autónomo. No necesita build.

---

## FASE 1 — Publicar konektaya.com (estático)

Objetivo: que el sitio esté en vivo bajo tu dominio, accesible desde cualquier dispositivo.
Nota: en esta fase los datos siguen guardándose en el navegador de cada visitante (localStorage).
La base de datos compartida llega en la Fase 2.

### Ruta A — Vercel CLI (la más rápida, sin GitHub)

En una terminal, dentro de la carpeta del proyecto:

```
cd "C:\Users\HSAID\Desarollo Claude\KonektaYa"
npx vercel login          # abre el navegador para iniciar sesión (o crea cuenta gratis)
npx vercel                # primer deploy de prueba (responde Enter a las preguntas)
npx vercel --prod         # deploy de producción
```

- En las preguntas del primer `vercel`: "Set up and deploy?" → **Y**; "Which scope?" → tu cuenta;
  "Link to existing project?" → **N**; "Project name?" → `konektaya`; "Directory?" → **.** (Enter);
  "Override settings?" → **N**.
- Al terminar te da una URL tipo `konektaya-xxxx.vercel.app`. Ábrela para confirmar que carga.

### Ruta B — GitHub + Vercel (mejor a largo plazo, deploy automático en cada cambio)

1. Crea un repo en https://github.com/new (privado), ej. `konektaya`.
2. En la terminal, dentro de la carpeta:
   ```
   git init
   git add .
   git commit -m "KonektaYa demo - fase 1"
   git branch -M main
   git remote add origin https://github.com/TU_USUARIO/konektaya.git
   git push -u origin main
   ```
3. Entra a https://vercel.com → **Add New → Project** → importa el repo `konektaya`.
4. Vercel leerá `vercel.json` (framework: none, sin build). Haz **Deploy**.
5. Desde ahora, cada `git push` re-despliega solo.

### Conectar el dominio konektaya.com

1. En el proyecto de Vercel → **Settings → Domains → Add** → escribe `konektaya.com` y también `www.konektaya.com`.
2. Vercel te mostrará los registros DNS exactos a configurar. Normalmente:
   - **konektaya.com** (apex): registro **A** → `76.76.21.21`
   - **www.konektaya.com**: registro **CNAME** → `cname.vercel-dns.com`
   - (Alternativa: cambiar los *nameservers* del dominio a los de Vercel — Vercel te los indica.)
3. Entra al panel donde compraste konektaya.com (GoDaddy, Namecheap, etc.) → zona DNS → crea/edita
   esos registros con los valores EXACTOS que muestra Vercel.
4. Espera la propagación (minutos a unas horas). Vercel emite el certificado HTTPS solo.
5. Listo: https://konektaya.com en vivo.

---

## FASE 2 — Base de datos real con Supabase (roadmap)

Convierte el demo en producto: datos compartidos entre todos los usuarios y desde cualquier dispositivo.

Qué implica (trabajo de desarrollo, se hace por partes):

1. **Crear proyecto en Supabase** (https://supabase.com) — gratis para empezar. Guardar URL y claves.
2. **Diseñar el esquema** (tablas): `properties`, `searches`, `vehicle_offers`, `vehicle_searches`,
   `user_accounts`, `contact_requests`, `unlocks`, `balance`, etc. — reflejan lo que hoy vive en localStorage.
3. **Autenticación segura**: usar Supabase Auth (email + contraseña, opcional Google). Elimina el
   problema actual de contraseñas en texto plano.
4. **Capa de datos**: reemplazar las llamadas a `localStorage` del `index.html` por llamadas a Supabase
   (guardar/leer propiedades, búsquedas, matches, créditos, desbloqueos).
5. **Conectar Supabase con Vercel**: variables de entorno en Vercel
   (`NEXT_PUBLIC_SUPABASE_URL`, `SUPABASE_ANON_KEY`, y clave de servicio para operaciones privadas).
6. **Reglas de seguridad (RLS)**: cada usuario solo ve/edita lo suyo; contactos protegidos hasta desbloqueo.
7. **Migración de datos demo** (opcional): sembrar ejemplos en la base.

Decisión pendiente para el arranque de Fase 2: mantener el `index.html` monolítico llamando a Supabase
desde el navegador (más rápido), o migrar a una app con funciones serverless (más robusto y seguro
para la lógica de créditos/desbloqueos). Recomendación: lógica sensible (cobros, desbloqueos) en el
servidor; lectura/publicación puede ir directo con RLS.

---

## Estado del código para deploy (ya configurado)

- `vercel.json` → framework: none, sin build, sirve la raíz, cleanUrls.
- `package.json` → mínimo, sin dependencias (Fase 1 no necesita build).
- `.gitignore` → ignora node_modules, .vercel, .env locales.
- `index.html` → la app completa (inmuebles + vehículos, matching, dashboard, admin).
