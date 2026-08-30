-- ============================================================
-- KonektaYa · 3I · Broker OPERATIVO desde el registro
-- Correr en Supabase → SQL Editor → Run. Idempotente.
--
-- Antes: broker 'pendiente' = sus publicaciones NO hacían match
-- hasta que el admin lo aprobara → los brokers se registraban
-- como "Propietario" para esquivar la pausa.
-- Ahora: 'pendiente' = operativo (activo sin insignia);
--        'aprobado'  = verificado ✓ (insignia, no candado);
--        'rechazado' = bloqueado del matching (igual que antes).
-- ============================================================

create or replace function public.owner_is_blocked(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.profiles
    where id = uid
      and ( blocked = true
            or (role = 'broker' and coalesce(broker_status, 'pendiente') = 'rechazado') )
  );
$$;

-- Reflejar la nueva regla en las publicaciones existentes de todos los brokers
-- (los pendientes quedan liberados; los rechazados/bloqueados siguen fuera).
update public.properties p set owner_blocked = public.owner_is_blocked(p.owner_id)
  where p.owner_id in (select id from public.profiles where role = 'broker');
update public.searches s set owner_blocked = public.owner_is_blocked(s.owner_id)
  where s.owner_id in (select id from public.profiles where role = 'broker');
update public.vehicle_offers v set owner_blocked = public.owner_is_blocked(v.owner_id)
  where v.owner_id in (select id from public.profiles where role = 'broker');
update public.vehicle_searches v set owner_blocked = public.owner_is_blocked(v.owner_id)
  where v.owner_id in (select id from public.profiles where role = 'broker');

-- Verificación rápida (opcional): ningún broker pendiente debe quedar bloqueado.
-- select p.email, p.broker_status, public.owner_is_blocked(p.id) as bloqueado
--   from public.profiles p where p.role = 'broker';
