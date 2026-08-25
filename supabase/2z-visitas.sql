-- ============================================================
-- 2z · Contador de visitas propio (para la estación Analítica)
-- ============================================================
-- Requiere haber corrido 2x (usa su admin_metrics como base).
--
-- Un contador por DÍA: visitas (cada entrada a la página) y visitantes
-- únicos (cada navegador cuenta una vez por día, marcado en localStorage).
-- Sin IP, sin identidad, sin cookies de rastreo: solo números agregados.
-- La página llama track_visit() al cargar; el admin lo ve en la Analítica
-- (etapa VISITARON del funnel + serie Visitas en la tendencia).
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

create table if not exists public.visit_days (
  day date primary key,
  visits integer not null default 0,
  uniques integer not null default 0
);
alter table public.visit_days enable row level security;
revoke all on public.visit_days from anon;
revoke all on public.visit_days from authenticated;

-- Ping anónimo: suma 1 visita al día de hoy (y 1 único si el navegador
-- no había entrado hoy). SECURITY DEFINER: nadie lee ni toca la tabla
-- directamente, solo puede sumar.
create or replace function public.track_visit(p_unique boolean default false)
returns void language sql security definer set search_path = public as $$
  insert into visit_days as v (day, visits, uniques)
  values (current_date, 1, case when p_unique then 1 else 0 end)
  on conflict (day) do update
    set visits = v.visits + 1,
        uniques = v.uniques + (case when p_unique then 1 else 0 end);
$$;
revoke execute on function public.track_visit(boolean) from public;
grant execute on function public.track_visit(boolean) to anon;
grant execute on function public.track_visit(boolean) to authenticated;

-- admin_metrics ampliado: igual que en 2x + 'visits_daily' (todos los días
-- del contador; son ~365 filas por año, sin límite necesario).
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

    'visits_daily', (select coalesce(jsonb_agg(jsonb_build_object('d', day, 'n', visits, 'u', uniques) order by day), '[]'::jsonb)
      from visit_days),

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
