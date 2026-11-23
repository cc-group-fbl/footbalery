-- Отложенный запуск опросов для СС «ФУТБОЛЁРЫ»
-- Выполнить один раз в Supabase SQL Editor.

ALTER TABLE public.polls
  ADD COLUMN IF NOT EXISTS starts_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS polls_active_starts_ends_idx
  ON public.polls (starts_at, ends_at)
  WHERE is_active = true;

-- Старые опросы продолжат считаться начавшимися сразу после миграции,
-- поскольку для них starts_at заполняется значением DEFAULT now().
