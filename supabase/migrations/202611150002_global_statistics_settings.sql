-- Дополнение общих настроек статистики: флаг имени и права доступа.
-- Выполнить после создания public.statistics_settings.

begin;

alter table public.statistics_settings
  add column if not exists name_enabled boolean not null default true;

grant select on public.statistics_settings to authenticated;
grant insert, update on public.statistics_settings to authenticated;

commit;
