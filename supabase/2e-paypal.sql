-- ============================================================
-- KonektaYa · Fase 2E · PayPal (idempotencia de órdenes acreditadas)
-- Correr en Supabase → SQL Editor → Run.
-- ============================================================
create table if not exists public.paypal_orders (
  order_id text primary key,          -- id de la orden de PayPal (evita doble acreditación)
  user_id uuid not null references auth.users (id) on delete cascade,
  amount numeric not null,
  created_at timestamptz default now()
);
alter table public.paypal_orders enable row level security;

drop policy if exists paypal_orders_select_own on public.paypal_orders;
create policy paypal_orders_select_own on public.paypal_orders
  for select to authenticated using (user_id = auth.uid());
-- (Sin insert/update por RLS: solo la Edge Function con service_role escribe aquí.)
