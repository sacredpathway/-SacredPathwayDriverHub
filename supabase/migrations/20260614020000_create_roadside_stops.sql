-- Roadside Stops community sync
--
-- The iOS MVP discovers stops with Apple Maps / MKLocalSearch, then stores a
-- user's saved stops and parking reports here when Cloud Sync is available.
-- Saved stops are private to the owner. Parking reports are community-readable
-- for the same account roles that can access Maps in the app.

create or replace function public.sph_has_maps_access()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.sph_current_account_role() in ('carrier', 'owner_operator')
$$;

comment on function public.sph_has_maps_access() is
    'Returns true for account roles allowed to use Maps/Roadside Stops.';

create table if not exists public.roadside_saved_stops (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    account_role text not null,
    stop_id text not null,
    stop_name text not null,
    stop_category text not null,
    latitude double precision not null,
    longitude double precision not null,
    address text,
    phone_number text,
    url text,
    open_status text,
    amenities text[] not null default '{}',
    notes text,
    apple_maps_name text,
    apple_maps_place_id text,
    apple_maps_url text,
    apple_maps_point_of_interest_category text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint roadside_saved_stops_account_role_check
        check (account_role in ('carrier', 'owner_operator')),
    constraint roadside_saved_stops_stop_category_check
        check (stop_category in (
            'truck_stops',
            'rest_areas',
            'fuel',
            'scales',
            'weigh_stations',
            'parking',
            'repair'
        )),
    constraint roadside_saved_stops_user_stop_unique unique (user_id, stop_id)
);

create table if not exists public.roadside_parking_reports (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    account_role text not null,
    stop_id text not null,
    stop_name text not null,
    stop_category text not null,
    parking_status text not null,
    notes text,
    latitude double precision not null,
    longitude double precision not null,
    address text,
    apple_maps_name text,
    apple_maps_place_id text,
    apple_maps_url text,
    apple_maps_point_of_interest_category text,
    reported_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint roadside_parking_reports_account_role_check
        check (account_role in ('carrier', 'owner_operator')),
    constraint roadside_parking_reports_stop_category_check
        check (stop_category in (
            'truck_stops',
            'rest_areas',
            'fuel',
            'scales',
            'weigh_stations',
            'parking',
            'repair'
        )),
    constraint roadside_parking_reports_status_check
        check (parking_status in ('available', 'limited', 'full', 'unknown')),
    constraint roadside_parking_reports_user_stop_unique unique (user_id, stop_id)
);

create index if not exists idx_roadside_saved_stops_user_updated
    on public.roadside_saved_stops (user_id, updated_at desc);

create index if not exists idx_roadside_saved_stops_location
    on public.roadside_saved_stops (latitude, longitude);

create index if not exists idx_roadside_parking_reports_stop_updated
    on public.roadside_parking_reports (stop_id, updated_at desc);

create index if not exists idx_roadside_parking_reports_location
    on public.roadside_parking_reports (latitude, longitude);

create or replace function public.sph_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists roadside_saved_stops_touch_updated_at on public.roadside_saved_stops;
create trigger roadside_saved_stops_touch_updated_at
before update on public.roadside_saved_stops
for each row execute function public.sph_touch_updated_at();

drop trigger if exists roadside_parking_reports_touch_updated_at on public.roadside_parking_reports;
create trigger roadside_parking_reports_touch_updated_at
before update on public.roadside_parking_reports
for each row execute function public.sph_touch_updated_at();

alter table public.roadside_saved_stops enable row level security;
alter table public.roadside_parking_reports enable row level security;

drop policy if exists "roadside saved stops select own" on public.roadside_saved_stops;
create policy "roadside saved stops select own"
on public.roadside_saved_stops for select
using (
    public.sph_has_maps_access()
    and user_id = auth.uid()
);

drop policy if exists "roadside saved stops insert own" on public.roadside_saved_stops;
create policy "roadside saved stops insert own"
on public.roadside_saved_stops for insert
with check (
    public.sph_has_maps_access()
    and user_id = auth.uid()
    and account_role = public.sph_current_account_role()
);

drop policy if exists "roadside saved stops update own" on public.roadside_saved_stops;
create policy "roadside saved stops update own"
on public.roadside_saved_stops for update
using (
    public.sph_has_maps_access()
    and user_id = auth.uid()
)
with check (
    public.sph_has_maps_access()
    and user_id = auth.uid()
    and account_role = public.sph_current_account_role()
);

drop policy if exists "roadside saved stops delete own" on public.roadside_saved_stops;
create policy "roadside saved stops delete own"
on public.roadside_saved_stops for delete
using (
    public.sph_has_maps_access()
    and user_id = auth.uid()
);

drop policy if exists "roadside parking reports read maps community" on public.roadside_parking_reports;
create policy "roadside parking reports read maps community"
on public.roadside_parking_reports for select
using (public.sph_has_maps_access());

drop policy if exists "roadside parking reports insert own" on public.roadside_parking_reports;
create policy "roadside parking reports insert own"
on public.roadside_parking_reports for insert
with check (
    public.sph_has_maps_access()
    and user_id = auth.uid()
    and account_role = public.sph_current_account_role()
);

drop policy if exists "roadside parking reports update own" on public.roadside_parking_reports;
create policy "roadside parking reports update own"
on public.roadside_parking_reports for update
using (
    public.sph_has_maps_access()
    and user_id = auth.uid()
)
with check (
    public.sph_has_maps_access()
    and user_id = auth.uid()
    and account_role = public.sph_current_account_role()
);

drop policy if exists "roadside parking reports delete own" on public.roadside_parking_reports;
create policy "roadside parking reports delete own"
on public.roadside_parking_reports for delete
using (
    public.sph_has_maps_access()
    and user_id = auth.uid()
);

grant select, insert, update, delete on public.roadside_saved_stops to authenticated;
grant select, insert, update, delete on public.roadside_parking_reports to authenticated;
