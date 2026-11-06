-- Подробные сведения и фотографии матчей расписания
-- Выполнить один раз в Supabase → SQL Editor.

begin;

alter table public.schedule_events
  add column if not exists details text;

insert into storage.buckets (id, name, public, file_size_limit)
values ('schedule-attachments', 'schedule-attachments', false, 26214400)
on conflict (id) do update
set public = false, file_size_limit = 26214400;

create table if not exists public.schedule_event_attachments (
  id uuid primary key default gen_random_uuid(),
  event_id text not null references public.schedule_events(id) on delete cascade,
  file_name text not null,
  file_path text not null unique,
  mime_type text,
  file_size bigint not null default 0,
  uploaded_by uuid not null,
  created_at timestamptz not null default now()
);

create index if not exists schedule_event_attachments_event_id_idx
  on public.schedule_event_attachments(event_id);

alter table public.schedule_event_attachments enable row level security;

grant select, insert, update, delete
  on public.schedule_event_attachments to authenticated;

drop policy if exists "Authenticated users read match photos" on public.schedule_event_attachments;
create policy "Authenticated users read match photos"
  on public.schedule_event_attachments
  for select to authenticated
  using (auth.uid() is not null);

drop policy if exists "Admins manage match photos" on public.schedule_event_attachments;
create policy "Admins manage match photos"
  on public.schedule_event_attachments
  for all to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin'
    )
  )
  with check (
    exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin'
    )
  );

drop policy if exists "Authenticated users read match photo files" on storage.objects;
create policy "Authenticated users read match photo files"
  on storage.objects
  for select to authenticated
  using (
    bucket_id = 'schedule-attachments'
    and exists (
      select 1 from public.schedule_event_attachments a
      where a.file_path = storage.objects.name
    )
  );

drop policy if exists "Admins upload match photo files" on storage.objects;
create policy "Admins upload match photo files"
  on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'schedule-attachments'
    and exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin'
    )
  );

drop policy if exists "Admins update match photo files" on storage.objects;
create policy "Admins update match photo files"
  on storage.objects
  for update to authenticated
  using (
    bucket_id = 'schedule-attachments'
    and exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin'
    )
  )
  with check (
    bucket_id = 'schedule-attachments'
    and exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin'
    )
  );

drop policy if exists "Admins delete match photo files" on storage.objects;
create policy "Admins delete match photo files"
  on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'schedule-attachments'
    and exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin'
    )
  );

commit;
