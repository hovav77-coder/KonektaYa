-- ============================================================
-- 3f · Cinta: búsquedas de vehículo con año mínimo, sin presupuesto
-- ============================================================
-- Requiere haber corrido 3e (reemplaza su public_ticker).
--
-- Formato aprobado para vehículos:
--   Publicado:  "SAN MIGUELITO · Yamaha MT-07 2023 en venta" (igual que 3e)
--   Búsqueda:   "CIUDAD DE PANAMÁ · Buscan Kia Sportage 2020+"  ← año mínimo,
--               y SIN presupuesto (ya no se envía para vehículos).
-- Las búsquedas de INMUEBLE conservan su presupuesto ("hasta $1,200 al mes").
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

create or replace function public.public_ticker()
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg record; reales jsonb; promos jsonb;
begin
  select ticker_enabled, ticker_hours, ticker_min, ticker_max
    into cfg from app_config where id = 1;
  if not found then
    return jsonb_build_object('min', 4, 'events', '[]'::jsonb);
  end if;
  if not cfg.ticker_enabled then
    return jsonb_build_object('min', cfg.ticker_min, 'events', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(e order by (e->>'t') desc), '[]'::jsonb) into reales from (
    select e from (
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'operation', 'z', data->>'zone',
         'm2', data->>'sizeM2', 'ph', data->>'phName') e
       from properties
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'desiredOperation', 'z', data->>'desiredZone',
         'pres', data->>'maxBudget')
       from searches
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'vehiculo',
         'tipo', data->>'vehicleType', 'marca', data->>'brand', 'modelo', data->>'model', 'anio', data->>'year', 'z', data->>'zone')
       from vehicle_offers
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'vehiculo',
         'tipo', data->>'vehicleType', 'marca', data->>'desiredBrand', 'modelo', data->>'desiredModel', 'anio', data->>'minYear', 'z', data->>'zone')
       from vehicle_searches
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max)
    ) u(e)
    order by (e->>'t') desc
    limit cfg.ticker_max
  ) fin(e);

  select coalesce(jsonb_agg(jsonb_build_object(
      't', created_at, 'k', 'promo', 'txt', text_msg) order by created_at asc), '[]'::jsonb)
    into promos
    from (select created_at, text_msg from ticker_messages where active = true
          order by created_at asc limit 6) m;

  return jsonb_build_object('min', cfg.ticker_min, 'events', reales || promos);
end $$;
revoke execute on function public.public_ticker() from public;
grant execute on function public.public_ticker() to anon;
grant execute on function public.public_ticker() to authenticated;
