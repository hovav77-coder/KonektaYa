-- ============================================================
-- KonektaYa · 3H · Clientes y créditos: fecha de registro,
-- último acceso y desbloqueos por usuario en admin_list_users
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================

-- El tipo de retorno cambia (3 columnas nuevas): hay que soltar
-- la versión anterior (2i) antes de recrearla.
drop function if exists public.admin_list_users();

create function public.admin_list_users()
returns table (
  id uuid, email text, name text, phone text, role text,
  broker_status text, blocked boolean, balance numeric, publicaciones bigint,
  created_at timestamptz, last_sign_in_at timestamptz, desbloqueos bigint
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
      + (select count(*) from public.vehicle_searches x where x.owner_id = p.id) as publicaciones,
      p.created_at,
      -- Último acceso: lo guarda Supabase Auth; el definer puede leerlo.
      (select u.last_sign_in_at from auth.users u where u.id = p.id) as last_sign_in_at,
      (select count(*) from public.unlocks x where x.unlocker_id = p.id) as desbloqueos
    from public.profiles p
    order by p.created_at desc nulls last;
end $$;
grant execute on function public.admin_list_users() to authenticated;

-- Verificación rápida (opcional): debe listar columnas nuevas sin error.
-- select email, created_at, last_sign_in_at, desbloqueos from public.admin_list_users() limit 3;
