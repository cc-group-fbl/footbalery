-- Регистрация игроков на турниры и мероприятия.
begin;
create table if not exists public.event_registrations (
  id uuid primary key default gen_random_uuid(),
  event_id text not null,
  event_name text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  unique(event_id,user_id)
);
create index if not exists event_registrations_event_status_idx
  on public.event_registrations(event_id,status,created_at desc);
alter table public.event_registrations enable row level security;
drop policy if exists "Users read own event registrations" on public.event_registrations;
create policy "Users read own event registrations"
  on public.event_registrations for select to authenticated
  using (user_id=auth.uid() or exists (
    select 1 from public.profiles p where p.user_id=auth.uid() and p.role='admin'
  ));
drop policy if exists "Users submit own event registrations" on public.event_registrations;
create policy "Users submit own event registrations"
  on public.event_registrations for insert to authenticated
  with check (user_id=auth.uid() and status='pending' and reviewed_by is null and reviewed_at is null);
drop policy if exists "Admins review event registrations" on public.event_registrations;
create policy "Admins review event registrations"
  on public.event_registrations for update to authenticated
  using (exists (select 1 from public.profiles p where p.user_id=auth.uid() and p.role='admin'))
  with check (exists (select 1 from public.profiles p where p.user_id=auth.uid() and p.role='admin'));
grant select,insert on public.event_registrations to authenticated;
grant update(status,reviewed_by,reviewed_at) on public.event_registrations to authenticated;
commit;
