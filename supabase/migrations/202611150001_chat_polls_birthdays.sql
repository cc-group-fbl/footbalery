-- Обычные опросы в чатах и даты рождения игроков.
-- Выполнить через Supabase SQL Editor. Повторный запуск безопасен.

begin;

-- День рождения хранится без года отображения в интерфейсе; тип DATE удобен для календарной проверки.
alter table public.profiles
  add column if not exists birth_date date;

comment on column public.profiles.birth_date is
  'Дата рождения игрока; используется для поздравления в день рождения.';

-- Получать только список именинников на текущую дату, не раскрывая всем даты рождения целиком.
create or replace function public.get_today_birthdays()
returns table(user_id uuid, display_name text)
language sql
stable
security definer
set search_path = public, auth
as $$
  select p.user_id,
         coalesce(
           nullif(trim(concat_ws(' ', p.first_name, p.last_name)), ''),
           nullif(trim(p.username), ''),
           'Игрок'
         ) as display_name
  from public.profiles p
  where p.birth_date is not null
    and extract(month from p.birth_date) = extract(month from current_date)
    and extract(day from p.birth_date) = extract(day from current_date)
  order by display_name;
$$;

revoke all on function public.get_today_birthdays() from public;
grant execute on function public.get_today_birthdays() to authenticated;

