-- Ensure cloud Driver Profile equipment defaults exist.
-- The app already writes these nullable fields; this migration makes the live
-- profiles table match the model without changing existing rows.

alter table public.profiles
    add column if not exists truck_number text,
    add column if not exists trailer_number text;

comment on column public.profiles.truck_number is
    'Default driver truck number used to prefill future load entry screens.';

comment on column public.profiles.trailer_number is
    'Default driver trailer number used to prefill future load entry screens.';
