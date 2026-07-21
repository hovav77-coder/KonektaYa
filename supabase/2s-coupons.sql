-- ============================================================
-- KonektaYa · 2S · Cupones de crédito regalo
-- ------------------------------------------------------------
-- El admin crea códigos (ej. BIENVENIDA10, $10, 100 usos) y el usuario los
-- canjea en su panel: el crédito entra directo a su billetera, sin compra.
-- Reglas inviolables en servidor: 1 por usuario (PK), tope de usos (lock),
-- vencimiento, activo/inactivo. Correr en Supabase → SQL Editor. Idempotente.
-- ============================================================

create table if not exists public.coupons (
  code       text primary key,                    -- se guarda en MAYÚSCULAS
  kind       text not null default 'credit',      -- 'credit' (regalo); 'discount' futuro
  value      numeric not null check (value > 0),
  max_uses   int not null default 1 check (max_uses > 0),
  used_count int not null default 0,
  active     boolean not null default true,
  expires_at timestamptz,
  created_at timestamptz default now()
);

create table if not exists public.coupon_redemptions (
  coupon_code text not null references public.coupons(code) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  amount      numeric not null,
  created_at  timestamptz default now(),
  primary key (coupon_code, user_id)              -- 1 canje por usuario
);

alter table public.coupons enable row level security;
alter table public.coupon_redemptions enable row level security;

-- El usuario puede ver SUS canjes (futuro historial); los cupones no se listan
-- al público (se canjean por RPC; el admin los lista por RPC).
drop policy if exists cr_select_own on public.coupon_redemptions;
create policy cr_select_own on public.coupon_redemptions
  for select to authenticated using (user_id = auth.uid());

-- ---------- Canje (usuario logueado) ----------
create or replace function public.redeem_coupon(p_code text)
returns numeric language plpgsql security definer set search_path = public as $$
declare c record; uid uuid := auth.uid(); newbal numeric;
begin
  if uid is null then raise exception 'Inicia sesión para canjear un cupón'; end if;
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

-- ---------- Gestión (solo admin) ----------
create or replace function public.admin_create_coupon(p_code text, p_value numeric, p_max_uses int, p_expires timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  if p_value is null or p_value <= 0 then raise exception 'Valor inválido'; end if;
  if p_max_uses is null or p_max_uses <= 0 then raise exception 'Usos máximos inválidos'; end if;
  if length(trim(coalesce(p_code,''))) < 3 then raise exception 'El código debe tener al menos 3 caracteres'; end if;
  insert into public.coupons (code, kind, value, max_uses, expires_at)
    values (upper(trim(p_code)), 'credit', p_value, p_max_uses, p_expires);
exception when unique_violation then
  raise exception 'Ya existe un cupón con ese código';
end $$;
grant execute on function public.admin_create_coupon(text, numeric, int, timestamptz) to authenticated;

create or replace function public.admin_list_coupons()
returns table (code text, kind text, value numeric, max_uses int, used_count int, active boolean, expires_at timestamptz, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  return query select c.code, c.kind, c.value, c.max_uses, c.used_count, c.active, c.expires_at, c.created_at
    from public.coupons c order by c.created_at desc;
end $$;
grant execute on function public.admin_list_coupons() to authenticated;

create or replace function public.admin_set_coupon_active(p_code text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  update public.coupons set active = coalesce(p_on, false) where code = upper(trim(p_code));
end $$;
grant execute on function public.admin_set_coupon_active(text, boolean) to authenticated;

-- Detalle de canjes de un cupón: quién lo usó, cuánto y cuándo (solo admin).
create or replace function public.admin_list_coupon_redemptions(p_code text)
returns table (email text, name text, amount numeric, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  return query
    select p.email, p.name, r.amount, r.created_at
    from public.coupon_redemptions r
    left join public.profiles p on p.id = r.user_id
    where r.coupon_code = upper(trim(p_code))
    order by r.created_at desc;
end $$;
grant execute on function public.admin_list_coupon_redemptions(text) to authenticated;
