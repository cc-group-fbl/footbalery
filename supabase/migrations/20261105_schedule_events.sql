-- Расписание официальных мероприятий для ИССД «ФУТБОЛЁРЫ»
-- Выполнить один раз в Supabase → SQL Editor.

begin;

alter table public.matches
  add column if not exists schedule_id text,
  add column if not exists tournament text,
  add column if not exists description text,
  add column if not exists score_home integer,
  add column if not exists score_away integer;

create unique index if not exists matches_schedule_id_uidx
  on public.matches(schedule_id)
  where schedule_id is not null;

-- Для обычных матчей команда не выбирается; для Д×Г поле остаётся обязательным на уровне интерфейса.
do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema='public'
      and table_name='match_applications'
      and column_name='team'
      and is_nullable='NO'
  ) then
    alter table public.match_applications alter column team drop not null;
  end if;
end $$;

create table if not exists public.schedule_events (
  id text primary key,
  type text not null check (type in ('match','event')),
  title text not null,
  event_date date not null,
  event_time time,
  location text,
  description text,
  tournament text,
  match_id uuid references public.matches(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint schedule_events_match_link_check
    check ((type='match' and match_id is not null) or (type='event' and match_id is null))
);

alter table public.schedule_events enable row level security;

grant select on public.schedule_events to authenticated;
grant insert, update, delete on public.schedule_events to authenticated;

drop policy if exists "Authenticated users can read schedule events" on public.schedule_events;
create policy "Authenticated users can read schedule events"
  on public.schedule_events for select
  to authenticated
  using (auth.uid() is not null);

drop policy if exists "Admins manage schedule events" on public.schedule_events;
create policy "Admins manage schedule events"
  on public.schedule_events for all
  to authenticated
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

commit;
