-- ============================================================
-- 2v · Soporte: interruptor de WhatsApp + email de soporte
-- ============================================================
-- El dueño aún no tiene número de WhatsApp dedicado: el soporte arranca por
-- EMAIL, y cuando tenga el número lo enciende desde el admin (como los pagos).
-- Misma tabla app_config (fila única) y mismos candados (is_admin).
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

alter table public.app_config
  add column if not exists whatsapp_support_enabled boolean not null default false;
alter table public.app_config
  add column if not exists support_email text not null default 'soporte@konektaya.com';

create or replace function public.admin_set_whatsapp_support(p_on boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  update public.app_config set whatsapp_support_enabled = coalesce(p_on, false), updated_at = now() where id = 1;
  return (select whatsapp_support_enabled from public.app_config where id = 1);
end $$;
revoke execute on function public.admin_set_whatsapp_support(boolean) from public;
revoke execute on function public.admin_set_whatsapp_support(boolean) from anon;
grant execute on function public.admin_set_whatsapp_support(boolean) to authenticated;

create or replace function public.admin_set_support_email(p_email text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Email no válido';
  end if;
  update public.app_config set support_email = lower(trim(p_email)), updated_at = now() where id = 1;
  return (select support_email from public.app_config where id = 1);
end $$;
revoke execute on function public.admin_set_support_email(text) from public;
revoke execute on function public.admin_set_support_email(text) from anon;
grant execute on function public.admin_set_support_email(text) to authenticated;
