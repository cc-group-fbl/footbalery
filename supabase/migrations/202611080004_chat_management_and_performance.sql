-- Удаление сообщений и защита от повторных личных чатов + ускорение realtime-удалений.
begin;

create table if not exists public.chat_message_hidden (
  message_id uuid not null references public.chat_messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  hidden_at timestamptz not null default now(),
  primary key (message_id,user_id)
);
create index if not exists chat_message_hidden_user_idx on public.chat_message_hidden(user_id,message_id);
alter table public.chat_message_hidden enable row level security;
drop policy if exists "Users can view own hidden chat messages" on public.chat_message_hidden;
create policy "Users can view own hidden chat messages"
on public.chat_message_hidden for select to authenticated
using (user_id=auth.uid());
grant select on public.chat_message_hidden to authenticated;

-- Скрытые для конкретного участника сообщения не попадают в его историю.
drop policy if exists "Chat members can read messages" on public.chat_messages;
create policy "Chat members can read messages"
on public.chat_messages for select to authenticated
using (
  public.is_chat_member(chat_messages.conversation_id,auth.uid())
  and not exists (
    select 1 from public.chat_message_hidden h
    where h.message_id=chat_messages.id and h.user_id=auth.uid()
  )
);

-- Повторный вызов создания личного чата возвращает уже существующую переписку.
-- Advisory lock закрывает гонку, если два запроса приходят одновременно.
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
  v_peer_id uuid;
  v_pair_key text;
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
    select 1 from unnest(v_members) as ids(member_id)
    where not exists (select 1 from public.profiles p where p.user_id=ids.member_id)
  ) then raise exception 'Один из участников не найден'; end if;

  if p_type='direct' then
    select member_id into v_peer_id from unnest(v_members) as x(member_id)
    where member_id<>auth.uid() limit 1;
    v_pair_key := least(auth.uid()::text,v_peer_id::text)||':'||greatest(auth.uid()::text,v_peer_id::text);
    perform pg_advisory_xact_lock(hashtextextended(v_pair_key,0));

    select c.id into v_chat_id
    from public.chat_conversations c
    join public.chat_members cm on cm.conversation_id=c.id
    where c.type='direct'
    group by c.id
    having count(*)=2 and bool_and(cm.user_id=any(v_members))
    limit 1;
    if v_chat_id is not null then return v_chat_id; end if;
  end if;

  insert into public.chat_conversations(type,title,created_by)
  values (p_type,case when p_type='group' then nullif(trim(p_title),'') else null end,auth.uid())
  returning id into v_chat_id;

  insert into public.chat_members(conversation_id,user_id)
  select v_chat_id,unnest(v_members);
  return v_chat_id;
end;
$$;
revoke all on function public.create_chat(text,uuid[],text) from public;
grant execute on function public.create_chat(text,uuid[],text) to authenticated;

-- Удаление для себя скрывает сообщение только у текущего пользователя.
-- Удаление для всех разрешено только автору сообщения.
create or replace function public.delete_chat_message(p_message_id uuid,p_for_everyone boolean)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_conversation_id uuid;
  v_sender_id uuid;
begin
  if auth.uid() is null then raise exception 'Необходима авторизация'; end if;
  select conversation_id,sender_id into v_conversation_id,v_sender_id
  from public.chat_messages where id=p_message_id;
  if v_conversation_id is null then raise exception 'Сообщение не найдено'; end if;
  if not public.is_chat_member(v_conversation_id,auth.uid()) then raise exception 'Нет доступа к этому чату'; end if;

  if coalesce(p_for_everyone,false) then
    if v_sender_id<>auth.uid() then raise exception 'Удалить сообщение у всех может только его автор'; end if;
    delete from public.chat_messages where id=p_message_id;
  else
    insert into public.chat_message_hidden(message_id,user_id)
    values(p_message_id,auth.uid())
    on conflict(message_id,user_id) do nothing;
  end if;
end;
$$;
revoke all on function public.delete_chat_message(uuid,boolean) from public;
grant execute on function public.delete_chat_message(uuid,boolean) to authenticated;

-- Позволяем автору удалить загруженные им файлы сообщения перед удалением сообщения у всех.
drop policy if exists "Users can delete own chat attachments" on storage.objects;
create policy "Users can delete own chat attachments"
on storage.objects for delete to authenticated
using (
  bucket_id='chat-attachments'
  and exists (
    select 1 from public.chat_attachments a
    where a.file_path=storage.objects.name
      and a.uploaded_by=auth.uid()
  )
);

-- DELETE-события Realtime должны содержать conversation_id для обновления открытого чата.
alter table public.chat_messages replica identity full;

commit;
