# KonektaYa — Recuperación de desastre

Cómo volver a levantar KonektaYa desde cero si se pierde el proyecto de
Supabase, o cómo restaurar los datos sobre un proyecto nuevo.

> **Estado: NO PROBADO de punta a punta.** El procedimiento sale de leer el
> esquema y los triggers reales, no de haberlo ejecutado. Las trampas que
> aparecen marcadas con ⚠️ son reales y verificadas en el código, pero la
> primera vez que se corra habrá sorpresas. **Pruébalo una vez en un
> proyecto de Supabase vacío y gratuito ANTES de necesitarlo de verdad**, y
> corrige este documento con lo que aprendas.

---

## 1. Qué tienes y qué no

| Pieza | Dónde vive | ¿Respaldada? |
|---|---|---|
| Código de la app (`index.html`) | GitHub | ✅ |
| Esquema de la base (`supabase/*.sql`) | GitHub | ✅ |
| Edge Functions (`supabase/functions/`) | GitHub | ✅ |
| Datos de las 15 tablas | Google Drive (`scripts/backup.js`) | ✅ |
| Cuentas de usuario (id, email, teléfono) | Google Drive (`_auth_users.json`) | ✅ |
| **Contraseñas de los usuarios** | — | ❌ **a propósito** |
| **Secretos** (Resend, PayPal, Google) | — | ❌ ver sección 2 |
| **Configuración del panel de Supabase** | — | ❌ ver sección 2 |
| Archivos subidos (Storage) | — | n/a (el proyecto no usa Storage) |

**Las contraseñas no se respaldan a propósito.** Guardar los hashes en Drive
sería un riesgo mayor que el que resuelve. Consecuencia al restaurar: quien
entra con email tendrá que usar "¿Olvidaste tu contraseña?". Quien entra con
Google no nota nada.

---

## 2. Hoja de secretos — RELLENAR Y GUARDAR APARTE

Sin esto, los datos no sirven de nada: el sistema levanta pero no manda
correos ni cobra.

> ⚠️ **NO rellenes esta tabla aquí.** Este archivo está en GitHub. Cópiala a
> tu gestor de contraseñas (1Password, Bitwarden, el de Google) o a un
> documento privado en Drive. `.gitignore` bloquea cualquier archivo que
> empiece por `SECRETOS` como red de seguridad, pero no dependas de eso.

### Secretos de las Edge Functions
En Supabase → Edge Functions → Secrets. Los tres primeros los inyecta
Supabase solo; los otros los pusiste tú.

| Nombre | De dónde sale | Valor |
|---|---|---|
| `SUPABASE_URL` | automático | — |
| `SUPABASE_ANON_KEY` | automático | — |
| `SUPABASE_SERVICE_ROLE_KEY` | automático | — |
| `RESEND_API_KEY` | panel de Resend → API Keys | ` ` |
| `NOTIFY_FROM` | ej. `KonektaYa <avisos@konektaya.com>` | ` ` |
| `PAYPAL_CLIENT_ID` | PayPal Developer → app LIVE | ` ` |
| `PAYPAL_SECRET` | PayPal Developer → app LIVE | ` ` |
| `PAYPAL_ENV` | `live` | ` ` |

### Configuración del panel de Supabase
| Qué | Dónde | Valor |
|---|---|---|
| Google OAuth Client ID | Auth → Providers → Google | ` ` |
| Google OAuth Secret | Auth → Providers → Google | ` ` |
| Site URL | Auth → URL Configuration | `https://konektaya.com` |
| Redirect URLs | Auth → URL Configuration | `https://konektaya.com/**`, `https://www.konektaya.com/**`, `http://localhost:3000/**` |

### Otros accesos
| Qué | Valor |
|---|---|
| Cuenta de Supabase (email) | ` ` |
| Cuenta de Vercel | ` ` |
| Cuenta de GitHub | ` ` |
| Registrador del dominio konektaya.com | ` ` |
| Cuenta de Resend | ` ` |
| Cuenta de PayPal (negocio) | ` ` |
| Google Cloud (proyecto del OAuth) | ` ` |

### Datos que están en el código (no son secretos, pero hay que reponerlos)
Si cambias de proyecto de Supabase, hay que editar `index.html`:
- `SUPABASE.url` y `SUPABASE.key` (~línea 14232) → los del proyecto nuevo
- `SUPABASE.adminEmails` → `hovav@saidacpa.com`, `asistencia.gerencia@saidacpa.com`
- `PAYPAL.clientId` (~línea 14291)
- `window.GOOGLE_GSI_CLIENT_ID` (~línea 18286)
- El SQL `2c-money.sql` tiene los emails de admin dentro de una policy: revisar.

---

## 3. Restaurar: el orden importa

