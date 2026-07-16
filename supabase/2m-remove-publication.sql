-- ============================================================
-- KonektaYa · 2M · Eliminar o archivar una publicación (seguro)
-- El usuario pide "Eliminar" su publicación. El SERVIDOR decide:
--   • Si NUNCA tuvo un desbloqueo pagado  -> se BORRA de verdad.
--   • Si ya tuvo un desbloqueo (alguien pagó por el contacto) -> se ARCHIVA
--     (active=false + data.archived=true): se oculta y no hace match, pero el
--     registro y el historial/auditoría se conservan (justo para quien pagó).
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================

create or replace function public.konektaya_remove_publication(p_table text, p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare owner uuid; tuvo boolean; uid uuid;
begin
  if p_table not in ('properties','searches','vehicle_offers','vehicle_searches') then
    raise exception 'Tabla no permitida';
  end if;

  -- Debe haber sesión. SIN esto, una llamada anónima (auth.uid() = NULL) haría
  -- que "owner <> NULL" evalúe a NULL (no true) y saltaría el control de dueño:
  -- cualquiera podría borrar publicaciones ajenas con solo el anon key.
  uid := auth.uid();
  if uid is null then
    raise exception 'Debes iniciar sesión para eliminar una publicación';
  end if;

  -- Verificar que la publicación exista y sea del usuario que llama.
  execute format('select owner_id from public.%I where id = $1', p_table) into owner using p_id;
  if owner is null then return 'not_found'; end if;
  -- is distinct from maneja NULL correctamente (a diferencia de <>).
  if owner is distinct from uid then
    raise exception 'Solo el dueño puede eliminar su publicación';
  end if;

  -- ¿Tuvo un desbloqueo pagado (como oferta o como búsqueda)?
  select exists(
    select 1 from public.unlocks where offer_id = p_id or search_id = p_id
  ) into tuvo;

  if tuvo then
    -- Archivar: se oculta y no matchea, pero se conserva el registro/historial.
    execute format(
      'update public.%I
         set active = false,
             data = jsonb_set(coalesce(data, ''{}''::jsonb), ''{archived}'', ''true''::jsonb),
             updated_at = now()
       where id = $1', p_table) using p_id;
    return 'archived';
  else
    -- Sin interacciones: se puede borrar de verdad.
    execute format('delete from public.%I where id = $1', p_table) using p_id;
    return 'deleted';
  end if;
end $$;

-- Postgres concede EXECUTE a PUBLIC por defecto. Lo quitamos para que solo
-- usuarios autenticados puedan invocarla (defensa en profundidad además del
-- chequeo de auth.uid() de arriba).
revoke execute on function public.konektaya_remove_publication(text, uuid) from public;
revoke execute on function public.konektaya_remove_publication(text, uuid) from anon;
grant  execute on function public.konektaya_remove_publication(text, uuid) to authenticated;
