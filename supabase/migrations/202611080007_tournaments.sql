-- Раздел турниров и редактируемые турнирные сетки.
-- Все авторизованные участники могут просматривать сетки.
-- Создание, изменение и удаление доступны только администраторам.

create table if not exists public.tournament_brackets (
  id uuid primary key default gen_random_uuid(),
  tournament_key text not null check (tournament_key in ('dg', 'one')),
  stage text null check (
    stage is null or stage in ('autumn', 'winter', 'spring', 'summer_playoff')
  ),
  title text not null check (char_length(trim(title)) between 1 and 120),
  bracket_data jsonb not null default '{"rounds":[]}'::jsonb,
  created_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournament_stage_matches_key check (
    (tournament_key = 'dg' and stage is null)
    or
    (tournament_key = 'one' and stage is not null)
  ),
  constraint tournament_bracket_data_is_object check (jsonb_typeof(bracket_data) = 'object')
);

create index if not exists tournament_brackets_lookup_idx
  on public.tournament_brackets (tournament_key, stage, created_at);

alter table public.tournament_brackets enable row level security;

drop policy if exists "Authenticated users can read tournament brackets" on public.tournament_brackets;
create policy "Authenticated users can read tournament brackets"
on public.tournament_brackets
for select
to authenticated
using (true);

drop policy if exists "Admins can insert tournament brackets" on public.tournament_brackets;
create policy "Admins can insert tournament brackets"
on public.tournament_brackets
for insert
to authenticated
with check (
  exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid() and p.role = 'admin'
  )
  and (created_by is null or created_by = auth.uid())
);

drop policy if exists "Admins can update tournament brackets" on public.tournament_brackets;
create policy "Admins can update tournament brackets"
on public.tournament_brackets
for update
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

drop policy if exists "Admins can delete tournament brackets" on public.tournament_brackets;
create policy "Admins can delete tournament brackets"
on public.tournament_brackets
for delete
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid() and p.role = 'admin'
  )
);

grant select on public.tournament_brackets to authenticated;
grant insert, update, delete on public.tournament_brackets to authenticated;
