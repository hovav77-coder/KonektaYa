-- ============================================================
-- KonektaYa · 2L · Blindaje SERVIDOR de campos libres (anti-contacto)
-- Rechaza guardar publicaciones cuyos campos de texto libre incluyan datos de
-- contacto (teléfono —incl. escrito en letras—, email, links, @usuario, redes).
-- Es la misma lógica del filtro del navegador, pero en la base de datos: aunque
-- alguien desactive JavaScript o use la API directa, NO puede saltarse el bloqueo.
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================

-- 1) Detector: ¿este texto contiene datos de contacto?
create or replace function public.konektaya_has_contact_info(raw text)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare t text; d text;
begin
  if raw is null or btrim(raw) = '' then return false; end if;
  t := lower(raw);
  -- Quitar acentos comunes (para que "teléfono" == "telefono").
  t := translate(t, 'áéíóúàèìòùäëïöüâêîôûñ', 'aeiouaeiouaeiouaeioun');

  -- Email (normal o deletreado), links y dominios.
  if t ~ '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' then return true; end if;
  if t ~ '(www\.|https?://|\.com|\.net|\.org|\.pa\y)' then return true; end if;
  if t ~ '[a-z0-9._%+-]+[[:space:]]+(at|arroba)[[:space:]]+[a-z0-9.-]+[[:space:]]+(dot|punto)[[:space:]]+[a-z]{2,}' then return true; end if;

  -- @usuario de red social (sin necesidad de dominio).
  if t ~ '(^|[[:space:].,;:])@[a-z0-9._]{2,}' then return true; end if;

  -- Palabras de contacto / redes / intención (ES + EN).
  if t ~ '(arroba|punto[[:space:]]*com|dot[[:space:]]*com|gmail|gmai|hotmail|outlook|yahoo|whatsapp|wasap|watsapp|telegram|instagram|messenger|signal|\yig\y|\ydm\y|\yinbox\y|correo|\yemail\y|celular|telefono|\ytel\y|contacto|contactame|llamame|llamenme|escribeme|call[[:space:]]me|text[[:space:]]me|txt[[:space:]]me|reach[[:space:]](me|out)|contact[[:space:]]me|message[[:space:]]me|dm[[:space:]]me|my[[:space:]](number|phone|cell|email)|hit[[:space:]]me[[:space:]]up)' then
    return true;
  end if;

  -- Convertir números escritos en letras (ES/EN) a dígitos.
  d := t;
  d := regexp_replace(d, '\y(cero|zero)\y',   '0', 'g');
  d := regexp_replace(d, '\y(uno|una|one)\y', '1', 'g');
  d := regexp_replace(d, '\y(dos|two)\y',     '2', 'g');
  d := regexp_replace(d, '\y(tres|three)\y',  '3', 'g');
  d := regexp_replace(d, '\y(cuatro|four)\y', '4', 'g');
  d := regexp_replace(d, '\y(cinco|five)\y',  '5', 'g');
  d := regexp_replace(d, '\y(seis|six)\y',    '6', 'g');
  d := regexp_replace(d, '\y(siete|seven)\y', '7', 'g');
  d := regexp_replace(d, '\y(ocho|eight)\y',  '8', 'g');
  d := regexp_replace(d, '\y(nueve|nine)\y',  '9', 'g');
  d := regexp_replace(d, '\y(oh)\y',          '0', 'g');

  -- Teléfono: 7+ dígitos seguidos, con o sin separadores.
  if d ~ '[0-9]([[:space:]().-]?[0-9]){6,}' then return true; end if;

  return false;
end $$;

-- 2) Trigger: revisa los campos de texto libre del JSONB 'data' antes de guardar.
create or replace function public.konektaya_block_contact_info()
returns trigger
language plpgsql
set search_path = public
as $$
declare k text; v text;
begin
  foreach k in array array[
    'streetOrNeighborhood','phName','desiredStreetOrNeighborhood','desiredPh',
    'brandOther','desiredBrandOther','modelOther','desiredModelOther',
    'colorOther','desiredColorOther','comments','vehicleComments','vehicleSearchComments'
  ] loop
    v := NEW.data ->> k;
    if v is not null and public.konektaya_has_contact_info(v) then
      raise exception 'CONTACTO_NO_PERMITIDO: el campo "%" no puede incluir datos de contacto (teléfono, email, redes o links).', k
        using errcode = 'check_violation';
    end if;
  end loop;
  return NEW;
end $$;

-- 3) Enganchar el trigger en las 4 tablas de publicaciones.
do $$
declare t text;
begin
  foreach t in array array['properties','searches','vehicle_offers','vehicle_searches'] loop
    execute format('drop trigger if exists trg_block_contact on public.%I;', t);
    execute format(
      'create trigger trg_block_contact before insert or update on public.%I
         for each row execute function public.konektaya_block_contact_info();', t);
  end loop;
end $$;
