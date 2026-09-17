-- Add nullable driver equipment defaults and per-load equipment snapshots.
-- Existing rows keep NULL values, so historical loads remain unchanged.

alter table public.profiles
    add column if not exists truck_number text,
    add column if not exists trailer_number text;

alter table public.loads
    add column if not exists truck_number text,
    add column if not exists trailer_number text;

comment on column public.profiles.truck_number is
    'Default driver truck number used to prefill future load entry screens.';

comment on column public.profiles.trailer_number is
    'Default driver trailer number used to prefill future load entry screens.';

comment on column public.loads.truck_number is
    'Per-load truck number snapshot; nullable for older rows and manual overrides.';

comment on column public.loads.trailer_number is
    'Per-load trailer number snapshot; nullable for older rows and manual overrides.';
