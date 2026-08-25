-- ============================================================
-- 3a · Cinta "EN VIVO" de la portada: RPC public_ticker()
-- ============================================================
-- La portada la ven visitantes SIN sesión, y las publicaciones solo se
-- cargan en el navegador con sesión iniciada. Este RPC devuelve los últimos
-- 12 eventos (máx. 48 h) con SOLO los campos del mensaje de la cinta:
-- tipo, operación, zona y fecha. Nada de emails, teléfonos, precios exactos
-- ni direcciones. Solo publicaciones activas y de dueños no bloqueados.
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

create or replace function public.public_ticker()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(e order by (e->>'t') desc), '[]'::jsonb) from (
    select e from (
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'operation', 'z', data->>'zone') e
       from properties
       where active = true and owner_blocked = false and created_at > now() - interval '48 hours'
       order by created_at desc limit 12)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'desiredOperation', 'z', data->>'desiredZone')
       from searches
       where active = true and owner_blocked = false and created_at > now() - interval '48 hours'
       order by created_at desc limit 12)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'vehiculo',
         'tipo', data->>'vehicleType', 'marca', data->>'brand', 'modelo', data->>'model', 'anio', data->>'year', 'z', data->>'zone')
       from vehicle_offers
       where active = true and owner_blocked = false and created_at > now() - interval '48 hours'
       order by created_at desc limit 12)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'vehiculo',
         'tipo', data->>'vehicleType', 'marca', data->>'desiredBrand', 'modelo', data->>'desiredModel', 'z', data->>'zone')
       from vehicle_searches
       where active = true and owner_blocked = false and created_at > now() - interval '48 hours'
       order by created_at desc limit 12)
    ) u(e)
    order by (e->>'t') desc
    limit 12
  ) fin(e);
$$;
revoke execute on function public.public_ticker() from public;
grant execute on function public.public_ticker() to anon;
grant execute on function public.public_ticker() to authenticated;
