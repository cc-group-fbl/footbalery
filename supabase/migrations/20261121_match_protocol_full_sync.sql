-- Полная синхронизация одобренного протокола с карточкой матча.
-- Выполнить один раз в Supabase SQL Editor после миграций match_protocols и sync_approved_protocol_scores.
begin;

alter table public.match_protocol_submissions
  add column if not exists player_stats jsonb not null default '[]'::jsonb;

alter table public.matches
  add column if not exists protocol_data jsonb;

-- Расширенная версия RPC для судьи: сохраняет индивидуальные голы и карточки.
create or replace function public.submit_match_protocol(
  p_match_id bigint,
  p_score_home integer,
  p_score_away integer,
  p_home_players text default null,
  p_away_players text default null,
  p_main_referee text default null,
  p_assistant_referee text default null,
  p_main_referee_rating numeric default null,
  p_assistant_referee_rating numeric default null,
  p_referee_comment text default null,
  p_document_path text default null,
  p_player_stats jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_id uuid;
  v_home_goals integer;
  v_away_goals integer;
begin
  if auth.uid() is null then raise exception 'Необходим вход в аккаунт'; end if;
  if not exists (
    select 1 from public.match_protocol_assignments
    where match_id = p_match_id and referee_user_id = auth.uid()
  ) then raise exception 'Вы не назначены судьёй на этот матч'; end if;
  if p_score_home is null or p_score_away is null or p_score_home < 0 or p_score_away < 0 then
    raise exception 'Укажи неотрицательный счёт обеих команд';
  end if;
  if p_player_stats is null or jsonb_typeof(p_player_stats) <> 'array' then
    raise exception 'Статистика игроков должна быть списком';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_player_stats) as item
    where coalesce(item->>'team','') not in ('home','away')
       or coalesce(item->>'name','') = ''
       or coalesce(item->>'goals','') !~ '^\\d+$'
       or coalesce(item->>'yellow_cards','0') !~ '^\\d+$'
       or coalesce(item->>'red_cards','0') !~ '^\\d+$'
  ) then raise exception 'Проверь имена игроков, голы и карточки'; end if;

  select
    coalesce(sum((item->>'goals')::integer) filter (where item->>'team'='home'),0),
    coalesce(sum((item->>'goals')::integer) filter (where item->>'team'='away'),0)
  into v_home_goals,v_away_goals
  from jsonb_array_elements(p_player_stats) as item;

  if v_home_goals <> p_score_home or v_away_goals <> p_score_away then
    raise exception 'Сумма голов по игрокам должна совпадать со счётом обеих команд';
  end if;

  insert into public.match_protocol_submissions(
    match_id,referee_user_id,score_home,score_away,home_players,away_players,
    main_referee,assistant_referee,main_referee_rating,assistant_referee_rating,
    referee_comment,document_path,player_stats,status,review_comment,reviewed_by,reviewed_at,updated_at
  ) values (
    p_match_id,auth.uid(),p_score_home,p_score_away,p_home_players,p_away_players,
    p_main_referee,p_assistant_referee,p_main_referee_rating,p_assistant_referee_rating,
    p_referee_comment,p_document_path,p_player_stats,'pending',null,null,null,now()
  )
  on conflict (match_id) do update set
    referee_user_id=excluded.referee_user_id,
    score_home=excluded.score_home,score_away=excluded.score_away,
    home_players=excluded.home_players,away_players=excluded.away_players,
    main_referee=excluded.main_referee,assistant_referee=excluded.assistant_referee,
    main_referee_rating=excluded.main_referee_rating,
    assistant_referee_rating=excluded.assistant_referee_rating,
    referee_comment=excluded.referee_comment,document_path=excluded.document_path,
    player_stats=excluded.player_stats,status='pending',review_comment=null,
    reviewed_by=null,reviewed_at=null,updated_at=now()
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.submit_match_protocol(bigint,integer,integer,text,text,text,text,numeric,numeric,text,text,jsonb) from public;
grant execute on function public.submit_match_protocol(bigint,integer,integer,text,text,text,text,numeric,numeric,text,text,jsonb) to authenticated;

-- После одобрения атомарно обновляем счёт, составы и полные сведения протокола.
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
  v_submission public.match_protocol_submissions%rowtype;
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where user_id=auth.uid() and role='admin'
  ) then raise exception 'Доступно только администратору'; end if;
  if p_status is null or p_status not in ('needs_changes','approved') then
    raise exception 'Недопустимый статус проверки';
  end if;

  update public.match_protocol_submissions
  set status=p_status,review_comment=p_review_comment,
      reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
  where id=p_submission_id
  returning * into v_submission;

  if not found then raise exception 'Протокол не найден'; end if;

  if p_status='approved' then
    update public.matches
    set score_home=v_submission.score_home,
        score_away=v_submission.score_away,
        home_players=v_submission.home_players,
        away_players=v_submission.away_players,
        protocol_data=jsonb_build_object(
          'submission_id',v_submission.id,
          'referee_user_id',v_submission.referee_user_id,
          'score_home',v_submission.score_home,
          'score_away',v_submission.score_away,
          'home_players',v_submission.home_players,
          'away_players',v_submission.away_players,
          'player_stats',v_submission.player_stats,
          'main_referee',v_submission.main_referee,
          'assistant_referee',v_submission.assistant_referee,
          'main_referee_rating',v_submission.main_referee_rating,
          'assistant_referee_rating',v_submission.assistant_referee_rating,
          'referee_comment',v_submission.referee_comment,
          'document_path',v_submission.document_path,
          'review_comment',p_review_comment,
          'approved_at',now()
        )
    where id=v_submission.match_id;
    if not found then raise exception 'Матч для протокола не найден; изменения не сохранены'; end if;
  end if;
end;
$$;

revoke all on function public.admin_review_match_protocol(uuid,text,text) from public;
grant execute on function public.admin_review_match_protocol(uuid,text,text) to authenticated;

-- Обновляем уже одобренные протоколы, чтобы они тоже отображались в расписании.
update public.matches m
set score_home=s.score_home,
    score_away=s.score_away,
    home_players=s.home_players,
    away_players=s.away_players,
    protocol_data=jsonb_build_object(
      'submission_id',s.id,
      'referee_user_id',s.referee_user_id,
      'score_home',s.score_home,
      'score_away',s.score_away,
      'home_players',s.home_players,
      'away_players',s.away_players,
      'player_stats',s.player_stats,
      'main_referee',s.main_referee,
      'assistant_referee',s.assistant_referee,
      'main_referee_rating',s.main_referee_rating,
      'assistant_referee_rating',s.assistant_referee_rating,
      'referee_comment',s.referee_comment,
      'document_path',s.document_path,
      'review_comment',s.review_comment,
      'approved_at',s.reviewed_at
    )
from public.match_protocol_submissions s
where s.match_id=m.id and s.status='approved';

commit;
