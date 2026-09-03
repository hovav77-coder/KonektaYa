-- ============================================================
-- 3l · Tablero: el admin puede OCULTAR publicaciones puntuales
--      de la portada (sin tocar la publicación del usuario)
-- ============================================================
-- Requiere haber corrido 3k. Decisión del dueño (opción A): en
-- Laboratorio → Cinta aparece "En el tablero ahora" con un interruptor
-- por fila. Ocultar solo quita la fila del tablero público; la
-- publicación sigue activa y haciendo match, y su dueño no ve cambio.
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

-- 1) La marca, por tabla (no se mete en el JSON del usuario).
alter table public.properties       add column if not exists ticker_hidden boolean not null default false;
alter table public.searches         add column if not exists ticker_hidden boolean not null default false;
alter table public.vehicle_offers   add column if not exists ticker_hidden boolean not null default false;
alter table public.vehicle_searches add column if not exists ticker_hidden boolean not null default false;

-- 2) Cambiar la marca (solo admin; tabla en lista blanca).
create or replace function public.admin_set_ticker_hidden(p_table text, p_id uuid, p_hidden boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  if p_table not in ('properties', 'searches', 'vehicle_offers', 'vehicle_searches') then
    raise exception 'Tabla no válida';
  end if;
  execute format('update public.%I set ticker_hidden = $1 where id = $2', p_table) using p_hidden, p_id;
end $$;
revoke execute on function public.admin_set_ticker_hidden(text, uuid, boolean) from public;
revoke execute on function public.admin_set_ticker_hidden(text, uuid, boolean) from anon;
grant execute on function public.admin_set_ticker_hidden(text, uuid, boolean) to authenticated;

-- 3) Lo que hay en la ventana del tablero, INCLUIDAS las ocultas (solo admin),
--    con id/tabla/estado para el interruptor. Mismos campos que public_ticker.
create or replace function public.admin_ticker_events()
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg record; salida jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select ticker_hours, ticker_max into cfg from app_config where id = 1;
  if not found then return jsonb_build_object('events', '[]'::jsonb); end if;
  select coalesce(jsonb_agg(e order by (e->>'t') desc), '[]'::jsonb) into salida from (
    select e from (
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'inmueble', 'id', id, 'tb', 'properties', 'hid', ticker_hidden,
         'tipo', data->>'propertyType', 'op', data->>'operation', 'z', data->>'zone',
         'm2', data->>'sizeM2', 'ph', data->>'phName', 'pv', data->>'salePrice', 'pa', data->>'rentalPrice') e
       from properties
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max * 2)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'inmueble', 'id', id, 'tb', 'searches', 'hid', ticker_hidden,
         'tipo', data->>'propertyType', 'op', data->>'desiredOperation', 'z', data->>'desiredZone',
         'pres', data->>'maxBudget',
         'lug', coalesce(nullif(trim(data->>'desiredPh'), ''), nullif(trim(data->>'desiredStreetOrNeighborhood'), '')))
       from searches
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max * 2)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'vehiculo', 'id', id, 'tb', 'vehicle_offers', 'hid', ticker_hidden,
         'tipo', data->>'vehicleType', 'marca', data->>'brand', 'modelo', data->>'model', 'anio', data->>'year', 'z', data->>'zone')
       from vehicle_offers
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max * 2)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'vehiculo', 'id', id, 'tb', 'vehicle_searches', 'hid', ticker_hidden,
         'tipo', data->>'vehicleType', 'marca', data->>'desiredBrand', 'modelo', data->>'desiredModel', 'anio', data->>'minYear', 'z', data->>'zone')
       from vehicle_searches
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max * 2)
    ) u(e)
    order by (e->>'t') desc
    limit cfg.ticker_max * 2
  ) fin(e);
  return jsonb_build_object('events', salida);
end $$;
revoke execute on function public.admin_ticker_events() from public;
revoke execute on function public.admin_ticker_events() from anon;
grant execute on function public.admin_ticker_events() to authenticated;

-- 4) El ticker público respeta la marca (idéntico a 3k + "and ticker_hidden = false").
create or replace function public.public_ticker()
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg record; reales jsonb; promos jsonb;
begin
  select ticker_enabled, ticker_hours, ticker_min, ticker_max, ticker_rows
    into cfg from app_config where id = 1;
  if not found then
    return jsonb_build_object('min', 4, 'rows', 4, 'events', '[]'::jsonb);
  end if;
  if not cfg.ticker_enabled then
    return jsonb_build_object('min', cfg.ticker_min, 'rows', cfg.ticker_rows, 'events', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(e order by (e->>'t') desc), '[]'::jsonb) into reales from (
    select e from (
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'operation', 'z', data->>'zone',
         'm2', data->>'sizeM2', 'ph', data->>'phName',
         'pv', data->>'salePrice', 'pa', data->>'rentalPrice') e
       from properties
       where active = true and owner_blocked = false and ticker_hidden = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'desiredOperation', 'z', data->>'desiredZone',
         'pres', data->>'maxBudget',
         'lug', coalesce(nullif(trim(data->>'desiredPh'), ''), nullif(trim(data->>'desiredStreetOrNeighborhood'), '')))
       from searches
       where active = true and owner_blocked = false and ticker_hidden = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'vehiculo',
         'tipo', data->>'vehicleType', 'marca', data->>'brand', 'modelo', data->>'model', 'anio', data->>'year', 'z', data->>'zone')
       from vehicle_offers
       where active = true and owner_blocked = false and ticker_hidden = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'vehiculo',
         'tipo', data->>'vehicleType', 'marca', data->>'desiredBrand', 'modelo', data->>'desiredModel', 'anio', data->>'minYear', 'z', data->>'zone')
       from vehicle_searches
       where active = true and owner_blocked = false and ticker_hidden = false
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

  return jsonb_build_object('min', cfg.ticker_min, 'rows', cfg.ticker_rows, 'events', reales || promos);
end $$;
revoke execute on function public.public_ticker() from public;
grant execute on function public.public_ticker() to anon;
grant execute on function public.public_ticker() to authenticated;
