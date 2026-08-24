-- ============================================================
-- 2w · Número de WhatsApp de soporte editable desde el admin
-- ============================================================
-- Complemento de 2v: además de encender/apagar el WhatsApp de soporte, el
-- admin puede CAMBIAR el número (ej. cuando llegue el número dedicado).
-- Se guarda solo en dígitos con código de país (formato wa.me).
--
-- CÓMO CORRERLO: Supabase → SQL Editor → pegar todo → Run. Idempotente.

alter table public.app_config
  add column if not exists support_whatsapp text not null default '50764905233';

create or replace function public.admin_set_support_whatsapp(p_num text)
returns text language plpgsql security definer set search_path = public as $$
declare digits text;
begin
  if not public.is_admin() then raise exception 'Solo administradores'; end if;
  digits := regexp_replace(coalesce(p_num, ''), '\D', '', 'g');
  -- 8 dígitos = celular panameño sin código de país: se le antepone 507.
  if length(digits) = 8 then digits := '507' || digits; end if;
  if length(digits) < 10 or length(digits) > 15 then
    raise exception 'Número no válido: escribe el celular con código de país (ej. +507 6123-4567)';
  end if;
  update public.app_config set support_whatsapp = digits, updated_at = now() where id = 1;
  return (select support_whatsapp from public.app_config where id = 1);
end $$;
revoke execute on function public.admin_set_support_whatsapp(text) from public;
revoke execute on function public.admin_set_support_whatsapp(text) from anon;
grant execute on function public.admin_set_support_whatsapp(text) to authenticated;
