-- ============================================================
-- 2x · Analítica del admin: RPC admin_metrics()
-- ============================================================
-- El admin en el navegador NO puede leer unlocks/paypal_orders/
-- match_notifications de otros usuarios (RLS *_select_own, a propósito).
-- Este RPC (SECURITY DEFINER + is_admin, mismo patrón de 2i) devuelve los
-- AGREGADOS de toda la plataforma en un solo JSON para la estación
-- "Analítica" del panel. Sin datos sensibles: nada de emails ni teléfonos.
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

-- Funnel de actividad por ventana de días (null = todo el tiempo).
-- "Actividad del periodo", no cohorte estricta: usuarios registrados,
-- usuarios que publicaron, usuarios avisados de match (proxy: emails de
-- match_notifications — subcuenta), usuarios que desbloquearon y repetidores.
create or replace function public._ky_funnel(p_days int)
returns jsonb language sql security definer set search_path = public as $$
  with corte as (select case when p_days is null then '-infinity'::timestamptz else now() - make_interval(days => p_days) end t)
  select jsonb_build_object(
    'registrados', (select count(*) from profiles, corte where created_at >= corte.t),
    'con_publicacion', (
      select count(distinct owner_id) from (
        select owner_id, created_at from properties
        union all select owner_id, created_at from searches
        union all select owner_id, created_at from vehicle_offers
        union all select owner_id, created_at from vehicle_searches
      ) p, corte where p.created_at >= corte.t
    ),
    'con_aviso_match', (select count(distinct recipient_id) from match_notifications, corte where created_at >= corte.t),
    'con_desbloqueo', (select count(distinct unlocker_id) from unlocks, corte where created_at >= corte.t),
    'repite', (select count(*) from (
        select unlocker_id from unlocks, corte where created_at >= corte.t group by unlocker_id having count(*) >= 2
      ) r)
  );
$$;
revoke execute on function public._ky_funnel(int) from public;
revoke execute on function public._ky_funnel(int) from anon;
revoke execute on function public._ky_funnel(int) from authenticated;

create or replace function public.admin_metrics()
returns jsonb language plpgsql security definer set search_path = public as $$
declare salida jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select jsonb_build_object(
    'generated_at', now(),

    'registros_all', (select count(*) from profiles),
    'registros_daily', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d), '[]'::jsonb)
      from (select created_at::date d, count(*) n from profiles where created_at > now() - interval '120 days' group by 1) t),

    'unlocks_all', jsonb_build_object(
      'n', (select count(*) from unlocks),
      'amt', (select coalesce(sum(price), 0) from unlocks)),
    'unlocks_list', (select coalesce(jsonb_agg(jsonb_build_object('t', created_at, 'v', vertical, 'o', offer_id, 'p', price) order by created_at desc), '[]'::jsonb)
      from (select created_at, vertical, offer_id, price from unlocks order by created_at desc limit 500) u),

    'paypal_all', jsonb_build_object(
      'n', (select count(*) from paypal_orders where status = 'credited'),
      'amt', (select coalesce(sum(amount), 0) from paypal_orders where status = 'credited')),
    'paypal_daily', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n, 'amt', amt) order by d), '[]'::jsonb)
      from (select created_at::date d, count(*) n, sum(amount) amt from paypal_orders
            where status = 'credited' and created_at > now() - interval '120 days' group by 1) t),

    'coupons_all', jsonb_build_object(
      'n', (select count(*) from coupon_redemptions),
      'amt', (select coalesce(sum(amount), 0) from coupon_redemptions)),

    'wallets_total', (select coalesce(sum(balance), 0) from wallets),

    'notif_list', (select coalesce(jsonb_agg(jsonb_build_object('t', created_at, 'v', vertical, 'pub', publication_id) order by created_at desc), '[]'::jsonb)
      from (select created_at, vertical, publication_id from match_notifications order by created_at desc limit 1000) m),

    'funnel', jsonb_build_object(
      'p7',  public._ky_funnel(7),
      'p30', public._ky_funnel(30),
      'p90', public._ky_funnel(90),
      'all', public._ky_funnel(null)),

    'recent', (select coalesce(jsonb_agg(e order by (e->>'t') desc), '[]'::jsonb) from (
        (select jsonb_build_object('t', created_at, 'k', 'unlock', 'v', vertical, 'p', price) e
           from unlocks order by created_at desc limit 8)
        union all
        (select jsonb_build_object('t', created_at, 'k', 'registro', 'r', coalesce(role, ''))
           from profiles order by created_at desc limit 8)
        union all
        (select jsonb_build_object('t', created_at, 'k', 'pago', 'amt', amount)
           from paypal_orders where status = 'credited' order by created_at desc limit 5)
        union all
        (select jsonb_build_object('t', created_at, 'k', 'cupon', 'amt', amount, 'c', coupon_code)
           from coupon_redemptions order by created_at desc limit 5)
        union all
        (select jsonb_build_object('t', created_at, 'k', 'aviso', 'v', vertical, 'm', matched_count)
           from match_notifications order by created_at desc limit 8)
        union all
        (select jsonb_build_object('t', p.created_at, 'k', 'pub', 'v', p.v, 'lado', p.lado, 'z', p.z) from (
          (select created_at, 'inmueble'::text v, 'oferta'::text lado, data->>'zone' z from properties order by created_at desc limit 4)
          union all (select created_at, 'inmueble', 'busqueda', data->>'desiredZone' from searches order by created_at desc limit 4)
          union all (select created_at, 'vehiculo', 'oferta', data->>'zone' from vehicle_offers order by created_at desc limit 4)
          union all (select created_at, 'vehiculo', 'busqueda', data->>'zone' from vehicle_searches order by created_at desc limit 4)
        ) p)
      ) ev(e))
  ) into salida;
  return salida;
end $$;
revoke execute on function public.admin_metrics() from public;
revoke execute on function public.admin_metrics() from anon;
grant execute on function public.admin_metrics() to authenticated;
