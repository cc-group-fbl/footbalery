-- Общий финансовый раздел сообщества.
-- Все авторизованные участники могут читать баланс и цели.
-- Изменять данные могут только пользователи с profiles.role = 'admin'.

create table if not exists public.finance_balance (
  id integer primary key check (id = 1),
  amount numeric(14,2) not null default 0,
  updated_at timestamptz not null default now()
);

insert into public.finance_balance (id, amount)
values (1, 0)
on conflict (id) do nothing;

create table if not exists public.finance_goals (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 120),
  description text not null default '',
  target_amount numeric(14,2) not null check (target_amount > 0),
  current_amount numeric(14,2) not null default 0 check (current_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.finance_balance enable row level security;
alter table public.finance_goals enable row level security;

drop policy if exists "Authenticated users can read finance balance" on public.finance_balance;
create policy "Authenticated users can read finance balance"
on public.finance_balance for select to authenticated using (true);

drop policy if exists "Admins can manage finance balance" on public.finance_balance;
create policy "Admins can manage finance balance"
on public.finance_balance for all to authenticated
using (exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin'))
with check (exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin'));

drop policy if exists "Authenticated users can read finance goals" on public.finance_goals;
create policy "Authenticated users can read finance goals"
on public.finance_goals for select to authenticated using (true);

drop policy if exists "Admins can manage finance goals" on public.finance_goals;
create policy "Admins can manage finance goals"
on public.finance_goals for all to authenticated
using (exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin'))
with check (exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin'));

grant select on public.finance_balance, public.finance_goals to authenticated;
grant insert, update, delete on public.finance_balance, public.finance_goals to authenticated;
