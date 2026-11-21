-- Отложенные новости Footbalery и автоматическая публикация через pg_cron.
begin;

create extension if not exists pg_cron;

create table if not exists public.scheduled_news (
  id uuid primary key,
  title text not null check (length(trim(title)) between 1 and 180),
  body text not null check (length(trim(body)) between 1 and 8000),
  image_url text,
  author_id uuid not null references auth.users(id) on delete cascade,
  visibility text not null check (visibility in ('all','selected')),
  recipient_ids uuid[] not null default '{}',
  scheduled_for timestamptz not null,
  status text not null default 'pending' check (status in ('pending','published','cancelled','failed')),
  published_news_id uuid,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  last_error text
);

create index if not exists scheduled_news_due_idx
  on public.scheduled_news (scheduled_for)
  where status='pending';

alter table public.scheduled_news enable row level security;
drop policy if exists scheduled_news_admin_read on public.scheduled_news;
create policy scheduled_news_admin_read on public.scheduled_news
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.user_id=auth.uid() and p.role='admin'));

create or replace function public.admin_schedule_news(
  p_title text,
  p_body text,
  p_image_url text,
  p_visibility text,
  p_recipient_ids uuid[],
  p_scheduled_for timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_id uuid := gen_random_uuid();
  v_recipients uuid[] := coalesce(p_recipient_ids,'{}'::uuid[]);
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where user_id=auth.uid() and role='admin'
  ) then raise exception 'Доступно только администратору'; end if;
  if p_title is null or length(trim(p_title)) not between 1 and 180 then
    raise exception 'Заголовок должен содержать от 1 до 180 символов';
  end if;
  if p_body is null or length(trim(p_body)) not between 1 and 8000 then
    raise exception 'Текст должен содержать от 1 до 8000 символов';
  end if;
  if p_visibility not in ('all','selected') then raise exception 'Неверная аудитория новости'; end if;
  if p_scheduled_for is null or p_scheduled_for <= now() then raise exception 'Дата публикации должна быть в будущем'; end if;
  if p_visibility='selected' then
    if cardinality(v_recipients)=0 then raise exception 'Выберите хотя бы одного получателя'; end if;
    if exists (select 1 from unnest(v_recipients) x where not exists (select 1 from public.profiles p where p.user_id=x)) then
      raise exception 'В списке есть неизвестный участник';
    end if;
  else
    v_recipients := '{}';
  end if;
  insert into public.scheduled_news(id,title,body,image_url,author_id,visibility,recipient_ids,scheduled_for)
  values(v_id,trim(p_title),trim(p_body),nullif(trim(p_image_url),''),auth.uid(),p_visibility,v_recipients,p_scheduled_for);
  return v_id;
end;
$$;

create or replace function public.admin_cancel_scheduled_news(p_schedule_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where user_id=auth.uid() and role='admin'
  ) then raise exception 'Доступно только администратору'; end if;
  update public.scheduled_news set status='cancelled'
  where id=p_schedule_id and status='pending';
  if not found then raise exception 'Запланированная новость не найдена или уже обработана'; end if;
end;
$$;

-- Функция вызывается планировщиком БД каждую минуту. Она создаёт новость,
-- список получателей и уведомления одной транзакцией; повторная отправка исключена блокировкой строки.
create or replace function public.process_due_scheduled_news()
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_item public.scheduled_news%rowtype;
  v_targets uuid[];
  v_count integer := 0;
begin
  for v_item in
    select * from public.scheduled_news
    where status='pending' and scheduled_for <= now()
    order by scheduled_for
    limit 50
    for update skip locked
  loop
    begin
      insert into public.news(id,title,body,image_url,author_id,created_by,visibility)
      values(v_item.id,v_item.title,v_item.body,v_item.image_url,v_item.author_id,v_item.author_id,v_item.visibility);

      if v_item.visibility='all' then
        select coalesce(array_agg(p.user_id),'{}'::uuid[]) into v_targets from public.profiles p;
      else
        v_targets := v_item.recipient_ids;
        insert into public.news_recipients(news_id,user_id)
        select v_item.id,x from unnest(v_targets) x;
      end if;

      insert into public.notifications(user_id,news_id,title,body)
      select x,v_item.id,v_item.title,left(v_item.body,500)
      from unnest(v_targets) x;

      update public.scheduled_news
      set status='published',published_news_id=v_item.id,published_at=now(),last_error=null
      where id=v_item.id;
      v_count := v_count + 1;
    exception when others then
      update public.scheduled_news
      set status='failed',last_error=left(sqlerrm,1000)
      where id=v_item.id;
    end;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.admin_schedule_news(text,text,text,text,uuid[],timestamptz) from public;
revoke all on function public.admin_cancel_scheduled_news(uuid) from public;
revoke all on function public.process_due_scheduled_news() from public, anon, authenticated;
grant execute on function public.admin_schedule_news(text,text,text,text,uuid[],timestamptz) to authenticated;
grant execute on function public.admin_cancel_scheduled_news(uuid) to authenticated;

do $$
declare
  v_job_id bigint;
begin
  select jobid into v_job_id from cron.job where jobname='footbalery-publish-scheduled-news' limit 1;
  if v_job_id is not null then perform cron.unschedule(v_job_id); end if;
  perform cron.schedule(
    'footbalery-publish-scheduled-news',
    '* * * * *',
    'select public.process_due_scheduled_news();'
  );
end;
$$;

commit;
