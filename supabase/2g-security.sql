-- ============================================================
-- KonektaYa · 2G · Endurecimiento de seguridad (auditoría jul 2026)
-- Correr en Supabase → SQL Editor → Run. Idempotente.
--
-- C1: add_credit solo administradores (antes: cualquier usuario podía
--     regalarse saldo desde la consola del navegador).
-- C2: profiles con permisos por columna (antes: un broker podía
--     auto-aprobarse escribiendo broker_status='aprobado').
-- H1/H2: débito y crédito de saldo ATÓMICOS (antes: leer-luego-escribir
--     permitía doble gasto con peticiones simultáneas).
-- H3: la orden de PayPal queda ligada al usuario que la creó.
-- M1: solo el CLIENTE puede responder confirmed/declined a un interés.
-- ============================================================

-- ---------- C1 · add_credit solo admin ----------
create or replace function public.add_credit(amount numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare newbal numeric;
begin
  if not public.is_admin() then
    raise exception 'Solo administradores pueden acreditar saldo manualmente';
  end if;
  if amount is null or amount <= 0 then
    raise exception 'Monto inválido';
  end if;
  insert into public.wallets (user_id, balance)
    values (auth.uid(), amount)
  on conflict (user_id)
    do update set balance = public.wallets.balance + excluded.balance, updated_at = now()
  returning balance into newbal;
  return newbal;
end;
$$;

-- ---------- C2 · profiles: broker_status NO editable por el cliente ----------
revoke insert, update on public.profiles from authenticated;
grant insert (id, email, name, phone, role, broker_license, broker_company, broker_independent)
  on public.profiles to authenticated;
grant update (email, name, phone, role, broker_license, broker_company, broker_independent, updated_at)
  on public.profiles to authenticated;
-- (broker_status solo lo cambia admin_set_broker_status, que es SECURITY DEFINER.)

-- ---------- H1/H2 · operaciones de saldo atómicas (solo service_role) ----------
create or replace function public.wallet_debit(p_user uuid, p_amount numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare newbal numeric;
begin
  if p_amount is null or p_amount < 0 then raise exception 'Monto inválido'; end if;
  insert into public.wallets (user_id, balance) values (p_user, 0)
    on conflict (user_id) do nothing;
  update public.wallets
     set balance = balance - p_amount, updated_at = now()
   where user_id = p_user and balance >= p_amount
   returning balance into newbal;
  if newbal is null then
    raise exception 'SALDO_INSUFICIENTE';
  end if;
  return newbal;
end;
$$;
revoke execute on function public.wallet_debit(uuid, numeric) from public, anon, authenticated;
grant execute on function public.wallet_debit(uuid, numeric) to service_role;

create or replace function public.wallet_credit(p_user uuid, p_amount numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare newbal numeric;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'Monto inválido'; end if;
  insert into public.wallets (user_id, balance) values (p_user, p_amount)
    on conflict (user_id)
    do update set balance = public.wallets.balance + excluded.balance, updated_at = now()
  returning balance into newbal;
  return newbal;
end;
$$;
revoke execute on function public.wallet_credit(uuid, numeric) from public, anon, authenticated;
grant execute on function public.wallet_credit(uuid, numeric) to service_role;

-- ---------- H3 · órdenes PayPal ligadas al usuario creador ----------
alter table public.paypal_orders add column if not exists status text not null default 'credited';
alter table public.paypal_orders alter column amount set default 0;

-- ---------- M1 · interés: solo el cliente responde; el dueño solo re-pregunta ----------
drop policy if exists ir_update on public.interest_requests;
drop policy if exists ir_update_client on public.interest_requests;
create policy ir_update_client on public.interest_requests
  for update to authenticated
  using (client_id = auth.uid())
  with check (client_id = auth.uid());
drop policy if exists ir_update_owner on public.interest_requests;
create policy ir_update_owner on public.interest_requests
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid() and status = 'pending');
