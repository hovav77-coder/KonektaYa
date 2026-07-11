-- ============================================================
-- KonektaYa · Fase 2C · Dinero seguro (wallet + unlocks + config)
-- Correr en Supabase → SQL Editor → New query → pegar → Run.
-- Idempotente.
-- ============================================================

-- ---------- WALLET (saldo): solo lectura propia, se modifica SOLO por funciones ----------
create table if not exists public.wallets (
  user_id uuid primary key references auth.users (id) on delete cascade,
  balance numeric not null default 0,
  updated_at timestamptz default now()
);
alter table public.wallets enable row level security;

drop policy if exists wallets_select_own on public.wallets;
create policy wallets_select_own on public.wallets
  for select to authenticated using (user_id = auth.uid());
-- (Sin políticas de insert/update: nadie escribe el saldo directo.
--  Solo lo cambian funciones SECURITY DEFINER como add_credit / unlock.)

-- ---------- UNLOCKS (desbloqueos pagados) ----------
create table if not exists public.unlocks (
  id uuid primary key default gen_random_uuid(),
  unlocker_id uuid not null references auth.users (id) on delete cascade,
  vertical text not null,           -- 'inmueble' | 'vehiculo'
  offer_id uuid not null,           -- publicación del que paga
  search_id uuid not null,          -- publicación del interesado
  counterpart_id uuid not null,     -- dueño del search (a quien se revela)
  price numeric not null default 0,
  created_at timestamptz default now(),
  unique (unlocker_id, offer_id, search_id)
);
alter table public.unlocks enable row level security;

drop policy if exists unlocks_select_own on public.unlocks;
create policy unlocks_select_own on public.unlocks
  for select to authenticated using (unlocker_id = auth.uid());

-- ---------- MATCH_CONFIG global (una sola fila; la escribe el Laboratorio) ----------
create table if not exists public.match_config (
  id int primary key default 1,
  config jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now(),
  constraint match_config_single_row check (id = 1)
);
alter table public.match_config enable row level security;

drop policy if exists match_config_read on public.match_config;
create policy match_config_read on public.match_config
  for select to authenticated using (true);

drop policy if exists match_config_write on public.match_config;
create policy match_config_write on public.match_config
  for all to authenticated
  using ((auth.jwt() ->> 'email') in ('hovav@saidacpa.com', 'asistencia.gerencia@saidacpa.com'))
  with check ((auth.jwt() ->> 'email') in ('hovav@saidacpa.com', 'asistencia.gerencia@saidacpa.com'));

-- ---------- RPC: agregar crédito (modo demo; luego lo gatilla PayPal) ----------
create or replace function public.add_credit(amount numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare newbal numeric;
begin
  if amount is null or amount <= 0 then
    raise exception 'Monto inválido';
  end if;
  insert into public.wallets (user_id, balance)
    values (auth.uid(), amount)
  on conflict (user_id)
    do update set balance = public.wallets.balance + excluded.balance, updated_at = now()
  returning balance into newbal;
  return newbal;
end;
$$;

grant execute on function public.add_credit(numeric) to authenticated;

-- ---------- Helper: saldo actual del usuario ----------
create or replace function public.my_balance()
returns numeric
language sql
security definer
set search_path = public
as $$
  select coalesce((select balance from public.wallets where user_id = auth.uid()), 0);
$$;

grant execute on function public.my_balance() to authenticated;
