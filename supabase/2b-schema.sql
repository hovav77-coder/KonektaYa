-- ============================================================
-- KonektaYa · Fase 2B · Esquema base (perfiles + publicaciones)
-- Correr en Supabase → SQL Editor → New query → pegar → Run.
-- Idempotente y seguro (recrea las tablas de publicaciones vacías).
--
-- PRIVACIDAD: las publicaciones usan owner_id (UUID opaco), NUNCA el email.
-- El contacto (nombre/teléfono/email) vive solo en profiles (privado).
-- ============================================================

-- ---------- PROFILES: contacto + cuenta (PRIVADO) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text unique not null,
  name text,
  phone text,
  role text,                       -- 'cliente final' | 'broker' | 'propietario'
  broker_license text,
  broker_company text,
  broker_independent boolean default false,
  broker_status text default 'pendiente',  -- pendiente | aprobado | rechazado
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.profiles enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated using (auth.uid() = id);

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated with check (auth.uid() = id);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated using (auth.uid() = id);

-- Crear el profile automáticamente al registrarse
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- PUBLICACIONES (datos PÚBLICOS para el matching) ----------
-- 'data' = campos públicos del registro (tipo, zona, precio, m², año, km...),
-- SIN contacto. owner_id = dueño (UUID, opaco). Cualquier logueado LEE;
-- solo el dueño crea/edita/borra lo suyo.

do $$
declare t text;
begin
  foreach t in array array['properties','searches','vehicle_offers','vehicle_searches']
  loop
    execute format('drop table if exists public.%I cascade;', t);
    execute format($f$
      create table public.%1$I (
        id uuid primary key default gen_random_uuid(),
        owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
        data jsonb not null default '{}'::jsonb,
        active boolean default true,
        created_at timestamptz default now(),
        updated_at timestamptz default now()
      );
      alter table public.%1$I enable row level security;

      create policy %1$s_read_all on public.%1$I
        for select to authenticated using (true);

      create policy %1$s_insert_own on public.%1$I
        for insert to authenticated with check (owner_id = auth.uid());

      create policy %1$s_update_own on public.%1$I
        for update to authenticated using (owner_id = auth.uid());

      create policy %1$s_delete_own on public.%1$I
        for delete to authenticated using (owner_id = auth.uid());

      create index %1$s_owner_idx on public.%1$I (owner_id);
    $f$, t);
  end loop;
end $$;
