-- ============================================================
-- 3g · Tablero: filas visibles configurables (4 a 10)
-- ============================================================
-- Requiere haber corrido 3f (reemplaza su public_ticker y el setter de 3d).
--
-- Nuevo ajuste del admin: cuántos anuncios se ven a la vez en el tablero
-- de la portada (antes fijo en 4). Vive en app_config para que aplique a
-- todos los visitantes. El "Máximo" existente sigue siendo cuántos eventos
-- ROTAN; esto es cuántos se VEN a la vez.
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

alter table public.app_config
  add column if not exists ticker_rows integer not null default 4;

-- El setter gana p_rows (con default: los clientes viejos siguen funcionando
-- mientras Vercel termina de desplegar el nuevo).
drop function if exists public.admin_set_ticker_config(boolean, integer, integer, integer);
create or replace function public.admin_set_ticker_config(
  p_enabled boolean, p_hours integer, p_min integer, p_max integer, p_rows integer default 4
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  if p_hours not in (24, 48, 72, 168) then raise exception 'Ventana no válida'; end if;
  if p_min < 1 or p_min > 12 then raise exception 'Mínimo no válido (1–12)'; end if;
  if p_max < 4 or p_max > 20 then raise exception 'Máximo no válido (4–20)'; end if;
  if p_rows < 4 or p_rows > 10 then raise exception 'Filas visibles no válidas (4–10)'; end if;
  update public.app_config
     set ticker_enabled = p_enabled, ticker_hours = p_hours,
         ticker_min = p_min, ticker_max = p_max, ticker_rows = p_rows,
         updated_at = now()
   where id = 1;
end $$;
revoke execute on function public.admin_set_ticker_config(boolean, integer, integer, integer, integer) from public;
revoke execute on function public.admin_set_ticker_config(boolean, integer, integer, integer, integer) from anon;
grant execute on function public.admin_set_ticker_config(boolean, integer, integer, integer, integer) to authenticated;

-- La lista del admin incluye el ajuste nuevo.
create or replace function public.admin_ticker_list()
returns jsonb language plpgsql security definer set search_path = public as $$
declare salida jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select jsonb_build_object(
    'cfg', (select jsonb_build_object(
        'enabled', ticker_enabled, 'hours', ticker_hours,
        'min', ticker_min, 'max', ticker_max, 'rows', ticker_rows)
      from app_config where id = 1),
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'txt', text_msg, 'on', active, 't', created_at) order by created_at desc), '[]'::jsonb)
      from ticker_messages)
  ) into salida;
  return salida;
end $$;
revoke execute on function public.admin_ticker_list() from public;
revoke execute on function public.admin_ticker_list() from anon;
grant execute on function public.admin_ticker_list() to authenticated;

-- La cinta pública informa las filas visibles (v5: {min, rows, events}).
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

  return jsonb_build_object('min', cfg.ticker_min, 'rows', cfg.ticker_rows, 'events', reales || promos);
end $$;
revoke execute on function public.public_ticker() from public;
grant execute on function public.public_ticker() to anon;
grant execute on function public.public_ticker() to authenticated;
