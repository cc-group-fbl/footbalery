-- Login audit history for administrators.
create table if not exists public.login_history (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  logged_in_at timestamptz not null default now(),
  device_label text not null default 'Неизвестное устройство',
  browser_label text not null default 'Неизвестный браузер',
  os_label text not null default 'Неизвестная ОС',
  user_agent text
);

create index if not exists login_history_logged_in_at_idx
  on public.login_history (logged_in_at desc);
create index if not exists login_history_user_id_logged_in_at_idx
  on public.login_history (user_id, logged_in_at desc);

alter table public.login_history enable row level security;

drop policy if exists "Admins can read login history" on public.login_history;
create policy "Admins can read login history"
on public.login_history
for select
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid() and p.role = 'admin'
  )
);

create or replace function public.log_my_login(
  p_device_label text default null,
  p_browser_label text default null,
  p_os_label text default null,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  insert into public.login_history (
    user_id, device_label, browser_label, os_label, user_agent
  ) values (
    auth.uid(),
    left(coalesce(nullif(trim(p_device_label), ''), 'Неизвестное устройство'), 120),
    left(coalesce(nullif(trim(p_browser_label), ''), 'Неизвестный браузер'), 120),
    left(coalesce(nullif(trim(p_os_label), ''), 'Неизвестная ОС'), 120),
    left(coalesce(p_user_agent, ''), 1000)
  );
end;
$$;

revoke all on function public.log_my_login(text,text,text,text) from public;
grant execute on function public.log_my_login(text,text,text,text) to authenticated;
grant select on public.login_history to authenticated;