### Paso 0 — Antes de tocar nada
Ten a mano el respaldo más reciente de `G:\Mi unidad\KonektaYa-Respaldos\`.
Abre `_resumen.json` y confirma que `errores` está vacío. Un respaldo con
errores no sirve para restaurar.

### Paso 1 — Crear el proyecto de Supabase
Plan **Pro** desde el inicio (el gratuito pausa por inactividad y no hace
copias). Anota la nueva URL y las llaves.

### Paso 2 — Correr los SQL EN ESTE ORDEN
Uno por uno en el SQL Editor. El orden alfabético es el correcto:

```
2b-schema.sql          2l-block-contact-info.sql
2c-money.sql           2m-remove-publication.sql
2c3-unlocks-rpc.sql    2n-cycle-server.sql
2d-secondary.sql       2o-unlock-notice.sql
2e-paypal.sql          2p-receipts.sql
2g-security.sql        2q-user-role.sql
2h-admin-credit.sql    2r-payments.sql
2i-admin-users.sql     2s-coupons.sql
2j-notify-matches.sql  2t-welcome.sql
2k-admin-delete-user.sql
```

(No hay `2f`, no falta nada.)

> ⚠️ **`2b-schema.sql` BORRA las 4 tablas de publicaciones** (`drop table ...
> cascade`). Solo se corre sobre un proyecto vacío. Volver a correrlo sobre
> producción destruye los datos.

### Paso 3 — Restaurar las cuentas PRIMERO
Todas las tablas apuntan a `auth.users(id)` con `on delete cascade`. Si los
usuarios no existen, ningún dato entra; y **los ids tienen que ser los
mismos del respaldo** o se rompen todas las referencias.

Fuente: `_auth_users.json`. Dos caminos:

- **Admin API** (`POST /auth/v1/admin/users` con la service_role key),
  pasando el `id` original de cada usuario.
- **INSERT directo en `auth.users`** desde el SQL Editor (funciona porque
  ahí corres como `postgres`), sin contraseña.

En ambos casos las contraseñas quedan vacías → los usuarios entran con
"¿Olvidaste tu contraseña?".

> ⚠️ Existe un trigger `on_auth_user_created` que crea el `profiles` al
> nacer un usuario. Al restaurar cuentas se van a auto-crear perfiles
> vacíos; el paso 4 debe **actualizarlos** (upsert), no insertarlos, o dará
> error de clave duplicada.

### Paso 4 — Restaurar los datos, en este orden
1. `profiles` (upsert, ver aviso de arriba)
2. `wallets`
3. `properties`, `searches`, `vehicle_offers`, `vehicle_searches`
4. `unlocks`, `paypal_orders`, `interest_requests`, `contact_requests`,
   `match_notifications`, `coupons`, `coupon_redemptions`
5. `match_config`, `app_config` (sin dependencias, van cuando sea)

> ⚠️ **Hay tres triggers que estorban al restaurar. Desactívalos antes y
> vuelve a activarlos después:**
>
> - **`trg_block_contact`** — escanea todo el jsonb buscando datos de
>   contacto. Con una sola publicación antigua que dispare el detector, el
>   INSERT falla.
> - **`trg_protect_cycle`** — impide escribir `cycle_start`, así que se
>   perdería el ciclo de cobro de cada publicación.
> - **`trg_owner_blocked`** — recalcula `owner_blocked` al insertar. No hace
>   falta restaurar esa columna: el trigger la pone bien sola.
>
> ```sql
> alter table public.properties disable trigger trg_block_contact;
> -- ... restaurar ...
> alter table public.properties enable trigger trg_block_contact;
> ```
> Repetir en `searches`, `vehicle_offers` y `vehicle_searches`.

### Paso 5 — Edge Functions
Pegar cada una en el panel (Edge Functions → Deploy). `git push` **no**
despliega funciones.

| Carpeta local | Nombre en Supabase |
|---|---|
| `unlock` | **`rapid-action`** ← ojo, distinto |
| `welcome-email` | `welcome-email` |
| `notify-matches` | `notify-matches` |
| `paypal-credit` | `paypal-credit` |

> ⚠️ Al pegar `unlock`, escribir el regex `DIACRITICS` como
> `/[\u0300-\u036f]/g`. El archivo local tiene ahí caracteres invisibles que
> se rompen al copiar.

Después cargar los secretos de la sección 2.

### Paso 6 — Auth y dominio
- Auth → Providers → Google: Client ID y Secret.
- Auth → URL Configuration: Site URL y Redirect URLs.
- Vercel: reconectar el repo y el dominio konektaya.com.

### Paso 7 — Actualizar el código
Editar `index.html` con la URL y la llave del proyecto nuevo (ver final de
la sección 2) y hacer `git push`.

### Paso 8 — Verificar antes de avisar a nadie
- [ ] Entrar con una cuenta de email y con Google.
- [ ] Publicar algo y confirmar que llega al servidor (recargar y ver si sigue).
- [ ] Que aparezca al menos una coincidencia.
- [ ] Que llegue el correo de bienvenida (cuenta nueva).
- [ ] Que los saldos de `wallets` cuadren con el respaldo.
- [ ] Que el historial de `unlocks` esté completo.
- [ ] Un desbloqueo real de punta a punta (con pagos encendidos).

---

## 4. Rutina de respaldo

```bash
node scripts/backup.js
```

Deja todo en `G:\Mi unidad\KonektaYa-Respaldos\<fecha>\` y Drive lo sube
solo. Configuración en `.env.local` (fuera de git).

**Cuándo:** siempre antes de un SQL que modifique datos, antes de tocar el
esquema o las funciones, una vez por semana mientras se prueba, y a diario
con usuarios reales.

Si Drive no está montado, el script **falla y no guarda nada** — a propósito,
para que no exista un respaldo que parece estar en la nube y no lo está.

---

## 5. Lo que falta por hacer

- [ ] **Probar esta recuperación** en un proyecto vacío. Es lo único que
      convierte este documento en algo confiable.
- [ ] Rellenar la hoja de secretos (sección 2) y guardarla fuera del repo.
- [ ] Escribir un script de restauración que automatice los pasos 3 y 4,
      con el manejo de triggers incluido.
