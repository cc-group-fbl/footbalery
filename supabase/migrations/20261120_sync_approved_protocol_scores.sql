-- Синхронизация одобренных электронных протоколов с основным результатом матча.
-- Безопасно выполнять после 20261120_match_protocols.sql.
begin;

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
declare
  v_match_id bigint;
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where user_id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Доступно только администратору';
  end if;

  if p_status is null or p_status not in ('needs_changes','approved') then
    raise exception 'Недопустимый статус проверки';
  end if;

  update public.match_protocol_submissions
  set status = p_status,
      review_comment = p_review_comment,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = p_submission_id
  returning match_id into v_match_id;

  if not found then
    raise exception 'Протокол не найден';
  end if;

  -- Результат попадает в основную карточку матча только после одобрения.
  if p_status = 'approved' then
    update public.matches
    set score_home = (
          select s.score_home
          from public.match_protocol_submissions s
          where s.id = p_submission_id
        ),
        score_away = (
          select s.score_away
          from public.match_protocol_submissions s
          where s.id = p_submission_id
        )
    where id = v_match_id;

    if not found then
      raise exception 'Матч для протокола не найден; результат не опубликован';
    end if;
  end if;
end;
$$;

revoke all on function public.admin_review_match_protocol(uuid,text,text) from public;
grant execute on function public.admin_review_match_protocol(uuid,text,text) to authenticated;

-- Однократная синхронизация протоколов, одобренных до установки этой миграции.
update public.matches m
set score_home = s.score_home,
    score_away = s.score_away
from public.match_protocol_submissions s
where s.match_id = m.id
  and s.status = 'approved';

commit;
