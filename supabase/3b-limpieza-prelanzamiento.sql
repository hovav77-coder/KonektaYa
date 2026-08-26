-- ============================================================
-- 3b · Limpieza pre-lanzamiento: arrancar la analítica en 0
-- ============================================================
-- Borra los DATOS de prueba de julio/agosto 2026. NO toca configuración:
-- app_config (pagos, soporte), match_config (fórmula), coupons (BIENVENIDO10),
-- ni las funciones/reglas de seguridad. Tampoco toca cuentas: las cuentas de
-- prueba se borran ANTES desde el admin (Registros → eliminar usuario).
--
-- ORDEN CORRECTO:
--   1) node scripts/backup.js            (respaldo completo primero)
--   2) Borrar las cuentas de prueba desde el panel ADMIN
--   3) Correr ESTE archivo: Supabase → SQL Editor → pegar todo → Run
--
-- Es seguro correrlo más de una vez (borra lo que quede, si no hay nada
-- no hace nada).

-- Desbloqueos de prueba que involucren cuentas que se quedan
delete from public.unlocks;

-- Orden PayPal huérfana (estado 'created', $0, nunca cobrada — 11-jul-2026)
delete from public.paypal_orders;

-- Canjes de cupón de prueba (la DEFINICIÓN del cupón BIENVENIDO10 se queda)
delete from public.coupon_redemptions;

-- Solicitudes del flujo viejo de pruebas
delete from public.interest_requests;
delete from public.contact_requests;

-- Avisos de match de prueba
delete from public.match_notifications;

-- Saldo de prueba de las billeteras de las cuentas que se quedan → $0
update public.wallets set balance = 0;

-- Contador de visitas: reiniciar para que el día 1 sea el del lanzamiento
delete from public.visit_days;
