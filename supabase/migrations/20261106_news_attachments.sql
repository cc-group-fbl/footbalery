-- Вложения новостей для ИССД «ФУТБОЛЁРЫ»
-- Выполнить в Supabase SQL Editor один раз.

insert into storage.buckets (id, name, public, file_size_limit)
values ('news-attachments', 'news-attachments', false, 26214400)
on conflict (id) do update set public = false, file_size_limit = 26214400;

create table if not exists public.news_attachments (
  id uuid primary key default gen_random_uuid(),
  news_id uuid not null references public.news(id) on delete cascade,
  file_name text not null,
  file_path text not null unique,
  mime_type text,
  file_size bigint not null default 0,
  uploaded_by uuid not null,
  created_at timestamptz not null default now()
);

alter table public.news_attachments enable row level security;

drop policy if exists "news attachments visible to readers" on public.news_attachments;
create policy "news attachments visible to readers"
on public.news_attachments for select to authenticated
using (public.can_view_news(news_id));

drop policy if exists "admins manage news attachments" on public.news_attachments;
create policy "admins manage news attachments"
on public.news_attachments for all to authenticated
using (exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin'))
with check (exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin'));

drop policy if exists "news attachment files readable by news audience" on storage.objects;
create policy "news attachment files readable by news audience"
on storage.objects for select to authenticated
using (
  bucket_id = 'news-attachments'
  and exists (
    select 1 from public.news n
    where n.id = (storage.foldername(name))[1]::uuid
      and public.can_view_news(n.id)
  )
);

drop policy if exists "admins upload news attachment files" on storage.objects;
create policy "admins upload news attachment files"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'news-attachments'
  and exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
);

drop policy if exists "admins update news attachment files" on storage.objects;
create policy "admins update news attachment files"
on storage.objects for update to authenticated
using (
  bucket_id = 'news-attachments'
  and exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
)
with check (
  bucket_id = 'news-attachments'
  and exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
);

drop policy if exists "admins delete news attachment files" on storage.objects;
create policy "admins delete news attachment files"
on storage.objects for delete to authenticated
using (
  bucket_id = 'news-attachments'
  and exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role = 'admin')
);
