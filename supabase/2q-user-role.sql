-- ============================================================
-- KonektaYa · 2Q · Admin: cambiar el tipo de usuario (Cliente final / Broker)
-- ------------------------------------------------------------
-- Permite al admin reclasificar la CUENTA de un usuario desde el panel.
-- Al pasar a broker, lo deja aprobado (operativo) para que sus publicaciones
-- no queden bloqueadas; al pasar a cliente, limpia el estado de broker.
-- Recalcula owner_blocked de sus publicaciones según el nuevo rol/estado.
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================
create or replace function public.admin_set_user_role(target_email text, new_role text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  if new_role not in ('cliente final', 'broker', 'propietario') then
    raise exception 'Rol invalido: %', new_role;
  end if;
  select id into uid from public.profiles where lower(email) = lower(trim(target_email)) limit 1;
  if uid is null then raise exception 'No existe un usuario con ese email'; end if;

  if new_role = 'broker' then
    -- El admin lo clasifica manualmente => broker aprobado (operativo).
    update public.profiles set role = 'broker', broker_status = 'aprobado', updated_at = now() where id = uid;
  else
    -- Ya no es broker: limpia el estado de broker.
    update public.profiles set role = new_role, broker_status = null, updated_at = now() where id = uid;
  end if;

  -- Recalcular owner_blocked de sus publicaciones con el nuevo rol/estado.
  update public.properties       set owner_blocked = public.owner_is_blocked(uid) where owner_id = uid;
  update public.searches         set owner_blocked = public.owner_is_blocked(uid) where owner_id = uid;
  update public.vehicle_offers   set owner_blocked = public.owner_is_blocked(uid) where owner_id = uid;
  update public.vehicle_searches set owner_blocked = public.owner_is_blocked(uid) where owner_id = uid;
end $$;
grant execute on function public.admin_set_user_role(text, text) to authenticated;
