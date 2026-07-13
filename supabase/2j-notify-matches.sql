-- ============================================================
-- KonektaYa · 2J · Avisos por email cuando hay match nuevo
-- Correr en Supabase → SQL Editor → Run. Idempotente.
-- ============================================================

-- 1) Registro de avisos enviados. Sirve para NO reenviar el mismo aviso
--    (dedupe por publicación nueva + destinatario) y como auditoría / futuro
--    "centro de notificaciones".
create table if not exists public.match_notifications (
  id             uuid primary key default gen_random_uuid(),
  publication_id text not null,          -- id de la publicación NUEVA que disparó el aviso
  recipient_id   uuid not null references public.profiles(id) on delete cascade,
  vertical       text not null,          -- 'inmueble' | 'vehiculo'
  kind           text not null,          -- 'offer' | 'search' (tipo de la publicación nueva)
  best_score     int,
  matched_count  int  not null default 1,
  channel        text not null default 'email',
  created_at     timestamptz not null default now(),
  unique (publication_id, recipient_id)
);

alter table public.match_notifications enable row level security;

-- El destinatario puede ver sus propios avisos (para un futuro centro de avisos).
-- La escritura la hace SOLO la Edge Function con service_role (sin policy de insert).
drop policy if exists mn_select_own on public.match_notifications;
create policy mn_select_own on public.match_notifications
  for select to authenticated using (recipient_id = auth.uid());

-- 2) Preferencia por usuario: recibir o no los avisos de match por email.
alter table public.profiles
  add column if not exists notify_matches boolean not null default true;
