-- Sacred Path rebrand — database-facing display text only.
--
-- SAFE / NON-DESTRUCTIVE. Updates COMMENT metadata so the database describes the
-- feature by its official name ("Sacred Path"). It does NOT rename any table,
-- column, function, RPC, or constraint — existing data and the iOS app keep
-- working unchanged. The physical names (roadside_saved_stops,
-- roadside_parking_reports, sph_nearby_roadside_parking_report_summaries) are
-- intentionally preserved for backward compatibility with shipped builds.

comment on function public.sph_has_maps_access() is
    'Returns true for account roles allowed to use Maps / Sacred Path (carrier, owner_operator).';

comment on table public.roadside_saved_stops is
    'Sacred Path saved places (user-private). Physical name kept for backward compatibility.';

comment on table public.roadside_parking_reports is
    'Sacred Path community parking reports. Physical name kept for backward compatibility.';

comment on function public.sph_nearby_roadside_parking_report_summaries(
    double precision,
    double precision,
    integer,
    integer,
    integer
) is
    'Returns lightweight, RLS-scoped Sacred Path parking-report summaries within a radius.';
