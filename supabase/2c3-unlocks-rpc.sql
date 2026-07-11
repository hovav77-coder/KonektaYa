-- ============================================================
-- KonektaYa · Fase 2C-3 · RPC para recuperar los contactos ya desbloqueados
-- Devuelve, para el usuario actual, sus desbloqueos + el contacto del interesado.
-- SECURITY DEFINER: puede leer profiles ajenos SOLO de los que ya pagó (unlocks).
-- Correr en Supabase → SQL Editor → Run.
-- ============================================================
create or replace function public.get_unlocked_contacts()
returns table (
  offer_id uuid,
  search_id uuid,
  vertical text,
  price numeric,
  created_at timestamptz,
  name text,
  phone text,
  email text
)
language sql
security definer
set search_path = public
as $$
  select u.offer_id, u.search_id, u.vertical, u.price, u.created_at,
         p.name, p.phone, p.email
  from public.unlocks u
  left join public.profiles p on p.id = u.counterpart_id
  where u.unlocker_id = auth.uid();
$$;

grant execute on function public.get_unlocked_contacts() to authenticated;
