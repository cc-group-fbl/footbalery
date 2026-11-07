-- Чаты ФУТБОЛЁРЫ: личные и групповые переписки
begin;

create table if not exists public.chat_conversations (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('direct','group')),
  title text,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.chat_members (
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  last_read_at timestamptz not null default now(),
  primary key (conversation_id,user_id)
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 5000),
  created_at timestamptz not null default now()
);

create index if not exists chat_members_user_idx on public.chat_members(user_id);
create index if not exists chat_messages_conversation_created_idx on public.chat_messages(conversation_id,created_at desc);

alter table public.chat_conversations enable row level security;
alter table public.chat_members enable row level security;
alter table public.chat_messages enable row level security;

-- SECURITY DEFINER helper prevents recursive RLS checks on chat_members.
create or replace function public.is_chat_member(p_conversation_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $
  select exists (
    select 1 from public.chat_members m
    where m.conversation_id=p_conversation_id and m.user_id=p_user_id
  );
$;
revoke all on function public.is_chat_member(uuid,uuid) from public;
grant execute on function public.is_chat_member(uuid,uuid) to authenticated;

drop policy if exists "Chat members can view their conversations" on public.chat_conversations;
create policy "Chat members can view their conversations"
on public.chat_conversations for select to authenticated
using (public.is_chat_member(id,auth.uid()));

drop policy if exists "Members can view chat membership" on public.chat_members;
create policy "Members can view chat membership"
on public.chat_members for select to authenticated
using (public.is_chat_member(chat_members.conversation_id,auth.uid()));

drop policy if exists "Users update own chat read marker" on public.chat_members;
create policy "Users update own chat read marker"
on public.chat_members for update to authenticated
using (user_id=auth.uid())
with check (user_id=auth.uid());

drop policy if exists "Chat members can read messages" on public.chat_messages;
create policy "Chat members can read messages"
on public.chat_messages for select to authenticated
using (public.is_chat_member(chat_messages.conversation_id,auth.uid()));

drop policy if exists "Chat members can send messages as themselves" on public.chat_messages;
create policy "Chat members can send messages as themselves"
on public.chat_messages for insert to authenticated
with check (
  sender_id=auth.uid()
  and public.is_chat_member(chat_messages.conversation_id,auth.uid())
);

grant select on public.chat_conversations, public.chat_members, public.chat_messages to authenticated;
grant update (last_read_at) on public.chat_members to authenticated;
grant insert on public.chat_messages to authenticated;

create or replace function public.create_chat(p_title text, p_member_ids uuid[], p_type text)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_chat_id uuid;
  v_members uuid[];
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Необходима авторизация'; end if;
  if p_type not in ('direct','group') then raise exception 'Неизвестный тип чата'; end if;

  select array_agg(distinct u.member_id) into v_members
  from unnest(coalesce(p_member_ids,'{}'::uuid[]) || array[auth.uid()]) as u(member_id);

  v_count := coalesce(array_length(v_members,1),0);
  if p_type='direct' and v_count<>2 then raise exception 'Для личного чата нужен один собеседник'; end if;
  if p_type='group' and v_count<2 then raise exception 'Добавьте хотя бы одного участника'; end if;
  if v_count>50 then raise exception 'В чате может быть не более 50 участников'; end if;

  if exists (
    select 1 from unnest(v_members) u
    where not exists (select 1 from public.profiles p where p.user_id=u)
  ) then raise exception 'Один из участников не найден'; end if;

  insert into public.chat_conversations(type,title,created_by)
  values (p_type, case when p_type='group' then nullif(trim(p_title),'') else null end, auth.uid())
  returning id into v_chat_id;

  insert into public.chat_members(conversation_id,user_id)
  select v_chat_id, unnest(v_members);

  return v_chat_id;
end;
$$;

revoke all on function public.create_chat(text,uuid[],text) from public;
grant execute on function public.create_chat(text,uuid[],text) to authenticated;

-- Обновляем сортировку списка чатов при появлении нового сообщения.
create or replace function public.touch_chat_updated_at()
returns trigger language plpgsql security definer set search_path=public
as $
begin
  update public.chat_conversations set updated_at=new.created_at where id=new.conversation_id;
  return new;
end;
$;
drop trigger if exists chat_message_touch_conversation on public.chat_messages;
create trigger chat_message_touch_conversation
after insert on public.chat_messages
for each row execute function public.touch_chat_updated_at();

-- Разрешаем Supabase Realtime передавать новые сообщения подписчикам чата.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='chat_messages'
  ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
exception when undefined_object then
  null;
end $$;

commit;
