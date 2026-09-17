-- =============================================================================
-- SECURITY HARDENING — REVIEW & TEST BEFORE APPLYING TO PRODUCTION
-- =============================================================================
-- Filename is intentionally prefixed REVIEW_BEFORE_APPLYING_ so the Supabase CLI
-- does NOT auto-run it. Rename it to a normal timestamped name only after you
-- have tested it on a Supabase branch. The app is currently in App Review; do
-- not change production RLS semantics until that build is approved.
--
-- FINDING
-- -------
-- The original policy "roadside parking reports read maps community" grants
-- SELECT on EVERY column of EVERY user's parking report (including free-text
-- `notes`, `user_id`, and `account_role`) to ANY maps-eligible user. The iOS app
-- never reads that table directly — it only calls the aggregate RPC
-- sph_nearby_roadside_parking_report_summaries — but the broad policy still
-- exposes other drivers' raw notes/identity to anyone who queries the table.
--
-- FIX
-- ---
-- 1. Make the aggregate RPC SECURITY DEFINER so it can still summarize across
--    all users (it only ever returns counts + latest status — never notes or
--    user_id), and
-- 2. Restrict direct table SELECT to the report's OWNER.
-- Net effect: community aggregates keep working; raw per-user notes/identity are
-- no longer readable by other users.

set search_path = public, extensions;

-- 1) Aggregate RPC runs as definer so own-row RLS does not blind it.
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
security definer
set search_path = public, extensions
as $$
    with guard as (
        -- still enforce the feature gate even though we run as definer
        select public.sph_has_maps_access() as ok
    ),
    params as (
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
        cross join guard g
        where g.ok
          and r.location is not null
          and r.updated_at >= now() - make_interval(days => p.since_days)
          and st_dwithin(r.location, p.origin, p.radius_meters)
    ),
    ranked as (
        select nearby.*,
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

grant execute on function public.sph_nearby_roadside_parking_report_summaries(
    double precision, double precision, integer, integer, integer
) to authenticated;

-- 2) Replace the broad community SELECT with owner-only SELECT.
drop policy if exists "roadside parking reports read maps community" on public.roadside_parking_reports;

drop policy if exists "roadside parking reports select own" on public.roadside_parking_reports;
create policy "roadside parking reports select own"
on public.roadside_parking_reports for select
using (
    public.sph_has_maps_access()
    and user_id = auth.uid()
);
