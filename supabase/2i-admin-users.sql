-- ============================================================
-- KonektaYa · 2I · Admin: ver TODOS los usuarios + bloquear + saldo +/-
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================

-- 1) Columna para bloquear un usuario (no puede operar: matchear/desbloquear)
alter table public.profiles add column if not exists blocked boolean not null default false;

-- 2) Un usuario bloqueado O broker no aprobado => owner_blocked (no aparece en matches)
create or replace function public.owner_is_blocked(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.profiles
    where id = uid
      and ( blocked = true
            or (role = 'broker' and coalesce(broker_status, 'pendiente') <> 'aprobado') )
  );
$$;

-- 3) Listar todos los usuarios (solo admin), con saldo y # de publicaciones
create or replace function public.admin_list_users()
returns table (
  id uuid, email text, name text, phone text, role text,
  broker_status text, blocked boolean, balance numeric, publicaciones bigint
)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  return query
    select p.id, p.email, p.name, p.phone, p.role, p.broker_status, p.blocked,
      coalesce((select w.balance from public.wallets w where w.user_id = p.id), 0) as balance,
      (select count(*) from public.properties x where x.owner_id = p.id)
      + (select count(*) from public.searches x where x.owner_id = p.id)
      + (select count(*) from public.vehicle_offers x where x.owner_id = p.id)
      + (select count(*) from public.vehicle_searches x where x.owner_id = p.id) as publicaciones
    from public.profiles p
    order by p.email;
end $$;
grant execute on function public.admin_list_users() to authenticated;

-- 4) Ajustar saldo (delta puede ser negativo; nunca baja de 0). Solo admin.
create or replace function public.admin_adjust_credit(target_email text, delta numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare uid uuid; newbal numeric;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select id into uid from public.profiles where lower(email) = lower(trim(target_email)) limit 1;
  if uid is null then raise exception 'No existe un usuario con ese email'; end if;
  insert into public.wallets (user_id, balance) values (uid, 0) on conflict (user_id) do nothing;
  update public.wallets set balance = greatest(0, balance + delta), updated_at = now()
    where user_id = uid returning balance into newbal;
  return newbal;
end $$;
grant execute on function public.admin_adjust_credit(text, numeric) to authenticated;

-- 5) Bloquear / desbloquear usuario (solo admin) + reflejar en sus publicaciones
create or replace function public.admin_set_user_blocked(target_email text, p_blocked boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select id into uid from public.profiles where lower(email) = lower(trim(target_email)) limit 1;
  if uid is null then raise exception 'No existe un usuario con ese email'; end if;
  update public.profiles set blocked = p_blocked, updated_at = now() where id = uid;
  update public.properties      set owner_blocked = public.owner_is_blocked(uid) where owner_id = uid;
  update public.searches        set owner_blocked = public.owner_is_blocked(uid) where owner_id = uid;
  update public.vehicle_offers  set owner_blocked = public.owner_is_blocked(uid) where owner_id = uid;
  update public.vehicle_searches set owner_blocked = public.owner_is_blocked(uid) where owner_id = uid;
end $$;
grant execute on function public.admin_set_user_blocked(text, boolean) to authenticated;
