-- Additive, idempotent. Adds optional contact-label columns to user_connections
-- so both apps can display who invited / was invited, persisted across reloads.
-- No RLS change; columns sit on rows the requester/recipient already read.
alter table public.user_connections
  add column if not exists requester_email        text,
  add column if not exists requester_display_name text,
  add column if not exists recipient_email        text,
  add column if not exists recipient_display_name text;

comment on column public.user_connections.requester_email        is 'Email label of the inviting party (written by the inviter app). Display/history only; not an identity source.';
comment on column public.user_connections.requester_display_name is 'Display name of the inviting party (optional).';
comment on column public.user_connections.recipient_email        is 'Email the inviter typed to find the recipient. Display/history only; persists the "Sent" row across reloads.';
comment on column public.user_connections.recipient_display_name is 'Display name of the recipient (optional, written once known).';
