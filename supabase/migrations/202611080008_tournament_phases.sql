-- Add qualification/playoff phases to the 1v1 tournament.
-- Existing tournament brackets are preserved and classified as qualification.
alter table public.tournament_brackets
  add column if not exists phase text not null default 'qualification';

alter table public.tournament_brackets
  drop constraint if exists tournament_brackets_phase_check;

alter table public.tournament_brackets
  add constraint tournament_brackets_phase_check
  check (phase in ('qualification', 'playoff'));

alter table public.tournament_brackets
  drop constraint if exists tournament_phase_matches_key;

alter table public.tournament_brackets
  add constraint tournament_phase_matches_key
  check (
    (tournament_key = 'one' and phase in ('qualification', 'playoff'))
    or
    (tournament_key = 'dg' and phase = 'qualification')
  );

create index if not exists tournament_brackets_phase_lookup_idx
  on public.tournament_brackets (tournament_key, stage, phase, created_at);
