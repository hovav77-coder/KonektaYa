-- ============================================================
-- KonektaYa · 2H · Acreditar saldo a cualquier usuario (solo admin)
-- Correr en Supabase → SQL Editor → Run. Idempotente.
--
-- Permite al administrador sumar saldo REAL a la billetera de cualquier
-- usuario registrado, buscándolo por email. Útil para pruebas internas
-- sin pasar por PayPal/sandbox. Gated por is_admin().
-- ============================================================

create or replace function public.admin_add_credit(target_email text, amount numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid;
  newbal numeric;
begin
  if not public.is_admin() then
    raise exception 'Solo administradores pueden acreditar saldo';
  end if;
  if amount is null or amount <= 0 then
    raise exception 'Monto inválido';
  end if;

  select id into uid
  from public.profiles
  where lower(email) = lower(trim(target_email))
  limit 1;

  if uid is null then
    raise exception 'No existe un usuario con ese email';
  end if;

  insert into public.wallets (user_id, balance)
    values (uid, amount)
  on conflict (user_id)
    do update set balance = public.wallets.balance + excluded.balance, updated_at = now()
  returning balance into newbal;

  return newbal;
end;
$$;

grant execute on function public.admin_add_credit(text, numeric) to authenticated;
