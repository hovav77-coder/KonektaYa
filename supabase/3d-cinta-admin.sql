-- ============================================================
-- 3d · Administración de la cinta EN VIVO desde el Laboratorio
-- ============================================================
-- Requiere haber corrido 2v (app_config) y 3c (public_ticker sin admins).
--
-- El admin controla la cinta de la portada sin tocar código:
--   · interruptor encendida/apagada (se apaga en el SERVIDOR)
--   · ventana de horas, mínimo para mostrarse y máximo de eventos
--   · mensajes propios 📣 (se mezclan con la actividad real y cuentan
--     para el mínimo — resuelven el arranque en frío del lanzamiento)
--
-- OJO: public_ticker cambia su respuesta de lista a objeto
-- {min, events:[...]} — el index.html publicado junto con este SQL ya
-- entiende ambos formatos.
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

-- ---------- Configuración ----------
alter table public.app_config
  add column if not exists ticker_enabled boolean not null default true,
  add column if not exists ticker_hours integer not null default 48,
  add column if not exists ticker_min integer not null default 4,
  add column if not exists ticker_max integer not null default 12;

-- ---------- Mensajes propios ----------
create table if not exists public.ticker_messages (
  id uuid primary key default gen_random_uuid(),
  text_msg text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.ticker_messages enable row level security;
revoke all on public.ticker_messages from anon;
revoke all on public.ticker_messages from authenticated;

-- ---------- RPCs del admin ----------
create or replace function public.admin_set_ticker_config(
  p_enabled boolean, p_hours integer, p_min integer, p_max integer
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  if p_hours not in (24, 48, 72, 168) then raise exception 'Ventana no válida'; end if;
  if p_min < 1 or p_min > 12 then raise exception 'Mínimo no válido (1–12)'; end if;
  if p_max < 4 or p_max > 20 then raise exception 'Máximo no válido (4–20)'; end if;
  update public.app_config
     set ticker_enabled = p_enabled, ticker_hours = p_hours,
         ticker_min = p_min, ticker_max = p_max, updated_at = now()
   where id = 1;
end $$;
revoke execute on function public.admin_set_ticker_config(boolean, integer, integer, integer) from public;
revoke execute on function public.admin_set_ticker_config(boolean, integer, integer, integer) from anon;
grant execute on function public.admin_set_ticker_config(boolean, integer, integer, integer) to authenticated;

create or replace function public.admin_ticker_add(p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare limpio text;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  limpio := btrim(coalesce(p_text, ''));
  if length(limpio) < 5 then raise exception 'El mensaje es muy corto (mínimo 5 letras)'; end if;
  if length(limpio) > 140 then raise exception 'El mensaje es muy largo (máximo 140 letras)'; end if;
  if (select count(*) from ticker_messages) >= 10 then
    raise exception 'Ya hay 10 mensajes: borra alguno antes de agregar otro';
  end if;
  insert into ticker_messages (text_msg) values (limpio);
end $$;
revoke execute on function public.admin_ticker_add(text) from public;
revoke execute on function public.admin_ticker_add(text) from anon;
grant execute on function public.admin_ticker_add(text) to authenticated;

create or replace function public.admin_ticker_toggle(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  update ticker_messages set active = p_active where id = p_id;
end $$;
revoke execute on function public.admin_ticker_toggle(uuid, boolean) from public;
revoke execute on function public.admin_ticker_toggle(uuid, boolean) from anon;
grant execute on function public.admin_ticker_toggle(uuid, boolean) to authenticated;

create or replace function public.admin_ticker_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  delete from ticker_messages where id = p_id;
end $$;
revoke execute on function public.admin_ticker_delete(uuid) from public;
revoke execute on function public.admin_ticker_delete(uuid) from anon;
grant execute on function public.admin_ticker_delete(uuid) to authenticated;

-- Todo lo que la tarjeta del Laboratorio necesita, en una sola llamada.
create or replace function public.admin_ticker_list()
returns jsonb language plpgsql security definer set search_path = public as $$
declare salida jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select jsonb_build_object(
    'cfg', (select jsonb_build_object(
        'enabled', ticker_enabled, 'hours', ticker_hours,
        'min', ticker_min, 'max', ticker_max)
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

-- ---------- Cinta pública (reemplaza a la de 3c) ----------
-- Ahora devuelve {min, events}: si está apagada, events = [] (nadie la ve).
-- Los mensajes propios activos van como eventos k='promo' (máx. 6) y las
-- publicaciones reales llenan hasta ticker_max dentro de ticker_hours.
create or replace function public.public_ticker()
returns jsonb language plpgsql security definer set search_path = public as $$
declare cfg record; reales jsonb; promos jsonb;
begin
  select ticker_enabled, ticker_hours, ticker_min, ticker_max
    into cfg from app_config where id = 1;
  if not found then
    -- sin fila de configuración no hay cinta (a prueba de fallos)
    return jsonb_build_object('min', 4, 'events', '[]'::jsonb);
  end if;
  if not cfg.ticker_enabled then
    return jsonb_build_object('min', cfg.ticker_min, 'events', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(e order by (e->>'t') desc), '[]'::jsonb) into reales from (
    select e from (
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'operation', 'z', data->>'zone') e
       from properties
       where active = true and owner_blocked = false
         and created_at > now() - make_interval(hours => cfg.ticker_hours)
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit cfg.ticker_max)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'desiredOperation', 'z', data->>'desiredZone')
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
         'tipo', data->>'vehicleType', 'marca', data->>'desiredBrand', 'modelo', data->>'desiredModel', 'z', data->>'zone')
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
