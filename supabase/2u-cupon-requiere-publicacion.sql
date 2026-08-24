-- ============================================================
-- 2u · Canjear cupón REQUIERE tener al menos una publicación
-- ============================================================
-- Idea del dueño (promo BIENVENIDO10): el cupón se canjea cuando el usuario
-- ya publicó algo, no solo por registrarse. La regla vive AQUÍ (servidor)
-- porque cualquier validación solo en la página se puede brincar.
--
-- Regla GLOBAL para cupones de crédito: coherente, porque el crédito solo lo
-- gasta quien publica (el que busca no paga). Si algún día se quiere un cupón
-- "solo por registrarte", se agrega una bandera por cupón — no antes.
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo este archivo → Run.
-- Es idempotente (CREATE OR REPLACE): correrlo dos veces no daña nada.

create or replace function public.redeem_coupon(p_code text)
returns numeric language plpgsql security definer set search_path = public as $$
declare c record; uid uuid := auth.uid(); newbal numeric;
begin
  if uid is null then raise exception 'Inicia sesión para canjear un cupón'; end if;

  -- NUEVO: exigir al menos una publicación ACTIVA (oferta o búsqueda, de
  -- inmuebles o vehículos) antes de acreditar el regalo.
  if not (
    exists (select 1 from public.properties       where owner_id = uid and active is not false)
    or exists (select 1 from public.searches         where owner_id = uid and active is not false)
    or exists (select 1 from public.vehicle_offers   where owner_id = uid and active is not false)
    or exists (select 1 from public.vehicle_searches where owner_id = uid and active is not false)
  ) then
    raise exception 'Para canjear el cupón primero publica algo (una oferta o una búsqueda). Después vuelve aquí y el crédito entra a tu billetera.';
  end if;

  select * into c from public.coupons where code = upper(trim(p_code)) for update;
  if not found or c.active = false then raise exception 'Cupón no válido'; end if;
  if c.kind <> 'credit' then raise exception 'Este cupón no es de crédito'; end if;
  if c.expires_at is not null and c.expires_at < now() then raise exception 'Cupón vencido'; end if;
  if c.used_count >= c.max_uses then raise exception 'Cupón agotado'; end if;
  begin
    insert into public.coupon_redemptions (coupon_code, user_id, amount) values (c.code, uid, c.value);
  exception when unique_violation then
    raise exception 'Ya canjeaste este cupón';
  end;
  update public.coupons set used_count = used_count + 1 where code = c.code;
  insert into public.wallets (user_id, balance) values (uid, c.value)
    on conflict (user_id) do update
    set balance = public.wallets.balance + excluded.balance, updated_at = now()
    returning balance into newbal;
  return c.value;
end $$;

revoke execute on function public.redeem_coupon(text) from public;
revoke execute on function public.redeem_coupon(text) from anon;
grant execute on function public.redeem_coupon(text) to authenticated;
