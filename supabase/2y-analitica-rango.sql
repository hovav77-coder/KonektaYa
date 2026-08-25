-- ============================================================
-- 2y · Analítica: funnel por rango de fechas (y último día)
-- ============================================================
-- Complemento de 2x: la estación Analítica gana el periodo "1d" y el
-- selector de rango libre (desde → hasta). Los presets 7/30/90/Todo siguen
-- saliendo de admin_metrics(); este RPC calcula el funnel para CUALQUIER
-- ventana que pida el admin. Mismo candado is_admin, sin datos sensibles.
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

create or replace function public.admin_metrics_funnel(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare salida jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select jsonb_build_object(
    'registrados', (select count(*) from profiles where created_at >= p_from and created_at <= p_to),
    'con_publicacion', (
      select count(distinct owner_id) from (
        select owner_id, created_at from properties
        union all select owner_id, created_at from searches
        union all select owner_id, created_at from vehicle_offers
        union all select owner_id, created_at from vehicle_searches
      ) p where p.created_at >= p_from and p.created_at <= p_to
    ),
    'con_aviso_match', (select count(distinct recipient_id) from match_notifications where created_at >= p_from and created_at <= p_to),
    'con_desbloqueo', (select count(distinct unlocker_id) from unlocks where created_at >= p_from and created_at <= p_to),
    'repite', (select count(*) from (
        select unlocker_id from unlocks where created_at >= p_from and created_at <= p_to
        group by unlocker_id having count(*) >= 2
      ) r)
  ) into salida;
  return salida;
end $$;
revoke execute on function public.admin_metrics_funnel(timestamptz, timestamptz) from public;
revoke execute on function public.admin_metrics_funnel(timestamptz, timestamptz) from anon;
grant execute on function public.admin_metrics_funnel(timestamptz, timestamptz) to authenticated;
