create table if not exists public.ifta_entries (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete cascade not null,
  load_id uuid references public.loads(id) on delete set null,
  entry_date date not null,
  state_code text not null,
  miles_driven numeric(10,2) not null default 0,
  fuel_gallons numeric(10,2) not null default 0,
  fuel_price_per_gallon numeric(6,3),
  total_fuel_cost numeric(10,2),
  notes text,
  created_at timestamptz default now()
);
create index if not exists idx_ifta_profile_date on public.ifta_entries(profile_id, entry_date);
create index if not exists idx_ifta_state on public.ifta_entries(state_code);
alter table public.ifta_entries enable row level security;
drop policy if exists "own ifta entries" on public.ifta_entries;
create policy "own ifta entries" on public.ifta_entries
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());
