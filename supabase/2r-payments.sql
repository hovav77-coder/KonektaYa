-- ============================================================
-- KonektaYa · 2R · Interruptor global de pagos (kill switch)
-- ------------------------------------------------------------
-- Los cobros con PayPal arrancan APAGADOS (payments_enabled=false).
-- El admin los enciende/apaga desde el panel (RPC admin_set_payments_enabled).
-- La Edge Function paypal-credit rechaza crear/capturar órdenes si está apagado
-- (fail closed: si la tabla/fila no existe, también rechaza).
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================

create table if not exists public.app_config (
  id int primary key default 1,
  payments_enabled boolean not null default false,
  updated_at timestamptz default now(),
  constraint app_config_single_row check (id = 1)   -- una sola fila
);
insert into public.app_config (id) values (1) on conflict (id) do nothing;

alter table public.app_config enable row level security;

-- Lectura para usuarios logueados (el cliente muestra/oculta los botones de pago).
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config
  for select to authenticated using (true);
-- Sin policies de insert/update: solo escriben el RPC (SECURITY DEFINER) y service_role.

create or replace function public.admin_set_payments_enabled(p_on boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  update public.app_config set payments_enabled = coalesce(p_on, false), updated_at = now() where id = 1;
  return (select payments_enabled from public.app_config where id = 1);
end $$;
revoke execute on function public.admin_set_payments_enabled(boolean) from public;
revoke execute on function public.admin_set_payments_enabled(boolean) from anon;
grant execute on function public.admin_set_payments_enabled(boolean) to authenticated;
