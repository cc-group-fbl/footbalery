-- Статистика турнира «Деревенские × Городские», импортированная из Memento Database.
-- Выполнить один раз в Supabase SQL Editor.

begin;

create table if not exists public.dg_tournament_statistics (
  season text primary key check (season in ('2025/2026','2026/2027')),
  stats jsonb not null default '{}'::jsonb,
  source_name text,
  imported_at timestamptz not null default now(),
  imported_by uuid references auth.users(id) on delete set null
);

alter table public.dg_tournament_statistics enable row level security;

drop policy if exists "DG statistics visible to authenticated users" on public.dg_tournament_statistics;
create policy "DG statistics visible to authenticated users"
on public.dg_tournament_statistics
for select to authenticated
using (true);

drop policy if exists "DG statistics insert by admins" on public.dg_tournament_statistics;
create policy "DG statistics insert by admins"
on public.dg_tournament_statistics
for insert to authenticated
with check (
  exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
);

drop policy if exists "DG statistics update by admins" on public.dg_tournament_statistics;
create policy "DG statistics update by admins"
on public.dg_tournament_statistics
for update to authenticated
using (
  exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
)
with check (
  exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
);

grant select, insert, update on public.dg_tournament_statistics to authenticated;

comment on table public.dg_tournament_statistics is
  'Агрегированная статистика Д×Г из официальной выгрузки Memento Database; одна запись на сезон.';

commit;
