-- Driver Contact Book snapshot fields.
-- Nullable so existing participant rows and dispatch threads continue to work.

alter table public.dispatch_participants
    add column if not exists phone text,
    add column if not exists email text,
    add column if not exists truck_number text,
    add column if not exists trailer_number text,
    add column if not exists current_status text,
    add column if not exists notes text;

comment on column public.dispatch_participants.phone is
    'Optional driver contact phone snapshot for dispatcher Driver Contact Book.';

comment on column public.dispatch_participants.email is
    'Optional driver contact email snapshot for dispatcher Driver Contact Book.';

comment on column public.dispatch_participants.truck_number is
    'Optional driver truck number snapshot for dispatcher Driver Contact Book.';

comment on column public.dispatch_participants.trailer_number is
    'Optional driver trailer number snapshot for dispatcher Driver Contact Book.';

comment on column public.dispatch_participants.current_status is
    'Optional dispatcher-visible driver status label.';

comment on column public.dispatch_participants.notes is
    'Optional dispatcher-visible driver notes.';
