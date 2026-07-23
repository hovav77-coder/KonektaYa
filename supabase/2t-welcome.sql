-- KonektaYa · 2t: email de bienvenida
-- Marca cuándo se envió la bienvenida (idempotencia del envío: una vez por cuenta).
-- La escribe SOLO la Edge Function `welcome-email` (service_role): los grants de
-- UPDATE de profiles son por columna (2g-security.sql) y welcomed_at NO está en
-- la lista, así que el cliente no puede fabricarla ni borrarla. El SELECT de la
-- tabla sigue completo, por lo que la app la lee con su select("*") normal.
--
-- Correr en: Supabase → SQL Editor → New query → pegar → Run.

alter table public.profiles add column if not exists welcomed_at timestamptz;
