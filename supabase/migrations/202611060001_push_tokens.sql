-- Push notification device tokens
create table if not exists public.push_tokens (
  token text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null default 'android' check (platform in ('android')),
  updated_at timestamptz not null default now()
);

create index if not exists push_tokens_user_id_idx
  on public.push_tokens(user_id);

alter table public.push_tokens enable row level security;

drop policy if exists "Users can read their own push tokens" on public.push_tokens;
create policy "Users can read their own push tokens"
  on public.push_tokens for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Users can register their own push tokens" on public.push_tokens;
create policy "Users can register their own push tokens"
  on public.push_tokens for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Users can update their own push tokens" on public.push_tokens;
create policy "Users can update their own push tokens"
  on public.push_tokens for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Users can delete their own push tokens" on public.push_tokens;
create policy "Users can delete their own push tokens"
  on public.push_tokens for delete
  to authenticated
  using (auth.uid() = user_id);

comment on table public.push_tokens is 'FCM device tokens used for Android push notifications.';
