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
declare t text; d text; tok text; g text; i int;
  pares text[] := array[
    'diecinueve','19','dieciocho','18','diecisiete','17','dieciseis','16',
    'nineteen','19','eighteen','18','seventeen','17','fourteen','14','thirteen','13',
    'diez','10','once','11','doce','12','trece','13','catorce','14','quince','15','sixteen','16','fifteen','15','twelve','12','eleven','11',
    'veinte','20','treinta','30','cuarenta','40','cincuenta','50','sesenta','60','setenta','70','ochenta','80','noventa','90','cien','100',
    'twenty','20','thirty','30','forty','40','fifty','50','sixty','60','seventy','70','eighty','80','ninety','90','hundred','100','ten','10',
    'cero','0','uno','1','una','1','dos','2','tres','3','cuatro','4','cinco','5','seis','6','siete','7','ocho','8','nueve','9',
    'zero','0','one','1','two','2','three','3','four','4','five','5','six','6','seven','7','eight','8','nine','9','oh','0'
  ];
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

  -- Números PEGADOS a letras en un mismo token ("615019nuevenueve"): por cada
  -- palabra, quitar lo no alfanumérico, convertir palabras-número (aunque estén
  -- pegadas, de más larga a más corta) y buscar 7+ dígitos seguidos.
  foreach tok in array regexp_split_to_array(t, '[[:space:]]+') loop
    g := regexp_replace(tok, '[^a-z0-9]', '', 'g');
    if g <> '' then
      i := 1;
      while i <= array_length(pares, 1) loop
        g := replace(g, pares[i], pares[i + 1]);
        i := i + 2;
      end loop;
      if g ~ '[0-9]{7,}' then return true; end if;
    end if;
  end loop;

  return false;
end $$;

-- 2) Trigger: revisa TODOS los valores del JSONB 'data' antes de guardar
--    (no una lista fija de claves). Así, aunque por la API metan el teléfono en
--    una clave inventada/no listada, se detecta. Se SALTAN solo las claves
--    numéricas/estructurales legítimas (precios, medidas, años, conteos,
--    coordenadas, place_id, fechas, ids) para no bloquear publicaciones válidas.
create or replace function public.konektaya_block_contact_info()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  k text; v text; es_comentario boolean;
  -- Claves numéricas / de sistema que NO se escanean (su valor es un número,
  -- coordenada, place_id o fecha; un teléfono de 7-8 dígitos y un precio de
  -- 7-8 dígitos son indistinguibles por forma, así que se separan por clave).
  skip text[] := array[
    'saleprice','rentalprice','maxbudget','price',
    'sizem2','minsizem2','desiredsizem2','landsizem2','hectares','hectareas',
    'parkingspaces','desiredparkingspaces','bedrooms','bathrooms','desiredbedrooms','desiredbathrooms',
    'year','minyear','desiredyear','mileage','maxmileage',
    'streetlat','streetlng','desiredstreetlat','desiredstreetlng',
    'streetplaceid','desiredstreetplaceid',
    'publishedat','renewedat','createdat','updatedat','unlockedat',
    'id','ownerid','active','archived','cappedfree','fullprice'
  ];
begin
  if NEW.data is null then return NEW; end if;
  for k, v in select key, value from jsonb_each_text(NEW.data) loop
    if v is null or btrim(v) = '' then continue; end if;
    if lower(k) = any(skip) then continue; end if;
    -- Timestamps ISO (2026-07-18T...) : seguros, se saltan.
    if v ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[t ]' then continue; end if;
    es_comentario := (lower(k) like '%comment%');
    if public.konektaya_has_contact_info(v, not es_comentario) then
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
