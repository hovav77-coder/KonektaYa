-- ============================================================
-- 3c · La analítica no te cuenta a ti: excluir cuentas admin
-- ============================================================
-- Requiere haber corrido 2x, 2y y 2z (reemplaza sus funciones).
--
-- Las cuentas admin (las mismas de is_admin: hovav@saidacpa.com y
-- asistencia.gerencia@saidacpa.com) dejan de contar en TODA la analítica:
-- funnel, registros, desbloqueos, pagos, cupones, billeteras, avisos y el
-- pulso en vivo — y sus publicaciones tampoco salen en la cinta EN VIVO de
-- la portada. El tablero mide el negocio, no al dueño.
-- (La cuenta broker hovav.saida@imrsa.com NO es admin: esa sí cuenta,
--  porque representa actividad real del mercado.)
--
-- OJO: si algún día cambian los correos de admin, hay que actualizarlos
-- en DOS lugares: is_admin() (2d) y _ky_admin_uids() (aquí).
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

-- Fuente única de los uid de admin (uso interno de las funciones definer)
create or replace function public._ky_admin_uids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from profiles
  where email in ('hovav@saidacpa.com', 'asistencia.gerencia@saidacpa.com');
$$;
revoke execute on function public._ky_admin_uids() from public;
revoke execute on function public._ky_admin_uids() from anon;
revoke execute on function public._ky_admin_uids() from authenticated;

-- ---------- Funnel por ventana de días (reemplaza al de 2x) ----------
create or replace function public._ky_funnel(p_days int)
returns jsonb language sql security definer set search_path = public as $$
  with corte as (select case when p_days is null then '-infinity'::timestamptz else now() - make_interval(days => p_days) end t)
  select jsonb_build_object(
    'registrados', (select count(*) from profiles, corte
      where created_at >= corte.t and id not in (select public._ky_admin_uids())),
    'con_publicacion', (
      select count(distinct owner_id) from (
        select owner_id, created_at from properties
        union all select owner_id, created_at from searches
        union all select owner_id, created_at from vehicle_offers
        union all select owner_id, created_at from vehicle_searches
      ) p, corte
      where p.created_at >= corte.t and p.owner_id not in (select public._ky_admin_uids())
    ),
    'con_aviso_match', (select count(distinct recipient_id) from match_notifications, corte
      where created_at >= corte.t and recipient_id not in (select public._ky_admin_uids())),
    'con_desbloqueo', (select count(distinct unlocker_id) from unlocks, corte
      where created_at >= corte.t and unlocker_id not in (select public._ky_admin_uids())),
    'repite', (select count(*) from (
        select unlocker_id from unlocks, corte
        where created_at >= corte.t and unlocker_id not in (select public._ky_admin_uids())
        group by unlocker_id having count(*) >= 2
      ) r)
  );
$$;
revoke execute on function public._ky_funnel(int) from public;
revoke execute on function public._ky_funnel(int) from anon;
revoke execute on function public._ky_funnel(int) from authenticated;

