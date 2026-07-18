-- ============================================================
-- KonektaYa · 2N · Ciclo del tope CONTROLADO POR EL SERVIDOR (seguridad #4)
-- Antes el "inicio de ciclo" salía de data.renewedAt/publishedAt (editable por
-- el dueño vía API) → congelarlo = pagar el tope una vez y desbloquear gratis
-- para siempre. Ahora el ciclo vive en una COLUMNA de servidor `cycle_start`
-- que el cliente NO puede fijar ni mover; solo la avanza el RPC de renovación.
-- Correr en Supabase → SQL Editor → Run. Idempotente y seguro de re-correr.
-- El ORDEN importa: rellenar ANTES de crear el trigger protector.
-- ============================================================

-- 0) Helper: cast seguro a timestamptz. Una fecha basura ISO-like ('2026-13-40',
--    '2026-07-18xx') NO debe abortar toda la migración: devuelve NULL y el
--    coalesce del relleno cae al siguiente candidato.
create or replace function public.konektaya_safe_ts(s text)
returns timestamptz
language plpgsql
immutable
set search_path = public
as $$
begin
  if s is null or btrim(s) = '' then return null; end if;
  return s::timestamptz;
exception when others then
  return null;
end $$;

-- 1) Columna cycle_start + relleno de filas existentes (aún SIN el trigger,
--    para que el UPDATE de relleno no sea interceptado).
do $$
declare t text;
begin
  foreach t in array array['properties','searches','vehicle_offers','vehicle_searches'] loop
    execute format('alter table public.%I add column if not exists cycle_start timestamptz;', t);
    -- Sembrar desde valores del servidor; si viene de data.* (editable), se acota
    -- con least(...,now()) para que NINGUNA fila herede un ciclo en el futuro.
    execute format($u$
      update public.%1$I set cycle_start = least(
        coalesce(
          public.konektaya_safe_ts(data->>'renewedAt'),
          public.konektaya_safe_ts(data->>'publishedAt'),
          created_at, now()),
        now())
      where cycle_start is null;$u$, t);
    execute format('alter table public.%I alter column cycle_start set default now();', t);
    execute format('alter table public.%I alter column cycle_start set not null;', t);
  end loop;
end $$;

-- 2) Trigger protector: el cliente NO puede fijar/mover cycle_start.
--    - INSERT: el ciclo de una publicación nueva SIEMPRE empieza ahora.
--    - UPDATE: se ignora cualquier cambio del cliente (se conserva el valor
--      anterior), salvo cuando el RPC de renovación habilita el flag de sesión.
create or replace function public.konektaya_protect_cycle_start()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    NEW.cycle_start := now();
  elsif TG_OP = 'UPDATE' then
    if coalesce(current_setting('konektaya.cycle_ok', true), '') <> '1' then
      NEW.cycle_start := OLD.cycle_start;
    end if;
  end if;
  return NEW;
end $$;

do $$
declare t text;
begin
  foreach t in array array['properties','searches','vehicle_offers','vehicle_searches'] loop
    execute format('drop trigger if exists trg_protect_cycle on public.%I;', t);
    execute format(
      'create trigger trg_protect_cycle before insert or update on public.%I
         for each row execute function public.konektaya_protect_cycle_start();', t);
  end loop;
end $$;

-- 3) RPC de renovación: solo el DUEÑO puede resetear el ciclo (cycle_start=now()).
--    Habilita el flag de sesión para poder mover cycle_start (el trigger lo exige)
--    y lo apaga al terminar. Reactiva la publicación (active=true).
create or replace function public.konektaya_renew_publication(p_table text, p_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare owner uuid; uid uuid; archived text; nowts timestamptz := now();
begin
  if p_table not in ('properties','searches','vehicle_offers','vehicle_searches') then
    raise exception 'Tabla no permitida';
  end if;
  uid := auth.uid();
  if uid is null then
    raise exception 'Debes iniciar sesión para renovar una publicación';
  end if;
  execute format('select owner_id, data->>''archived'' from public.%I where id = $1', p_table)
    into owner, archived using p_id;
  if owner is null then raise exception 'Publicación no encontrada'; end if;
  if owner is distinct from uid then
    raise exception 'Solo el dueño puede renovar su publicación';
  end if;
  -- No resucitar una publicación ARCHIVADA (2m la archiva cuando ya tuvo un
  -- desbloqueo pagado); renovarla la volvería a mostrar y desbloquear.
  if archived = 'true' then
    raise exception 'No se puede renovar una publicación archivada; crea una nueva.';
  end if;

  perform set_config('konektaya.cycle_ok', '1', true);   -- habilita mover cycle_start SOLO aquí
  execute format(
    'update public.%I
       set cycle_start = $1,
           active = true,
           data = jsonb_set(coalesce(data, ''{}''::jsonb), ''{renewedAt}'', to_jsonb($1::text)),
           updated_at = now()
     where id = $2', p_table) using nowts, p_id;
  perform set_config('konektaya.cycle_ok', '', true);    -- lo apaga

  return nowts;
end $$;

revoke execute on function public.konektaya_renew_publication(text, uuid) from public;
revoke execute on function public.konektaya_renew_publication(text, uuid) from anon;
grant  execute on function public.konektaya_renew_publication(text, uuid) to authenticated;

-- 4) Corrección para filas ya migradas por una versión anterior de este script:
--    acotar cualquier cycle_start FUTURO (heredado de un data.renewedAt manipulado)
--    a now(). Necesita el flag porque si no, el trigger protector revierte el cambio.
do $$
declare t text;
begin
  perform set_config('konektaya.cycle_ok', '1', true);
  foreach t in array array['properties','searches','vehicle_offers','vehicle_searches'] loop
    execute format('update public.%I set cycle_start = now() where cycle_start > now();', t);
  end loop;
  perform set_config('konektaya.cycle_ok', '', true);
end $$;

-- ============================================================
-- Verificación rápida (opcional, pégalo aparte tras correr lo de arriba):
--   -- (a) la columna existe y está llena:
--   select count(*) filter (where cycle_start is null) as nulos,
--          count(*) as total from public.properties;
--   -- (b) el cliente NO puede mover el ciclo (debe quedar igual tras el update):
--   --     (córrelo logueado como el dueño de una fila suya)
--   -- update public.properties set cycle_start = '2000-01-01' where id = '<tu-id>';
--   -- select cycle_start from public.properties where id = '<tu-id>';  -- NO cambió
-- ============================================================