-- Дату рождения может назначать/исправлять только администратор.
create or replace function public.admin_set_player_birth_date(
  p_user_id uuid,
  p_birth_date date
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null then
    raise exception 'Необходима авторизация';
  end if;

  if not exists (
    select 1 from public.profiles
    where user_id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Изменять даты рождения может только администратор';
  end if;

  if p_birth_date is not null and p_birth_date > current_date then
    raise exception 'Дата рождения не может быть в будущем';
  end if;

  update public.profiles
  set birth_date = p_birth_date
  where user_id = p_user_id;

  if not found then
    raise exception 'Профиль игрока не найден';
  end if;
end;
$$;

revoke all on function public.admin_set_player_birth_date(uuid,date) from public;
grant execute on function public.admin_set_player_birth_date(uuid,date) to authenticated;

-- Отдельные таблицы не конфликтуют с существующими polls/poll_candidates/votes,
-- которые используются для турнирного голосования за кандидатов.
create table if not exists public.chat_polls (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  message_id uuid not null unique references public.chat_messages(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.chat_polls(id) on delete cascade,
  option_text text not null check (char_length(trim(option_text)) between 1 and 180),
  position integer not null default 0 check (position >= 0),
  unique (poll_id, position)
);

create table if not exists public.chat_poll_votes (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.chat_polls(id) on delete cascade,
  option_id uuid not null references public.chat_poll_options(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (poll_id, user_id)
);

create index if not exists chat_polls_conversation_created_idx
  on public.chat_polls(conversation_id, created_at desc);
create index if not exists chat_poll_options_poll_position_idx
  on public.chat_poll_options(poll_id, position);
create index if not exists chat_poll_votes_poll_option_idx
  on public.chat_poll_votes(poll_id, option_id);

alter table public.chat_polls enable row level security;
alter table public.chat_poll_options enable row level security;
alter table public.chat_poll_votes enable row level security;

drop policy if exists "Chat members can read polls" on public.chat_polls;
create policy "Chat members can read polls"
on public.chat_polls for select to authenticated
using (public.is_chat_member(conversation_id, auth.uid()));

drop policy if exists "Chat members can read poll options" on public.chat_poll_options;
create policy "Chat members can read poll options"
on public.chat_poll_options for select to authenticated
using (
  exists (
    select 1 from public.chat_polls p
    where p.id = chat_poll_options.poll_id
      and public.is_chat_member(p.conversation_id, auth.uid())
  )
);

drop policy if exists "Chat members can read poll votes" on public.chat_poll_votes;
create policy "Chat members can read poll votes"
on public.chat_poll_votes for select to authenticated
using (
  exists (
    select 1 from public.chat_polls p
    where p.id = chat_poll_votes.poll_id
      and public.is_chat_member(p.conversation_id, auth.uid())
  )
);

grant select on public.chat_polls, public.chat_poll_options, public.chat_poll_votes to authenticated;
-- Создание опросов и голосование выполняются только через проверяемые RPC-функции.

create or replace function public.create_chat_poll(
  p_conversation_id uuid,
  p_question text,
  p_options text[],
  p_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_poll_id uuid;
  v_message_id uuid;
  v_options text[];
  v_option text;
  v_position integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Необходима авторизация';
  end if;

  if not public.is_chat_member(p_conversation_id, auth.uid()) then
    raise exception 'Создавать опросы могут только участники чата';
  end if;

  if char_length(trim(coalesce(p_question, ''))) not between 1 and 5000 then
    raise exception 'Вопрос должен содержать от 1 до 5000 символов';
  end if;

  if p_options is null or cardinality(p_options) not between 2 and 10 then
    raise exception 'Добавьте от 2 до 10 вариантов ответа';
  end if;

  select array_agg(trim(x))
    into v_options
  from unnest(p_options) as x
  where char_length(trim(x)) between 1 and 180;

  if v_options is null or cardinality(v_options) <> cardinality(p_options) then
    raise exception 'Каждый вариант должен содержать от 1 до 180 символов';
  end if;

  if (select count(distinct lower(x)) from unnest(v_options) as x) <> cardinality(v_options) then
    raise exception 'Варианты ответа не должны повторяться';
  end if;

  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'Срок окончания должен быть в будущем';
  end if;

  insert into public.chat_messages(conversation_id, sender_id, body)
  values (p_conversation_id, auth.uid(), trim(p_question))
  returning id into v_message_id;

  insert into public.chat_polls(conversation_id, message_id, created_by, expires_at)
  values (p_conversation_id, v_message_id, auth.uid(), p_expires_at)
  returning id into v_poll_id;

  foreach v_option in array v_options loop
    insert into public.chat_poll_options(poll_id, option_text, position)
    values (v_poll_id, v_option, v_position);
    v_position := v_position + 1;
  end loop;

  return v_poll_id;
end;
$$;

revoke all on function public.create_chat_poll(uuid,text,text[],timestamptz) from public;
grant execute on function public.create_chat_poll(uuid,text,text[],timestamptz) to authenticated;

create or replace function public.vote_chat_poll(
  p_poll_id uuid,
  p_option_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_conversation_id uuid;
  v_expires_at timestamptz;
  v_closed_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Необходима авторизация';
  end if;

  select conversation_id, expires_at, closed_at
    into v_conversation_id, v_expires_at, v_closed_at
  from public.chat_polls
  where id = p_poll_id;

  if v_conversation_id is null then
    raise exception 'Опрос не найден';
  end if;

  if not public.is_chat_member(v_conversation_id, auth.uid()) then
    raise exception 'Нет доступа к этому опросу';
  end if;

  if v_closed_at is not null or (v_expires_at is not null and v_expires_at <= now()) then
    raise exception 'Голосование уже завершено';
  end if;

  if not exists (
    select 1 from public.chat_poll_options
    where id = p_option_id and poll_id = p_poll_id
  ) then
    raise exception 'Выбранный вариант не относится к этому опросу';
  end if;

  insert into public.chat_poll_votes(poll_id, option_id, user_id)
  values (p_poll_id, p_option_id, auth.uid());
exception
  when unique_violation then
    raise exception 'Вы уже голосовали в этом опросе';
end;
$$;

revoke all on function public.vote_chat_poll(uuid,uuid) from public;
grant execute on function public.vote_chat_poll(uuid,uuid) to authenticated;

create or replace function public.close_chat_poll(p_poll_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_creator uuid;
begin
  if auth.uid() is null then
    raise exception 'Необходима авторизация';
  end if;

  select created_by into v_creator
  from public.chat_polls
  where id = p_poll_id
  for update;

  if v_creator is null then
    raise exception 'Опрос не найден';
  end if;

  if v_creator <> auth.uid() and not exists (
    select 1 from public.profiles
    where user_id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Закрыть опрос может его автор или администратор';
  end if;

  update public.chat_polls
  set closed_at = coalesce(closed_at, now())
  where id = p_poll_id;
end;
$$;

revoke all on function public.close_chat_poll(uuid) from public;
grant execute on function public.close_chat_poll(uuid) to authenticated;

commit;
