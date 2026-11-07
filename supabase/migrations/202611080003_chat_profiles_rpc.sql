-- Безопасное получение имён участников общих чатов.
-- Функция возвращает только user_id, username, first_name и last_name.
create or replace function public.get_chat_profiles(p_user_ids uuid[])
returns table (
  user_id uuid,
  username text,
  first_name text,
  last_name text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.user_id, p.username, p.first_name, p.last_name
  from public.profiles p
  where p.user_id = any(coalesce(p_user_ids, array[]::uuid[]))
    and exists (
      select 1
      from public.chat_members mine
      join public.chat_members peer
        on peer.conversation_id = mine.conversation_id
      where mine.user_id = auth.uid()
        and peer.user_id = p.user_id
    );
$$;

revoke all on function public.get_chat_profiles(uuid[]) from public;
revoke all on function public.get_chat_profiles(uuid[]) from anon;
grant execute on function public.get_chat_profiles(uuid[]) to authenticated;
