-- Roadside Stops nearby parking report summaries.
--
-- Adds PostGIS-backed radius queries for community parking reports while
-- preserving the existing RLS rules on roadside_parking_reports.

create schema if not exists extensions;
create extension if not exists postgis with schema extensions;

set search_path = public, extensions;

alter table public.roadside_parking_reports
    add column if not exists location geography(Point, 4326)
    generated always as (
        st_setsrid(st_makepoint(longitude, latitude), 4326)::geography
    ) stored;

create index if not exists idx_roadside_parking_reports_location_gist
    on public.roadside_parking_reports
    using gist (location);

create or replace function public.sph_nearby_roadside_parking_report_summaries(
    p_latitude double precision,
    p_longitude double precision,
    p_radius_meters integer default 80000,
    p_since_days integer default 7,
    p_limit integer default 250
)
returns table (
    stop_id text,
    latest_status text,
    latest_reported_at timestamptz,
    total_reports bigint,
    available_count bigint,
    limited_count bigint,
    full_count bigint,
    unknown_count bigint
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
    with params as (
        select
            st_setsrid(st_makepoint(p_longitude, p_latitude), 4326)::geography as origin,
            least(greatest(coalesce(p_radius_meters, 80000), 1000), 321869) as radius_meters,
            least(greatest(coalesce(p_since_days, 7), 1), 30) as since_days,
            least(greatest(coalesce(p_limit, 250), 1), 500) as row_limit
    ),
    nearby as (
        select r.*
        from public.roadside_parking_reports r
        cross join params p
        where public.sph_has_maps_access()
          and r.location is not null
          and r.updated_at >= now() - make_interval(days => p.since_days)
          and st_dwithin(r.location, p.origin, p.radius_meters)
    ),
    ranked as (
        select
            nearby.*,
            row_number() over (
                partition by nearby.stop_id
                order by nearby.updated_at desc, nearby.reported_at desc
            ) as report_rank
        from nearby
    ),
    aggregated as (
        select
            ranked.stop_id,
            max(ranked.parking_status) filter (where ranked.report_rank = 1) as latest_status,
            max(ranked.updated_at) filter (where ranked.report_rank = 1) as latest_reported_at,
            count(*) as total_reports,
            count(*) filter (where ranked.parking_status = 'available') as available_count,
            count(*) filter (where ranked.parking_status = 'limited') as limited_count,
            count(*) filter (where ranked.parking_status = 'full') as full_count,
            count(*) filter (where ranked.parking_status = 'unknown') as unknown_count
        from ranked
        group by ranked.stop_id
    )
    select
        aggregated.stop_id,
        aggregated.latest_status,
        aggregated.latest_reported_at,
        aggregated.total_reports,
        aggregated.available_count,
        aggregated.limited_count,
        aggregated.full_count,
        aggregated.unknown_count
    from aggregated, params
    order by aggregated.latest_reported_at desc
    limit (select row_limit from params);
$$;

comment on function public.sph_nearby_roadside_parking_report_summaries(
    double precision,
    double precision,
    integer,
    integer,
    integer
) is
    'Returns lightweight, RLS-scoped parking report summaries for Roadside Stops within a radius.';

grant execute on function public.sph_nearby_roadside_parking_report_summaries(
    double precision,
    double precision,
    integer,
    integer,
    integer
) to authenticated;
