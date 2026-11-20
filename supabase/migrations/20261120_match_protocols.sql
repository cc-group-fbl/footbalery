-- Footbalery: электронные протоколы матчей
-- Выполнить в Supabase SQL Editor. Миграция не изменяет существующие matches/schedule_events.
begin;

create table if not exists public.match_protocol_assignments (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  referee_user_id uuid not null references auth.users(id) on delete cascade,
  assigned_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (match_id)
);

create table if not exists public.match_protocol_submissions (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  referee_user_id uuid not null references auth.users(id) on delete cascade,
  score_home integer not null check (score_home >= 0),
  score_away integer not null check (score_away >= 0),
  home_players text,
  away_players text,
  main_referee text,
  assistant_referee text,
  main_referee_rating numeric(3,1) check (main_referee_rating between 0 and 10),
  assistant_referee_rating numeric(3,1) check (assistant_referee_rating between 0 and 10),
  referee_comment text,
  document_path text,
  status text not null default 'pending'
    check (status in ('pending','needs_changes','approved')),
  review_comment text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (match_id)
);

create index if not exists match_protocol_assignments_referee_idx
  on public.match_protocol_assignments(referee_user_id);
create index if not exists match_protocol_submissions_status_idx
  on public.match_protocol_submissions(status, created_at desc);

alter table public.match_protocol_assignments enable row level security;
alter table public.match_protocol_submissions enable row level security;

drop policy if exists "protocol assignments visible to assigned referee and admins" on public.match_protocol_assignments;
create policy "protocol assignments visible to assigned referee and admins"
on public.match_protocol_assignments for select to authenticated
using (
  referee_user_id = auth.uid()
  or exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
);

drop policy if exists "protocol submissions visible to referee and admins" on public.match_protocol_submissions;
create policy "protocol submissions visible to referee and admins"
on public.match_protocol_submissions for select to authenticated
using (
  referee_user_id = auth.uid()
  or exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
);

create or replace function public.admin_assign_match_referee(p_match_id uuid, p_referee_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where user_id = auth.uid() and role = 'admin'
  ) then raise exception 'Доступно только администратору'; end if;
  if not exists (select 1 from public.matches where id = p_match_id) then
    raise exception 'Матч не найден';
  end if;
  if not exists (select 1 from public.profiles where user_id = p_referee_user_id) then
    raise exception 'Пользователь не найден';
  end if;
  insert into public.match_protocol_assignments(match_id, referee_user_id, assigned_by)
  values (p_match_id, p_referee_user_id, auth.uid())
  on conflict (match_id) do update
    set referee_user_id = excluded.referee_user_id,
        assigned_by = excluded.assigned_by,
        created_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.submit_match_protocol(
  p_match_id uuid,
  p_score_home integer,
  p_score_away integer,
  p_home_players text default null,
  p_away_players text default null,
  p_main_referee text default null,
  p_assistant_referee text default null,
  p_main_referee_rating numeric default null,
  p_assistant_referee_rating numeric default null,
  p_referee_comment text default null,
  p_document_path text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Необходим вход в аккаунт'; end if;
  if not exists (
    select 1 from public.match_protocol_assignments
    where match_id = p_match_id and referee_user_id = auth.uid()
  ) then raise exception 'Вы не назначены судьёй на этот матч'; end if;
  if p_score_home < 0 or p_score_away < 0 then raise exception 'Счёт не может быть отрицательным'; end if;
  insert into public.match_protocol_submissions(
    match_id, referee_user_id, score_home, score_away, home_players, away_players,
    main_referee, assistant_referee, main_referee_rating, assistant_referee_rating,
    referee_comment, document_path, status, review_comment, reviewed_by, reviewed_at, updated_at
  ) values (
    p_match_id, auth.uid(), p_score_home, p_score_away, p_home_players, p_away_players,
    p_main_referee, p_assistant_referee, p_main_referee_rating, p_assistant_referee_rating,
    p_referee_comment, p_document_path, 'pending', null, null, null, now()
  )
  on conflict (match_id) do update set
    referee_user_id = excluded.referee_user_id,
    score_home = excluded.score_home, score_away = excluded.score_away,
    home_players = excluded.home_players, away_players = excluded.away_players,
    main_referee = excluded.main_referee, assistant_referee = excluded.assistant_referee,
    main_referee_rating = excluded.main_referee_rating,
    assistant_referee_rating = excluded.assistant_referee_rating,
    referee_comment = excluded.referee_comment, document_path = excluded.document_path,
    status = 'pending', review_comment = null, reviewed_by = null, reviewed_at = null,
    updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_review_match_protocol(
  p_submission_id uuid,
  p_status text,
  p_review_comment text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where user_id = auth.uid() and role = 'admin'
  ) then raise exception 'Доступно только администратору'; end if;
  if p_status not in ('needs_changes','approved') then
    raise exception 'Недопустимый статус проверки';
  end if;
  update public.match_protocol_submissions
  set status = p_status, review_comment = p_review_comment,
      reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  where id = p_submission_id;
  if not found then raise exception 'Протокол не найден'; end if;
end;
$$;

revoke all on function public.admin_assign_match_referee(uuid,uuid) from public;
revoke all on function public.submit_match_protocol(uuid,integer,integer,text,text,text,text,numeric,numeric,text,text) from public;
revoke all on function public.admin_review_match_protocol(uuid,text,text) from public;
grant execute on function public.admin_assign_match_referee(uuid,uuid) to authenticated;
grant execute on function public.submit_match_protocol(uuid,integer,integer,text,text,text,text,numeric,numeric,text,text) to authenticated;
grant execute on function public.admin_review_match_protocol(uuid,text,text) to authenticated;

commit;
