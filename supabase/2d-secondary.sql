-- ============================================================
-- KonektaYa · Fase 2D · Migración de flujos secundarios
-- (aprobación de brokers · "quiero que me contacten" · "preguntar interés")
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================

-- ---------- 1) owner_blocked en publicaciones (broker pendiente = no matchea) ----------
do $$ declare t text; begin
  foreach t in array array['properties','searches','vehicle_offers','vehicle_searches'] loop
    execute format('alter table public.%I add column if not exists owner_blocked boolean not null default false;', t);
  end loop;
end $$;

create or replace function public.owner_is_blocked(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.profiles
    where id = uid and role = 'broker' and coalesce(broker_status, 'pendiente') <> 'aprobado'
  );
$$;

create or replace function public.set_owner_blocked()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.owner_blocked := public.owner_is_blocked(new.owner_id);
  return new;
end $$;

do $$ declare t text; begin
  foreach t in array array['properties','searches','vehicle_offers','vehicle_searches'] loop
    execute format('drop trigger if exists trg_owner_blocked on public.%I;', t);
    execute format('create trigger trg_owner_blocked before insert on public.%I for each row execute function public.set_owner_blocked();', t);
  end loop;
end $$;

-- ---------- 2) Admin helpers ----------
create or replace function public.is_admin()
returns boolean language sql stable as $$
  select (auth.jwt() ->> 'email') in ('hovav@saidacpa.com', 'asistencia.gerencia@saidacpa.com');
$$;

create or replace function public.admin_list_brokers()
returns table (
  id uuid, email text, name text, phone text,
  broker_license text, broker_company text, broker_independent boolean,
  broker_status text, publicaciones bigint
)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  return query
    select p.id, p.email, p.name, p.phone, p.broker_license, p.broker_company, p.broker_independent, p.broker_status,
      (select count(*) from public.properties x where x.owner_id = p.id)
      + (select count(*) from public.searches x where x.owner_id = p.id)
      + (select count(*) from public.vehicle_offers x where x.owner_id = p.id)
      + (select count(*) from public.vehicle_searches x where x.owner_id = p.id)
    from public.profiles p where p.role = 'broker';
end $$;
grant execute on function public.admin_list_brokers() to authenticated;

create or replace function public.admin_set_broker_status(target uuid, new_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  update public.profiles set broker_status = new_status, updated_at = now() where id = target;
  update public.properties set owner_blocked = (new_status <> 'aprobado') where owner_id = target;
  update public.searches set owner_blocked = (new_status <> 'aprobado') where owner_id = target;
  update public.vehicle_offers set owner_blocked = (new_status <> 'aprobado') where owner_id = target;
  update public.vehicle_searches set owner_blocked = (new_status <> 'aprobado') where owner_id = target;
end $$;
grant execute on function public.admin_set_broker_status(uuid, text) to authenticated;

-- ---------- 3) INTEREST REQUESTS (el dueño pregunta al interesado "¿te interesa?") ----------
create table if not exists public.interest_requests (
  id uuid primary key default gen_random_uuid(),
  vertical text not null,
  offer_id uuid not null,
  search_id uuid not null,
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,   -- quien pregunta
  client_id uuid not null references auth.users (id) on delete cascade,                      -- el interesado
  status text not null default 'pending',   -- pending | confirmed | declined
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (owner_id, offer_id, search_id)
);
alter table public.interest_requests enable row level security;

drop policy if exists ir_select on public.interest_requests;
create policy ir_select on public.interest_requests
  for select to authenticated using (owner_id = auth.uid() or client_id = auth.uid());
drop policy if exists ir_insert on public.interest_requests;
create policy ir_insert on public.interest_requests
  for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists ir_update on public.interest_requests;
create policy ir_update on public.interest_requests
  for update to authenticated using (client_id = auth.uid() or owner_id = auth.uid());

-- ---------- 4) CONTACT REQUESTS (el interesado pide "quiero que me contacten") ----------
create table if not exists public.contact_requests (
  id uuid primary key default gen_random_uuid(),
  vertical text not null,
  offer_id uuid not null,
  search_id uuid not null,
  client_id uuid not null default auth.uid() references auth.users (id) on delete cascade,   -- quien pide
  owner_id uuid not null references auth.users (id) on delete cascade,                        -- dueño del offer
  reminders int not null default 0,
  created_at timestamptz default now(),
  last_at timestamptz default now(),
  unique (client_id, offer_id, search_id)
);
alter table public.contact_requests enable row level security;

drop policy if exists cr_select on public.contact_requests;
create policy cr_select on public.contact_requests
  for select to authenticated using (client_id = auth.uid() or owner_id = auth.uid());
drop policy if exists cr_insert on public.contact_requests;
create policy cr_insert on public.contact_requests
  for insert to authenticated with check (client_id = auth.uid());
drop policy if exists cr_update on public.contact_requests;
create policy cr_update on public.contact_requests
  for update to authenticated using (client_id = auth.uid());