-- ---------- Funnel por rango libre (reemplaza al de 2y) ----------
create or replace function public.admin_metrics_funnel(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare salida jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select jsonb_build_object(
    'registrados', (select count(*) from profiles
      where created_at >= p_from and created_at <= p_to and id not in (select public._ky_admin_uids())),
    'con_publicacion', (
      select count(distinct owner_id) from (
        select owner_id, created_at from properties
        union all select owner_id, created_at from searches
        union all select owner_id, created_at from vehicle_offers
        union all select owner_id, created_at from vehicle_searches
      ) p where p.created_at >= p_from and p.created_at <= p_to
        and p.owner_id not in (select public._ky_admin_uids())
    ),
    'con_aviso_match', (select count(distinct recipient_id) from match_notifications
      where created_at >= p_from and created_at <= p_to and recipient_id not in (select public._ky_admin_uids())),
    'con_desbloqueo', (select count(distinct unlocker_id) from unlocks
      where created_at >= p_from and created_at <= p_to and unlocker_id not in (select public._ky_admin_uids())),
    'repite', (select count(*) from (
        select unlocker_id from unlocks
        where created_at >= p_from and created_at <= p_to and unlocker_id not in (select public._ky_admin_uids())
        group by unlocker_id having count(*) >= 2
      ) r)
  ) into salida;
  return salida;
end $$;
revoke execute on function public.admin_metrics_funnel(timestamptz, timestamptz) from public;
revoke execute on function public.admin_metrics_funnel(timestamptz, timestamptz) from anon;
grant execute on function public.admin_metrics_funnel(timestamptz, timestamptz) to authenticated;

-- ---------- Métricas completas (reemplaza a la de 2z) ----------
create or replace function public.admin_metrics()
returns jsonb language plpgsql security definer set search_path = public as $$
declare salida jsonb;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  select jsonb_build_object(
    'generated_at', now(),

    'registros_all', (select count(*) from profiles where id not in (select public._ky_admin_uids())),
    'registros_daily', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d), '[]'::jsonb)
      from (select created_at::date d, count(*) n from profiles
            where created_at > now() - interval '120 days' and id not in (select public._ky_admin_uids())
            group by 1) t),

    'visits_daily', (select coalesce(jsonb_agg(jsonb_build_object('d', day, 'n', visits, 'u', uniques) order by day), '[]'::jsonb)
      from visit_days),

    'unlocks_all', jsonb_build_object(
      'n', (select count(*) from unlocks where unlocker_id not in (select public._ky_admin_uids())),
      'amt', (select coalesce(sum(price), 0) from unlocks where unlocker_id not in (select public._ky_admin_uids()))),
    'unlocks_list', (select coalesce(jsonb_agg(jsonb_build_object('t', created_at, 'v', vertical, 'o', offer_id, 'p', price) order by created_at desc), '[]'::jsonb)
      from (select created_at, vertical, offer_id, price from unlocks
            where unlocker_id not in (select public._ky_admin_uids())
            order by created_at desc limit 500) u),

    'paypal_all', jsonb_build_object(
      'n', (select count(*) from paypal_orders where status = 'credited' and user_id not in (select public._ky_admin_uids())),
      'amt', (select coalesce(sum(amount), 0) from paypal_orders where status = 'credited' and user_id not in (select public._ky_admin_uids()))),
    'paypal_daily', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n, 'amt', amt) order by d), '[]'::jsonb)
      from (select created_at::date d, count(*) n, sum(amount) amt from paypal_orders
            where status = 'credited' and created_at > now() - interval '120 days'
              and user_id not in (select public._ky_admin_uids())
            group by 1) t),

    'coupons_all', jsonb_build_object(
      'n', (select count(*) from coupon_redemptions where user_id not in (select public._ky_admin_uids())),
      'amt', (select coalesce(sum(amount), 0) from coupon_redemptions where user_id not in (select public._ky_admin_uids()))),

    'wallets_total', (select coalesce(sum(balance), 0) from wallets where user_id not in (select public._ky_admin_uids())),

    'notif_list', (select coalesce(jsonb_agg(jsonb_build_object('t', created_at, 'v', vertical, 'pub', publication_id) order by created_at desc), '[]'::jsonb)
      from (select created_at, vertical, publication_id from match_notifications
            where recipient_id not in (select public._ky_admin_uids())
            order by created_at desc limit 1000) m),

    'funnel', jsonb_build_object(
      'p7',  public._ky_funnel(7),
      'p30', public._ky_funnel(30),
      'p90', public._ky_funnel(90),
      'all', public._ky_funnel(null)),

    'recent', (select coalesce(jsonb_agg(e order by (e->>'t') desc), '[]'::jsonb) from (
        (select jsonb_build_object('t', created_at, 'k', 'unlock', 'v', vertical, 'p', price) e
           from unlocks where unlocker_id not in (select public._ky_admin_uids())
           order by created_at desc limit 8)
        union all
        (select jsonb_build_object('t', created_at, 'k', 'registro', 'r', coalesce(role, ''))
           from profiles where id not in (select public._ky_admin_uids())
           order by created_at desc limit 8)
        union all
        (select jsonb_build_object('t', created_at, 'k', 'pago', 'amt', amount)
           from paypal_orders where status = 'credited' and user_id not in (select public._ky_admin_uids())
           order by created_at desc limit 5)
        union all
        (select jsonb_build_object('t', created_at, 'k', 'cupon', 'amt', amount, 'c', coupon_code)
           from coupon_redemptions where user_id not in (select public._ky_admin_uids())
           order by created_at desc limit 5)
        union all
        (select jsonb_build_object('t', created_at, 'k', 'aviso', 'v', vertical, 'm', matched_count)
           from match_notifications where recipient_id not in (select public._ky_admin_uids())
           order by created_at desc limit 8)
        union all
        (select jsonb_build_object('t', p.created_at, 'k', 'pub', 'v', p.v, 'lado', p.lado, 'z', p.z) from (
          (select created_at, 'inmueble'::text v, 'oferta'::text lado, data->>'zone' z from properties
             where owner_id not in (select public._ky_admin_uids()) order by created_at desc limit 4)
          union all (select created_at, 'inmueble', 'busqueda', data->>'desiredZone' from searches
             where owner_id not in (select public._ky_admin_uids()) order by created_at desc limit 4)
          union all (select created_at, 'vehiculo', 'oferta', data->>'zone' from vehicle_offers
             where owner_id not in (select public._ky_admin_uids()) order by created_at desc limit 4)
          union all (select created_at, 'vehiculo', 'busqueda', data->>'zone' from vehicle_searches
             where owner_id not in (select public._ky_admin_uids()) order by created_at desc limit 4)
        ) p)
      ) ev(e))
  ) into salida;
  return salida;
end $$;
revoke execute on function public.admin_metrics() from public;
revoke execute on function public.admin_metrics() from anon;
grant execute on function public.admin_metrics() to authenticated;

-- ---------- Cinta EN VIVO de la portada (reemplaza a la de 3a) ----------
create or replace function public.public_ticker()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(e order by (e->>'t') desc), '[]'::jsonb) from (
    select e from (
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'operation', 'z', data->>'zone') e
       from properties
       where active = true and owner_blocked = false and created_at > now() - interval '48 hours'
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit 12)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'inmueble',
         'tipo', data->>'propertyType', 'op', data->>'desiredOperation', 'z', data->>'desiredZone')
       from searches
       where active = true and owner_blocked = false and created_at > now() - interval '48 hours'
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit 12)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'oferta', 'v', 'vehiculo',
         'tipo', data->>'vehicleType', 'marca', data->>'brand', 'modelo', data->>'model', 'anio', data->>'year', 'z', data->>'zone')
       from vehicle_offers
       where active = true and owner_blocked = false and created_at > now() - interval '48 hours'
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit 12)
      union all
      (select jsonb_build_object('t', created_at, 'k', 'busqueda', 'v', 'vehiculo',
         'tipo', data->>'vehicleType', 'marca', data->>'desiredBrand', 'modelo', data->>'desiredModel', 'z', data->>'zone')
       from vehicle_searches
       where active = true and owner_blocked = false and created_at > now() - interval '48 hours'
         and owner_id not in (select public._ky_admin_uids())
       order by created_at desc limit 12)
    ) u(e)
    order by (e->>'t') desc
    limit 12
  ) fin(e);
$$;
revoke execute on function public.public_ticker() from public;
grant execute on function public.public_ticker() to anon;
grant execute on function public.public_ticker() to authenticated;
