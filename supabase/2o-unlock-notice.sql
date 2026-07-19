-- ============================================================
-- KonektaYa · 2O · Transparencia + revelado mutuo del desbloqueo
-- Cuando un dueño paga para ver el contacto de un buscador, el buscador:
--   (a) recibe aviso (in-app + email; el email lo manda la Edge Function unlock), y
--   (b) puede ver el contacto de QUIEN lo desbloqueó (revelado mutuo) — porque el
--       otro ya pagó y quiere que lo contacten.
-- Este RPC es el espejo de get_unlocked_contacts: devuelve, para el usuario actual
-- (el buscador = counterpart), los desbloqueos de SU contacto + el contacto del
-- que desbloqueó (unlocker). SECURITY DEFINER, pero SOLO expone perfiles de quienes
-- ya pagaron por ver el del usuario (u.counterpart_id = auth.uid()).
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================
create or replace function public.get_who_unlocked_me()
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
  left join public.profiles p on p.id = u.unlocker_id
  where u.counterpart_id = auth.uid()
  order by u.created_at desc;
$$;

revoke execute on function public.get_who_unlocked_me() from public;
revoke execute on function public.get_who_unlocked_me() from anon;
grant  execute on function public.get_who_unlocked_me() to authenticated;
