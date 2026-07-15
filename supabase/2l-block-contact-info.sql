-- ============================================================
-- KonektaYa · 2L · Blindaje SERVIDOR de campos libres (anti-contacto)
-- Rechaza guardar publicaciones cuyos campos de texto libre incluyan datos de
-- contacto (teléfono —incl. escrito en letras, con decenas y troceado—, email,
-- links, @usuario, redes). Misma lógica del filtro del navegador, pero en la BD:
-- aunque desactiven JavaScript o usen la API directa, NO pueden saltarse el bloqueo.
-- Correr en Supabase → SQL Editor → Run. Idempotente (seguro re-correr).
-- ============================================================

-- La firma cambió (ahora lleva 'strict'); soltamos la versión vieja de 1 arg.
drop function if exists public.konektaya_has_contact_info(text);

-- 1) Detector. strict=true para campos de identidad (marca/modelo/color/PH/calle),
--    donde ≥4 grupos de números = teléfono troceado.
create or replace function public.konektaya_has_contact_info(raw text, strict boolean default false)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare t text; d text;
begin
  if raw is null or btrim(raw) = '' then return false; end if;
  t := lower(raw);
  t := translate(t, 'áéíóúàèìòùäëïöüâêîôûñ', 'aeiouaeiouaeiouaeioun');

  -- Email (normal o deletreado), links y dominios.
  if t ~ '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' then return true; end if;
  if t ~ '(www\.|https?://|\.com|\.net|\.org|\.pa\y)' then return true; end if;
  if t ~ '[a-z0-9._%+-]+[[:space:]]+(at|arroba)[[:space:]]+[a-z0-9.-]+[[:space:]]+(dot|punto)[[:space:]]+[a-z]{2,}' then return true; end if;

  -- @usuario de red social (sin dominio).
  if t ~ '(^|[[:space:].,;:])@[a-z0-9._]{2,}' then return true; end if;

  -- Palabras de contacto / redes / intención (ES + EN).
  if t ~ '(arroba|punto[[:space:]]*com|dot[[:space:]]*com|gmail|gmai|hotmail|outlook|yahoo|whatsapp|wasap|watsapp|telegram|instagram|messenger|signal|\yig\y|\ydm\y|\yinbox\y|correo|\yemail\y|celular|telefono|\ytel\y|contacto|contactame|llamame|llamenme|escribeme|call[[:space:]]me|text[[:space:]]me|txt[[:space:]]me|reach[[:space:]](me|out)|contact[[:space:]]me|message[[:space:]]me|dm[[:space:]]me|my[[:space:]](number|phone|cell|email)|hit[[:space:]]me[[:space:]]up)' then
    return true;
  end if;

  -- Convertir números escritos en letras (ES/EN, incl. teens y decenas) a dígitos.
  -- Los compuestos van primero (dieciseis antes que seis).
  d := t;
  d := regexp_replace(d, '\y(diecinueve)\y', '19', 'g');
  d := regexp_replace(d, '\y(dieciocho)\y',  '18', 'g');
  d := regexp_replace(d, '\y(diecisiete)\y', '17', 'g');
  d := regexp_replace(d, '\y(dieciseis)\y',  '16', 'g');
  d := regexp_replace(d, '\y(quince)\y',     '15', 'g');
  d := regexp_replace(d, '\y(catorce)\y',    '14', 'g');
  d := regexp_replace(d, '\y(trece)\y',      '13', 'g');
  d := regexp_replace(d, '\y(doce)\y',       '12', 'g');
  d := regexp_replace(d, '\y(once)\y',       '11', 'g');
  d := regexp_replace(d, '\y(diez)\y',       '10', 'g');
  d := regexp_replace(d, '\y(veinte)\y',     '20', 'g');
  d := regexp_replace(d, '\y(treinta)\y',    '30', 'g');
  d := regexp_replace(d, '\y(cuarenta)\y',   '40', 'g');
  d := regexp_replace(d, '\y(cincuenta)\y',  '50', 'g');
  d := regexp_replace(d, '\y(sesenta)\y',    '60', 'g');
  d := regexp_replace(d, '\y(setenta)\y',    '70', 'g');
  d := regexp_replace(d, '\y(ochenta)\y',    '80', 'g');
  d := regexp_replace(d, '\y(noventa)\y',    '90', 'g');
  d := regexp_replace(d, '\y(cien)\y',       '100', 'g');
  d := regexp_replace(d, '\y(nineteen)\y',   '19', 'g');
  d := regexp_replace(d, '\y(eighteen)\y',   '18', 'g');
  d := regexp_replace(d, '\y(seventeen)\y',  '17', 'g');
  d := regexp_replace(d, '\y(sixteen)\y',    '16', 'g');
  d := regexp_replace(d, '\y(fifteen)\y',    '15', 'g');
  d := regexp_replace(d, '\y(fourteen)\y',   '14', 'g');
  d := regexp_replace(d, '\y(thirteen)\y',   '13', 'g');
  d := regexp_replace(d, '\y(twelve)\y',     '12', 'g');
  d := regexp_replace(d, '\y(eleven)\y',     '11', 'g');
  d := regexp_replace(d, '\y(ten)\y',        '10', 'g');
  d := regexp_replace(d, '\y(twenty)\y',     '20', 'g');
  d := regexp_replace(d, '\y(thirty)\y',     '30', 'g');
  d := regexp_replace(d, '\y(forty)\y',      '40', 'g');
  d := regexp_replace(d, '\y(fifty)\y',      '50', 'g');
  d := regexp_replace(d, '\y(sixty)\y',      '60', 'g');
  d := regexp_replace(d, '\y(seventy)\y',    '70', 'g');
  d := regexp_replace(d, '\y(eighty)\y',     '80', 'g');
  d := regexp_replace(d, '\y(ninety)\y',     '90', 'g');
  d := regexp_replace(d, '\y(hundred)\y',    '100', 'g');
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

  -- Teléfono: 7+ dígitos seguidos (con o sin separadores).
  if d ~ '[0-9]([[:space:]().-]?[0-9]){6,}' then return true; end if;

  -- En campos de identidad: ≥4 grupos de números = teléfono troceado con palabras.
  if strict and (select count(*) from regexp_matches(d, '[0-9]+', 'g')) >= 4 then
    return true;
  end if;

  return false;
end $$;

-- 2) Trigger: revisa los campos de texto libre del JSONB 'data' antes de guardar.
create or replace function public.konektaya_block_contact_info()
returns trigger
language plpgsql
set search_path = public
as $$
declare k text; v text; es_comentario boolean;
begin
  foreach k in array array[
    'streetOrNeighborhood','phName','desiredStreetOrNeighborhood','desiredPh',
    'brandOther','desiredBrandOther','modelOther','desiredModelOther',
    'colorOther','desiredColorOther','comments','vehicleComments','vehicleSearchComments'
  ] loop
    v := NEW.data ->> k;
    es_comentario := (lower(k) like '%comment%');
    if v is not null and public.konektaya_has_contact_info(v, not es_comentario) then
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
