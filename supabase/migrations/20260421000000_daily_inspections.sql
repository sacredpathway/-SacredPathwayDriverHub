-- Daily Inspection (DVIR) log.
--
-- Fast, driver-facing record of pre-trip / post-trip inspections. The app's
-- "Daily Inspection" screen queries the most recent row by profile to
-- pre-fill driver/truck/trailer numbers so logging takes <30 seconds on
-- a normal clean inspection.
--
-- text[] on photo_paths stores storage keys (bucket `compliance-docs` or
-- a future dedicated `inspection-photos` bucket) — the column is nullable
-- and empty by default since v1 ships manual-first with no photo UI.

create table if not exists public.daily_inspections (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete cascade not null,

  inspection_date date not null,
  driver_name     text,
  truck_number    text,
  trailer_number  text,
  odometer        integer,

  inspection_type text not null default 'pre_trip'
    check (inspection_type in ('pre_trip', 'post_trip')),

  has_defects     boolean not null default false,
  defect_notes    text,

  status          text not null default 'no_defects'
    check (status in ('no_defects', 'defects_found', 'repaired', 'needs_repair')),

  signature_name  text,
  signed_at       timestamptz,
  photo_paths     text[],

  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);
-- Most-recent-first queries drive the UI; an index on profile+date supports
-- both the history list and the `fetchMostRecentInspection()` path.
create index if not exists idx_daily_inspections_profile_date
  on public.daily_inspections(profile_id, inspection_date desc);
create index if not exists idx_daily_inspections_type
  on public.daily_inspections(profile_id, inspection_type);
-- Auto-bump updated_at on every UPDATE so clients don't have to.
create or replace function public.set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;
drop trigger if exists daily_inspections_set_updated_at on public.daily_inspections;
create trigger daily_inspections_set_updated_at
  before update on public.daily_inspections
  for each row execute function public.set_updated_at();
-- Row-level security: driver sees only their own inspections.
alter table public.daily_inspections enable row level security;
drop policy if exists "own daily inspections" on public.daily_inspections;
create policy "own daily inspections" on public.daily_inspections
  for all
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());
