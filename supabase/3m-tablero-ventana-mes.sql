-- ============================================================
-- 3m · Tablero: ventana ampliable a 2 semanas y a 1 mes (30 días)
-- ============================================================
-- Requiere haber corrido 3l. Pedido del dueño: con poco tráfico aún, la
-- ventana de "última semana" deja el tablero flaco; ampliar a último mes.
-- Cambia solo la validación del setter (acepta 336 h y 720 h) y deja la
-- ventana actual en 720 h (30 días) de una vez. Lo demás igual a 3g.
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

create or replace function public.admin_set_ticker_config(
  p_enabled boolean, p_hours integer, p_min integer, p_max integer, p_rows integer default 4
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  -- 24 h · 48 h · 72 h · 1 semana · 2 semanas · 1 mes
  if p_hours not in (24, 48, 72, 168, 336, 720) then raise exception 'Ventana no válida'; end if;
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

-- Ventana actual → último mes (30 días). Se puede volver a cambiar desde el admin.
update public.app_config set ticker_hours = 720, updated_at = now() where id = 1;
