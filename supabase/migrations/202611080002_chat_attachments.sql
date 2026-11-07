-- Вложения для личных и групповых чатов ФУТБОЛЁРЫ
begin;

-- Сообщение может содержать только вложение без текста.
alter table public.chat_messages
  drop constraint if exists chat_messages_body_check;

alter table public.chat_messages
  add constraint chat_messages_body_length_check
  check (char_length(trim(body)) <= 5000);

create table if not exists public.chat_attachments (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.chat_messages(id) on delete cascade,
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  file_name text not null,
  file_path text not null unique,
  mime_type text,
  file_size bigint not null default 0,
  uploaded_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists chat_attachments_message_idx
  on public.chat_attachments(message_id);

alter table public.chat_attachments enable row level security;

drop policy if exists "Chat members can view attachments" on public.chat_attachments;
create policy "Chat members can view attachments"
on public.chat_attachments for select to authenticated
using (public.is_chat_member(conversation_id,auth.uid()));

drop policy if exists "Chat members can add their own attachments" on public.chat_attachments;
create policy "Chat members can add their own attachments"
on public.chat_attachments for insert to authenticated
with check (
  uploaded_by=auth.uid()
  and public.is_chat_member(conversation_id,auth.uid())
  and exists (
    select 1 from public.chat_messages m
    where m.id=message_id and m.conversation_id=chat_attachments.conversation_id
      and m.sender_id=auth.uid()
  )
);

grant select,insert on public.chat_attachments to authenticated;

-- Приватное хранилище: файлы доступны только участникам соответствующего чата.
insert into storage.buckets (id,name,public,file_size_limit)
values ('chat-attachments','chat-attachments',false,26214400)
on conflict (id) do update
set public=false,file_size_limit=26214400;

drop policy if exists "Chat members can read chat files" on storage.objects;
create policy "Chat members can read chat files"
on storage.objects for select to authenticated
using (
  bucket_id='chat-attachments'
  and exists (
    select 1 from public.chat_members cm
    where cm.conversation_id::text=(storage.foldername(name))[1]
      and cm.user_id=auth.uid()
  )
);

drop policy if exists "Chat members can upload chat files" on storage.objects;
create policy "Chat members can upload chat files"
on storage.objects for insert to authenticated
with check (
  bucket_id='chat-attachments'
  and exists (
    select 1 from public.chat_members cm
    where cm.conversation_id::text=(storage.foldername(name))[1]
      and cm.user_id=auth.uid()
  )
);


-- Realtime: уведомляем участников после сохранения вложения.
do $realtime$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='chat_attachments'
  ) then
    alter publication supabase_realtime add table public.chat_attachments;
  end if;
exception when undefined_object then
  null;
end
$realtime$;

commit;
