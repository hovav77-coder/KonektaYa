-- ============================================================
-- KonektaYa · 2K · Admin: eliminar un usuario por completo
-- Correr en Supabase → SQL Editor → Run. Idempotente.
--
-- Borra el usuario de auth.users; TODO lo suyo cae en cascada:
-- profiles, properties/searches/vehicle_offers/vehicle_searches (owner_id),
-- wallets, unlocks, match_notifications. Así el email queda libre para
-- volver a registrarse (útil para limpiar usuarios de prueba).
-- ============================================================

create or replace function public.admin_delete_user(target_email text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select id into uid from public.profiles where lower(email) = lower(trim(target_email)) limit 1;
  if uid is null then raise exception 'No existe un usuario con ese email'; end if;
  if uid = auth.uid() then raise exception 'No puedes eliminar tu propia cuenta'; end if;

  -- Limpieza explícita de tablas SIN FK-cascade a auth.users (por si acaso).
  delete from public.match_notifications where recipient_id = uid;
  delete from public.unlocks where unlocker_id = uid or counterpart_id = uid;

  -- Borrar el usuario de auth; el resto cae en cascada (ON DELETE CASCADE).
  delete from auth.users where id = uid;
end $$;

grant execute on function public.admin_delete_user(text) to authenticated;
