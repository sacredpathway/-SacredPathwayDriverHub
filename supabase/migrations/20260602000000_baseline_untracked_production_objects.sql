-- =====================================================================
-- Baseline: untracked production objects
-- Version 20260602000000 (sorts after 20260530130000, before 20260604135602)
--
-- WHY
--   Production (rmzqxsfhjqrshhdjzhze) contains objects that no tracked
--   migration creates. A new preview branch replays the tracked history and
--   stops at 20260604135602 ("relation public.user_connections does not
--   exist"). This file recreates those objects so the history replays.
--
-- SOURCE
--   Generated 2026-09-16 from the production catalog with read-only SELECTs
--   (pg_get_functiondef, pg_get_constraintdef, pg_get_indexdef, pg_policy,
--   pg_get_triggerdef, aclexplode, pg_default_acl). No production rows read.
--
-- STATUS: DRAFT. NOT APPLIED ANYWHERE.
--   * Production already has every object below. Do NOT run this file on
--     production. Recording version 20260602000000 in production's
--     supabase_migrations.schema_migrations is a production write and needs
--     explicit owner approval (2.3.3 reconciliation).
--   * Idempotent: create ... if not exists, guarded constraints,
--     create or replace function, drop ... if exists before create policy
--     and create trigger.
--
-- REVISION 2 (2026-09-16 audit): added 2b (expenses DEF column types) and
--   8b (replica identity FULL), found by the extended catalog comparison.
--
-- NOT INCLUDED (on purpose)
--   * Rows of public.sph_edge_config (runtime config; may hold a key).
--   * Objects stored in the config bucket.
--   * 20260616094021 seed data (demo reviewer account) - data, not schema.
--   * Event trigger ensure_rls -> public.rls_auto_enable(): production has
--     it (auto-enables RLS on new public tables); creating event triggers is
--     a platform/dashboard setting, not a migration. Every table here enables
--     RLS explicitly.
--   * Extension pg_net: present on new branches, absent on production.
--
-- SECURITY NOTE
--   Sections 12 and 14 mirror production: anon and authenticated hold full
--   table privileges and RLS is the access control. This file does not
--   widen anything production already allows. Tightening anon table
--   privileges is a separate, reviewed change.
--
-- ROLLBACK (branches/local only; never production)
--   drop table if exists public.connection_messages, public.message_reads,
--     public.notifications, public.dispatch_device_tokens,
--     public.sph_edge_config, public.user_connections cascade;
--   drop function if exists public._sph_d1_recreate_user_setnull(text,text,text),
--     public.rls_auto_enable(), public.sph_anonymize_dispatcher(uuid),
--     public.sph_conn_is_accepted_member(uuid), public.sph_conn_touch_updated_at(),
--     public.sph_dispatch_caller_muted_out(uuid), public.sph_dispatch_mark_read(uuid),
--     public.sph_find_connectable_user(text), public.sph_notify_dispatch_push() cascade;
--   alter table public.dispatch_participants drop column if exists last_read_at,
--     drop column if exists last_read_message_id, drop column if exists muted_at,
--     drop column if exists participant_status;
--   alter table public.expenses drop column if exists def_total;
--   (policy, privilege and default-privilege changes are restored by
--    re-running the tracked migrations on a fresh branch)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables that exist in production but no tracked migration creates.
--    The four user_connections contact columns are left to 20260604135602.
-- ---------------------------------------------------------------------
create table if not exists public.user_connections (
  id uuid default gen_random_uuid() not null,
  requester_id uuid not null,
  recipient_id uuid not null,
  requester_role text not null,
  recipient_role text not null,
  status text default 'pending'::text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table if not exists public.connection_messages (
  id uuid default gen_random_uuid() not null,
  connection_id uuid not null,
  sender_id uuid not null,
  body text not null,
  created_at timestamp with time zone default now() not null,
  read_at timestamp with time zone
);
create table if not exists public.message_reads (
  id uuid default gen_random_uuid() not null,
  message_id uuid not null,
  conversation_id uuid,
  profile_id uuid not null,
  read_at timestamp with time zone default now() not null
);
create table if not exists public.notifications (
  id uuid default gen_random_uuid() not null,
  recipient_profile_id uuid not null,
  company_id uuid,
  kind text not null,
  title text,
  body text,
  payload jsonb,
  delivery_status text default 'pending'::text not null,
  read_at timestamp with time zone,
  sent_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.dispatch_device_tokens (
  id uuid default gen_random_uuid() not null,
  profile_id uuid not null,
  token text not null,
  platform text default 'ios'::text not null,
  app text,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);
create table if not exists public.sph_edge_config (
  key text not null,
  value text not null
);

-- ---------------------------------------------------------------------
-- 2. Columns on existing tables added outside tracked migrations.
--    expenses.receipt_image_filename is left to 20260705031141.
-- ---------------------------------------------------------------------
alter table public.dispatch_participants add column if not exists last_read_at timestamp with time zone;
alter table public.dispatch_participants add column if not exists last_read_message_id uuid;
alter table public.dispatch_participants add column if not exists muted_at timestamp with time zone;
alter table public.dispatch_participants add column if not exists participant_status text default 'active'::text not null;
alter table public.expenses add column if not exists def_total numeric;

-- 2b. Column types widened in production outside tracked migrations.
--     20260419230000 created these as decimal(10,2) / decimal(6,3); production
--     has unconstrained numeric. Widening only (no rounding, no data loss).
--     Guarded: does nothing when the column is already unconstrained numeric.
do $sph$
begin
  if exists (select 1 from pg_attribute
              where attrelid = 'public.expenses'::regclass and attname = 'def_gallons'
                and atttypid = 'numeric'::regtype and atttypmod <> -1) then
    alter table public.expenses alter column def_gallons type numeric;
  end if;
  if exists (select 1 from pg_attribute
              where attrelid = 'public.expenses'::regclass and attname = 'def_price_per_gallon'
                and atttypid = 'numeric'::regtype and atttypmod <> -1) then
    alter table public.expenses alter column def_price_per_gallon type numeric;
  end if;
end
$sph$;

-- ---------------------------------------------------------------------
-- 3. Primary key, unique and check constraints.
-- ---------------------------------------------------------------------
do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'connection_messages_body_check' and conrelid = 'public.connection_messages'::regclass) then
    alter table public.connection_messages add constraint connection_messages_body_check CHECK (((length(btrim(body)) > 0) AND (length(body) <= 4000)));
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'connection_messages_pkey' and conrelid = 'public.connection_messages'::regclass) then
    alter table public.connection_messages add constraint connection_messages_pkey PRIMARY KEY (id);
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'dispatch_device_tokens_pkey' and conrelid = 'public.dispatch_device_tokens'::regclass) then
    alter table public.dispatch_device_tokens add constraint dispatch_device_tokens_pkey PRIMARY KEY (id);
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'dispatch_device_tokens_profile_id_token_key' and conrelid = 'public.dispatch_device_tokens'::regclass) then
    alter table public.dispatch_device_tokens add constraint dispatch_device_tokens_profile_id_token_key UNIQUE (profile_id, token);
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'message_reads_message_id_profile_id_key' and conrelid = 'public.message_reads'::regclass) then
    alter table public.message_reads add constraint message_reads_message_id_profile_id_key UNIQUE (message_id, profile_id);
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'message_reads_pkey' and conrelid = 'public.message_reads'::regclass) then
    alter table public.message_reads add constraint message_reads_pkey PRIMARY KEY (id);
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'notifications_pkey' and conrelid = 'public.notifications'::regclass) then
    alter table public.notifications add constraint notifications_pkey PRIMARY KEY (id);
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'sph_edge_config_pkey' and conrelid = 'public.sph_edge_config'::regclass) then
    alter table public.sph_edge_config add constraint sph_edge_config_pkey PRIMARY KEY (key);
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_connections_no_self' and conrelid = 'public.user_connections'::regclass) then
    alter table public.user_connections add constraint user_connections_no_self CHECK ((requester_id <> recipient_id));
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_connections_pkey' and conrelid = 'public.user_connections'::regclass) then
    alter table public.user_connections add constraint user_connections_pkey PRIMARY KEY (id);
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_connections_recipient_role_check' and conrelid = 'public.user_connections'::regclass) then
    alter table public.user_connections add constraint user_connections_recipient_role_check CHECK ((recipient_role = ANY (ARRAY['dispatcher'::text, 'driver'::text, 'owner_operator'::text, 'carrier'::text])));
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_connections_requester_role_check' and conrelid = 'public.user_connections'::regclass) then
    alter table public.user_connections add constraint user_connections_requester_role_check CHECK ((requester_role = ANY (ARRAY['dispatcher'::text, 'driver'::text, 'owner_operator'::text, 'carrier'::text])));
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_connections_role_pairing' and conrelid = 'public.user_connections'::regclass) then
    alter table public.user_connections add constraint user_connections_role_pairing CHECK (((requester_role = 'dispatcher'::text) <> (recipient_role = 'dispatcher'::text)));
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_connections_status_check' and conrelid = 'public.user_connections'::regclass) then
    alter table public.user_connections add constraint user_connections_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'declined'::text, 'blocked'::text])));
  end if;
end
$sph$;


-- ---------------------------------------------------------------------
-- 4. Foreign keys (new tables, dispatch_participants read marker, and the
--    SET NULL dispatcher FKs that _sph_d1_recreate_user_setnull created).
-- ---------------------------------------------------------------------
do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'connection_messages_connection_id_fkey' and conrelid = 'public.connection_messages'::regclass) then
    alter table public.connection_messages add constraint connection_messages_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES user_connections(id) ON DELETE CASCADE;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'connection_messages_sender_id_fkey' and conrelid = 'public.connection_messages'::regclass) then
    alter table public.connection_messages add constraint connection_messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES auth.users(id) ON DELETE CASCADE;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'dispatch_device_tokens_profile_id_fkey' and conrelid = 'public.dispatch_device_tokens'::regclass) then
    alter table public.dispatch_device_tokens add constraint dispatch_device_tokens_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'dispatch_participants_last_read_message_id_fkey' and conrelid = 'public.dispatch_participants'::regclass) then
    alter table public.dispatch_participants add constraint dispatch_participants_last_read_message_id_fkey FOREIGN KEY (last_read_message_id) REFERENCES dispatch_messages(id) ON DELETE SET NULL;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'dispatcher_fee_records_user_fk_setnull' and conrelid = 'public.dispatcher_fee_records'::regclass) then
    alter table public.dispatcher_fee_records add constraint dispatcher_fee_records_user_fk_setnull FOREIGN KEY (dispatcher_user_id) REFERENCES auth.users(id) ON DELETE SET NULL NOT VALID;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'dispatcher_invoices_user_fk_setnull' and conrelid = 'public.dispatcher_invoices'::regclass) then
    alter table public.dispatcher_invoices add constraint dispatcher_invoices_user_fk_setnull FOREIGN KEY (dispatcher_user_id) REFERENCES auth.users(id) ON DELETE SET NULL NOT VALID;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'dispatcher_payment_records_user_fk_setnull' and conrelid = 'public.dispatcher_payment_records'::regclass) then
    alter table public.dispatcher_payment_records add constraint dispatcher_payment_records_user_fk_setnull FOREIGN KEY (dispatcher_user_id) REFERENCES auth.users(id) ON DELETE SET NULL NOT VALID;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'dispatcher_profiles_user_fk_setnull' and conrelid = 'public.dispatcher_profiles'::regclass) then
    alter table public.dispatcher_profiles add constraint dispatcher_profiles_user_fk_setnull FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL NOT VALID;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'message_reads_conversation_id_fkey' and conrelid = 'public.message_reads'::regclass) then
    alter table public.message_reads add constraint message_reads_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dispatch_threads(id) ON DELETE CASCADE;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'message_reads_message_id_fkey' and conrelid = 'public.message_reads'::regclass) then
    alter table public.message_reads add constraint message_reads_message_id_fkey FOREIGN KEY (message_id) REFERENCES dispatch_messages(id) ON DELETE CASCADE;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'message_reads_profile_id_fkey' and conrelid = 'public.message_reads'::regclass) then
    alter table public.message_reads add constraint message_reads_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'notifications_recipient_profile_id_fkey' and conrelid = 'public.notifications'::regclass) then
    alter table public.notifications add constraint notifications_recipient_profile_id_fkey FOREIGN KEY (recipient_profile_id) REFERENCES profiles(id) ON DELETE CASCADE;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_connections_recipient_id_fkey' and conrelid = 'public.user_connections'::regclass) then
    alter table public.user_connections add constraint user_connections_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES auth.users(id) ON DELETE CASCADE;
  end if;
end
$sph$;

do $sph$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_connections_requester_id_fkey' and conrelid = 'public.user_connections'::regclass) then
    alter table public.user_connections add constraint user_connections_requester_id_fkey FOREIGN KEY (requester_id) REFERENCES auth.users(id) ON DELETE CASCADE;
  end if;
end
$sph$;


-- ---------------------------------------------------------------------
-- 5. dispatcher_profiles.user_id is nullable in production (dispatcher anonymize).
-- ---------------------------------------------------------------------
alter table public.dispatcher_profiles alter column user_id drop not null;

-- ---------------------------------------------------------------------
-- 6. Indexes that are not backed by a constraint.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_connection_messages_thread ON public.connection_messages USING btree (connection_id, created_at);
CREATE INDEX IF NOT EXISTS idx_user_connections_recipient ON public.user_connections USING btree (recipient_id);
CREATE INDEX IF NOT EXISTS idx_user_connections_requester ON public.user_connections USING btree (requester_id);
CREATE INDEX IF NOT EXISTS idx_user_connections_status ON public.user_connections USING btree (status);
CREATE UNIQUE INDEX IF NOT EXISTS ux_user_connections_pair ON public.user_connections USING btree (LEAST(requester_id, recipient_id), GREATEST(requester_id, recipient_id));

-- ---------------------------------------------------------------------
-- 7. Functions. Bodies copied verbatim from pg_get_functiondef. No secrets:
--    sph_notify_dispatch_push reads its URL and key from public.sph_edge_config
--    at run time; this file creates no rows in that table.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._sph_d1_recreate_user_setnull(p_table text, p_col text, p_fk_name text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
    v_existing  text;
    v_nullable  text;
begin
    if to_regclass('public.' || p_table) is null then
        raise notice 'D1: table public.% absent -- skipping', p_table; return;
    end if;
    select is_nullable into v_nullable
    from information_schema.columns
    where table_schema='public' and table_name=p_table and column_name=p_col;
    if v_nullable is null then
        raise notice 'D1: column %.% absent -- skipping', p_table, p_col; return;
    end if;
    if v_nullable = 'NO' then
        raise notice 'D1: %.% is NOT NULL -- cannot SET NULL; leave FK as-is and rely on anonymize RPC only.', p_table, p_col;
        return;
    end if;

    select tc.constraint_name into v_existing
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu
      on kcu.constraint_name = tc.constraint_name and kcu.table_schema = tc.table_schema
    where tc.constraint_type='FOREIGN KEY'
      and tc.table_schema='public' and tc.table_name=p_table
      and kcu.column_name=p_col
    group by tc.constraint_name
    having count(*)=1
    limit 1;

    if v_existing is not null then
        execute format('alter table public.%I drop constraint %I', p_table, v_existing);
        raise notice 'D1: dropped existing FK % on %.%', v_existing, p_table, p_col;
    end if;

    if not exists (
        select 1 from information_schema.table_constraints
        where constraint_name = p_fk_name and table_name = p_table and table_schema='public'
    ) then
        execute format(
            'alter table public.%I add constraint %I foreign key (%I) '
            || 'references auth.users(id) on delete set null not valid',
            p_table, p_fk_name, p_col);
        raise notice 'D1: added SET NULL FK % on %.%', p_fk_name, p_table, p_col;
    end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.sph_anonymize_dispatcher(p_uid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_dispatcher_profile_ids uuid[] := '{}'::uuid[];
begin
    -- Guard: only the service_role (Edge Function) or a platform admin may run this.
    if not (
        coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
        or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'), '') = 'service_role'
        or coalesce(auth.role()::text, '') = 'service_role'
        or public.sph_dispatch_is_platform_admin()
    ) then
        raise exception 'not authorized to anonymize dispatcher %', p_uid;
    end if;

    if to_regclass('public.dispatcher_profiles') is not null then
        select coalesce(array_agg(id), '{}'::uuid[])
        into v_dispatcher_profile_ids
        from public.dispatcher_profiles
        where user_id = p_uid;
    end if;

    -- dispatcher_reviews: keep rating/aggregate, drop free-text review comment.
    -- Staging schema has no auth user column here; target by retained profile id.
    if to_regclass('public.dispatcher_reviews') is not null then
        begin
            update public.dispatcher_reviews set
                comment = null
            where dispatcher_profile_id = any(v_dispatcher_profile_ids);
        exception when undefined_column then
            raise notice 'D1: dispatcher_reviews column mismatch -- confirm names; partial anonymize.';
        end;
    end if;

    -- payment/fee/invoice tracking: keep financial figures, strip embedded PII
    -- and clear the individual dispatcher user link. Never touch company_id.
    if to_regclass('public.dispatcher_payment_records') is not null then
        begin
            update public.dispatcher_payment_records set
                dispatcher_user_id = null,
                dispatcher_name    = null,
                dispatcher_company = null,
                notes              = null
            where dispatcher_user_id = p_uid
               or dispatcher_profile_id = any(v_dispatcher_profile_ids);
        exception when undefined_column then
            raise notice 'D1: dispatcher_payment_records column mismatch -- confirm names; partial anonymize.';
        end;
    end if;

    if to_regclass('public.dispatcher_fee_records') is not null then
        begin
            update public.dispatcher_fee_records set
                dispatcher_user_id = null,
                notes              = null
            where dispatcher_user_id = p_uid
               or dispatcher_profile_id = any(v_dispatcher_profile_ids);
        exception when undefined_column then
            raise notice 'D1: dispatcher_fee_records column mismatch -- confirm names; partial anonymize.';
        end;
    end if;

    if to_regclass('public.dispatcher_invoices') is not null then
        begin
            update public.dispatcher_invoices set
                dispatcher_user_id = null,
                notes              = null
            where dispatcher_user_id = p_uid
               or dispatcher_profile_id = any(v_dispatcher_profile_ids);
        exception when undefined_column then
            raise notice 'D1: dispatcher_invoices column mismatch -- confirm names; partial anonymize.';
        end;
    end if;

    -- dispatcher_profiles: strip PII, deactivate, keep the row + aggregates.
    -- Staging column names confirmed 2026-06-03; guarded so a future schema drift
    -- never aborts the whole deletion.
    if to_regclass('public.dispatcher_profiles') is not null then
        begin
            update public.dispatcher_profiles set
                user_id       = null,
                display_name  = 'Deleted dispatcher',
                company_name  = null,
                phone         = null,
                email         = null,
                is_active     = false
            where user_id = p_uid;
        exception when undefined_column then
            raise notice 'D1: dispatcher_profiles column mismatch -- confirm names; partial anonymize.';
        end;
    end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sph_conn_is_accepted_member(p_connection_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select exists (
        select 1 from public.user_connections c
        where c.id = p_connection_id
          and c.status = 'accepted'
          and (c.requester_id = auth.uid() or c.recipient_id = auth.uid())
    );
$function$
;

CREATE OR REPLACE FUNCTION public.sph_conn_touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
    new.updated_at := now();
    return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sph_dispatch_caller_muted_out(target_thread_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.dispatch_participants p
    where p.thread_id = target_thread_id
    and p.profile_id = auth.uid()
    and p.participant_status in ('left', 'blocked')
  );
$function$
;

CREATE OR REPLACE FUNCTION public.sph_dispatch_mark_read(p_thread_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_company uuid;
  v_role text;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select t.company_id into v_company
  from public.dispatch_threads t
  where t.id = p_thread_id;

  if v_company is null then
    return;
  end if;

  if not public.sph_dispatch_can_access_thread(p_thread_id, v_company)
     and not public.sph_dispatch_is_platform_admin() then
    raise exception 'not authorized for thread %', p_thread_id;
  end if;

  v_role := public.sph_current_account_role();

  update public.dispatch_messages m
  set read_at = now()
  where m.thread_id = p_thread_id
    and m.sender_profile_id <> v_uid
    and m.read_at is null;

  insert into public.message_reads (message_id, conversation_id, profile_id, read_at)
  select m.id, m.thread_id, v_uid, now()
  from public.dispatch_messages m
  where m.thread_id = p_thread_id
    and m.sender_profile_id <> v_uid
  on conflict (message_id, profile_id) do nothing;

  if v_role = 'dispatcher' then
    update public.dispatch_threads set dispatcher_unread_count = 0 where id = p_thread_id;
  elsif v_role = 'driver' then
    update public.dispatch_threads set driver_unread_count = 0 where id = p_thread_id;
  elsif v_role in ('carrier', 'owner_operator') then
    update public.dispatch_threads set carrier_unread_count = 0 where id = p_thread_id;
  end if;

  update public.dispatch_participants p
  set last_read_at = now(),
      last_read_message_id = (
        select m.id from public.dispatch_messages m
        where m.thread_id = p_thread_id
        order by m.created_at desc
        limit 1
      )
  where p.thread_id = p_thread_id
    and p.profile_id = v_uid;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sph_find_connectable_user(p_email text)
 RETURNS TABLE(user_id uuid, account_role text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
    v_caller_role text;
    v_target_id   uuid;
    v_target_role text;
begin
    v_caller_role := public.sph_current_account_role();
    if v_caller_role is null then
        return;                                  -- caller has no role
    end if;

    select u.id into v_target_id
        from auth.users u
        where lower(u.email) = lower(btrim(p_email))
        limit 1;
    if v_target_id is null then
        return;                                  -- no such user
    end if;
    if v_target_id = auth.uid() then
        return;                                  -- cannot connect to self
    end if;

    select p.account_role into v_target_role
        from public.profiles p where p.id = v_target_id;
    if v_target_role is null then
        return;                                  -- target has no role
    end if;

    -- opposite-side rule: exactly one of {caller, target} is a dispatcher
    if (v_caller_role = 'dispatcher') = (v_target_role = 'dispatcher') then
        return;                                  -- same side -> not connectable
    end if;

    user_id := v_target_id;
    account_role := v_target_role;
    return next;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sph_notify_dispatch_push()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_url text;
  v_key text;
begin
  select value into v_url from public.sph_edge_config where key = 'dispatch_push_url';
  select value into v_key from public.sph_edge_config where key = 'service_role_key';
  if v_url is null or v_key is null then
    return new;
  end if;
  if exists (select 1 from pg_proc where pronamespace = (select oid from pg_namespace where nspname = 'net') and proname = 'http_post') then
    perform net.http_post(
      url := v_url,
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer '||v_key),
      body := jsonb_build_object('type','INSERT','table','dispatch_messages',
              'record', to_jsonb(new))
    );
  end if;
  return new;
exception when others then
  return new;
end;
$function$
;


-- ---------------------------------------------------------------------
-- 8. Row level security.
-- ---------------------------------------------------------------------
alter table public.connection_messages enable row level security;
alter table public.dispatch_device_tokens enable row level security;
alter table public.message_reads enable row level security;
alter table public.notifications enable row level security;
alter table public.sph_edge_config enable row level security;
alter table public.user_connections enable row level security;

-- 8b. Replica identity FULL (production setting for realtime old-row payloads).
--     Guarded: does nothing when already FULL.
do $sph$
begin
  if (select relreplident from pg_class where oid = 'public.connection_messages'::regclass) <> 'f' then
    alter table public.connection_messages replica identity full;
  end if;
  if (select relreplident from pg_class where oid = 'public.user_connections'::regclass) <> 'f' then
    alter table public.user_connections replica identity full;
  end if;
end
$sph$;

-- ---------------------------------------------------------------------
-- 9. Policies (new tables, plus the two dispatch select policies production
--    uses in inline form).
-- ---------------------------------------------------------------------
drop policy if exists "messages insert accepted members" on public.connection_messages;
create policy "messages insert accepted members" on public.connection_messages
  as permissive for insert to public
  with check (((sender_id = auth.uid()) AND sph_conn_is_accepted_member(connection_id)));

drop policy if exists "messages select accepted members" on public.connection_messages;
create policy "messages select accepted members" on public.connection_messages
  as permissive for select to public
  using (sph_conn_is_accepted_member(connection_id));

drop policy if exists "messages update read members" on public.connection_messages;
create policy "messages update read members" on public.connection_messages
  as permissive for update to public
  using (sph_conn_is_accepted_member(connection_id))
  with check (sph_conn_is_accepted_member(connection_id));

drop policy if exists "dispatch agreements scoped select" on public.dispatch_agreements;
create policy "dispatch agreements scoped select" on public.dispatch_agreements
  as permissive for select to public
  using (((carrier_profile_id = auth.uid()) OR (dispatcher_user_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM dispatcher_profiles dp
  WHERE ((dp.id = dispatch_agreements.dispatcher_profile_id) AND (dp.user_id = auth.uid())))) OR sph_dispatch_is_company_admin(company_id)));

drop policy if exists "device tokens self delete" on public.dispatch_device_tokens;
create policy "device tokens self delete" on public.dispatch_device_tokens
  as permissive for delete to public
  using ((profile_id = auth.uid()));

drop policy if exists "device tokens self insert" on public.dispatch_device_tokens;
create policy "device tokens self insert" on public.dispatch_device_tokens
  as permissive for insert to public
  with check ((profile_id = auth.uid()));

drop policy if exists "device tokens self select" on public.dispatch_device_tokens;
create policy "device tokens self select" on public.dispatch_device_tokens
  as permissive for select to public
  using (((profile_id = auth.uid()) OR sph_dispatch_is_platform_admin()));

drop policy if exists "device tokens self update" on public.dispatch_device_tokens;
create policy "device tokens self update" on public.dispatch_device_tokens
  as permissive for update to public
  using ((profile_id = auth.uid()))
  with check ((profile_id = auth.uid()));

drop policy if exists "dispatch threads scoped select" on public.dispatch_threads;
create policy "dispatch threads scoped select" on public.dispatch_threads
  as permissive for select to public
  using (((company_id = auth.uid()) OR (driver_profile_id = auth.uid()) OR (dispatcher_user_id = auth.uid()) OR ((agreement_id IS NOT NULL) AND sph_dispatch_can_access_agreement(agreement_id, company_id)) OR (EXISTS ( SELECT 1
   FROM dispatch_participants p
  WHERE ((p.company_id = dispatch_threads.company_id) AND ((p.thread_id = dispatch_threads.id) OR (p.thread_id IS NULL)) AND (p.profile_id = auth.uid()) AND (p.is_active = true)))) OR sph_dispatch_is_company_admin(company_id)));

drop policy if exists "message reads scoped select" on public.message_reads;
create policy "message reads scoped select" on public.message_reads
  as permissive for select to public
  using (((profile_id = auth.uid()) OR sph_dispatch_can_access_thread(conversation_id, ( SELECT t.company_id
   FROM dispatch_threads t
  WHERE (t.id = message_reads.conversation_id))) OR sph_dispatch_is_platform_admin()));

drop policy if exists "message reads self insert" on public.message_reads;
create policy "message reads self insert" on public.message_reads
  as permissive for insert to public
  with check (((profile_id = auth.uid()) AND sph_dispatch_can_access_thread(conversation_id, ( SELECT t.company_id
   FROM dispatch_threads t
  WHERE (t.id = message_reads.conversation_id)))));

drop policy if exists "message reads self update" on public.message_reads;
create policy "message reads self update" on public.message_reads
  as permissive for update to public
  using ((profile_id = auth.uid()))
  with check ((profile_id = auth.uid()));

drop policy if exists "notifications admin insert" on public.notifications;
create policy "notifications admin insert" on public.notifications
  as permissive for insert to public
  with check (sph_dispatch_is_platform_admin());

drop policy if exists "notifications recipient select" on public.notifications;
create policy "notifications recipient select" on public.notifications
  as permissive for select to public
  using (((recipient_profile_id = auth.uid()) OR sph_dispatch_is_platform_admin()));

drop policy if exists "notifications recipient update" on public.notifications;
create policy "notifications recipient update" on public.notifications
  as permissive for update to public
  using ((recipient_profile_id = auth.uid()))
  with check ((recipient_profile_id = auth.uid()));

drop policy if exists "connections insert as requester" on public.user_connections;
create policy "connections insert as requester" on public.user_connections
  as permissive for insert to public
  with check (((requester_id = auth.uid()) AND (requester_role = sph_current_account_role()) AND (status = 'pending'::text)));

drop policy if exists "connections recipient updates" on public.user_connections;
create policy "connections recipient updates" on public.user_connections
  as permissive for update to public
  using ((recipient_id = auth.uid()))
  with check ((recipient_id = auth.uid()));

drop policy if exists "connections requester cancels pending" on public.user_connections;
create policy "connections requester cancels pending" on public.user_connections
  as permissive for delete to public
  using (((requester_id = auth.uid()) AND (status = 'pending'::text)));

drop policy if exists "connections select own" on public.user_connections;
create policy "connections select own" on public.user_connections
  as permissive for select to public
  using (((requester_id = auth.uid()) OR (recipient_id = auth.uid())));


-- ---------------------------------------------------------------------
-- 10. Triggers.
-- ---------------------------------------------------------------------
drop trigger if exists trg_dispatch_message_push on public.dispatch_messages;
CREATE TRIGGER trg_dispatch_message_push AFTER INSERT ON public.dispatch_messages FOR EACH ROW EXECUTE FUNCTION sph_notify_dispatch_push();

drop trigger if exists trg_user_connections_touch on public.user_connections;
CREATE TRIGGER trg_user_connections_touch BEFORE UPDATE ON public.user_connections FOR EACH ROW EXECUTE FUNCTION sph_conn_touch_updated_at();


-- ---------------------------------------------------------------------
-- 11. Comments.
-- ---------------------------------------------------------------------
comment on function public.sph_anonymize_dispatcher(uuid) is 'GAP D-1 (anonymize policy): strip PII from a dispatcher''s retained directory/tracking rows. service_role only.';
comment on table public.connection_messages is 'Messages for an accepted user_connections row. RLS: only accepted members can read/insert.';
comment on table public.user_connections is 'Dispatcher<->Driver-side connection invites. status: pending/accepted/declined/blocked. Exactly one party is a dispatcher.';

-- ---------------------------------------------------------------------
-- 12. Table and view privileges, exactly as production has them today.
--     20260611192931 re-applies its own revokes/grants after this file.
-- ---------------------------------------------------------------------
revoke all on table public.activity_log from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.activity_log to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.activity_log to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.activity_log to service_role;

revoke all on table public.broker_contacts from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.broker_contacts to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.broker_contacts to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.broker_contacts to service_role;

revoke all on table public.brokers from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.brokers to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.brokers to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.brokers to service_role;

revoke all on table public.carrier_invites from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.carrier_invites to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.carrier_invites to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.carrier_invites to service_role;

revoke all on table public.carrier_members from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.carrier_members to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.carrier_members to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.carrier_members to service_role;

revoke all on table public.compliance_documents from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.compliance_documents to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.compliance_documents to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.compliance_documents to service_role;

revoke all on table public.connection_messages from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.connection_messages to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.connection_messages to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.connection_messages to service_role;

revoke all on table public.daily_inspections from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.daily_inspections to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.daily_inspections to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.daily_inspections to service_role;

revoke all on table public.dispatch_agreements from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_agreements to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_agreements to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_agreements to service_role;

revoke all on table public.dispatch_device_tokens from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_device_tokens to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_device_tokens to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_device_tokens to service_role;

revoke all on table public.dispatch_load_offers from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_load_offers to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_load_offers to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_load_offers to service_role;

revoke all on table public.dispatch_messages from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_messages to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_messages to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_messages to service_role;

revoke all on table public.dispatch_participants from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_participants to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_participants to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_participants to service_role;

revoke all on table public.dispatch_service_requests from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_service_requests to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_service_requests to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_service_requests to service_role;

revoke all on table public.dispatch_threads from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_threads to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_threads to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatch_threads to service_role;

revoke all on table public.dispatcher_fee_records from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_fee_records to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_fee_records to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_fee_records to service_role;

revoke all on table public.dispatcher_invoices from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_invoices to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_invoices to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_invoices to service_role;

revoke all on table public.dispatcher_payment_records from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_payment_records to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_payment_records to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_payment_records to service_role;

revoke all on table public.dispatcher_profiles from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_profiles to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_profiles to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_profiles to service_role;

revoke all on table public.dispatcher_reviews from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_reviews to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_reviews to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.dispatcher_reviews to service_role;

revoke all on table public.documents from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.documents to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.documents to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.documents to service_role;

revoke all on table public.drivers from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.drivers to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.drivers to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.drivers to service_role;

revoke all on table public.expenses from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.expenses to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.expenses to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.expenses to service_role;

revoke all on table public.ifta_entries from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.ifta_entries to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.ifta_entries to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.ifta_entries to service_role;

revoke all on table public.loads from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.loads to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.loads to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.loads to service_role;

revoke all on table public.message_reads from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.message_reads to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.message_reads to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.message_reads to service_role;

revoke all on table public.notifications from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.notifications to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.notifications to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.notifications to service_role;

revoke all on table public.paystub_deductions from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_deductions to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_deductions to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_deductions to service_role;

revoke all on table public.paystub_earnings from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_earnings to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_earnings to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_earnings to service_role;

revoke all on table public.paystub_settlement_items from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_settlement_items to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_settlement_items to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_settlement_items to service_role;

revoke all on table public.paystub_taxes from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_taxes to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_taxes to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystub_taxes to service_role;

revoke all on table public.paystubs from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystubs to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystubs to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.paystubs to service_role;

revoke all on table public.profiles from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.profiles to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.profiles to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.profiles to service_role;

revoke all on table public.settlements from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.settlements to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.settlements to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.settlements to service_role;

revoke all on table public.sph_edge_config from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.sph_edge_config to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.sph_edge_config to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.sph_edge_config to service_role;

revoke all on table public.trailers from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.trailers to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.trailers to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.trailers to service_role;

revoke all on table public.trucks from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.trucks to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.trucks to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.trucks to service_role;

revoke all on table public.user_connections from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.user_connections to anon;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.user_connections to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.user_connections to service_role;

revoke all on table public.v_payroll_unified from public, anon, authenticated, service_role;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.v_payroll_unified to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update on table public.v_payroll_unified to service_role;


-- ---------------------------------------------------------------------
-- 13. Function privileges for every public function that has an explicit ACL
--     in production. Functions with the built-in default ACL are untouched.
-- ---------------------------------------------------------------------
revoke all on function public._sph_d1_recreate_user_setnull(text,text,text) from public, anon, authenticated, service_role;
grant execute on function public._sph_d1_recreate_user_setnull(text,text,text) to service_role;

revoke all on function public.accept_carrier_invite(text) from public, anon, authenticated, service_role;
grant execute on function public.accept_carrier_invite(text) to authenticated;
grant execute on function public.accept_carrier_invite(text) to service_role;

revoke all on function public.driver_dashboard_data(timestamp with time zone,timestamp with time zone) from public, anon, authenticated, service_role;
grant execute on function public.driver_dashboard_data(timestamp with time zone,timestamp with time zone) to authenticated;
grant execute on function public.driver_dashboard_data(timestamp with time zone,timestamp with time zone) to service_role;

revoke all on function public.handle_new_user() from public, anon, authenticated, service_role;
grant execute on function public.handle_new_user() to service_role;
grant execute on function public.handle_new_user() to supabase_auth_admin;

revoke all on function public.preview_carrier_invite(text) from public, anon, authenticated, service_role;
grant execute on function public.preview_carrier_invite(text) to authenticated;
grant execute on function public.preview_carrier_invite(text) to service_role;

revoke all on function public.rls_auto_enable() from public, anon, authenticated, service_role;
grant execute on function public.rls_auto_enable() to service_role;

revoke all on function public.set_documents_updated_at() from public, anon, authenticated, service_role;
grant execute on function public.set_documents_updated_at() to anon;
grant execute on function public.set_documents_updated_at() to authenticated;
grant execute on function public.set_documents_updated_at() to public;
grant execute on function public.set_documents_updated_at() to service_role;

revoke all on function public.set_updated_at() from public, anon, authenticated, service_role;
grant execute on function public.set_updated_at() to anon;
grant execute on function public.set_updated_at() to authenticated;
grant execute on function public.set_updated_at() to public;
grant execute on function public.set_updated_at() to service_role;

revoke all on function public.sph_anonymize_dispatcher(uuid) from public, anon, authenticated, service_role;
grant execute on function public.sph_anonymize_dispatcher(uuid) to service_role;

revoke all on function public.sph_conn_is_accepted_member(uuid) from public, anon, authenticated, service_role;
grant execute on function public.sph_conn_is_accepted_member(uuid) to authenticated;
grant execute on function public.sph_conn_is_accepted_member(uuid) to service_role;

revoke all on function public.sph_conn_touch_updated_at() from public, anon, authenticated, service_role;
grant execute on function public.sph_conn_touch_updated_at() to anon;
grant execute on function public.sph_conn_touch_updated_at() to authenticated;
grant execute on function public.sph_conn_touch_updated_at() to public;
grant execute on function public.sph_conn_touch_updated_at() to service_role;

revoke all on function public.sph_current_account_role() from public, anon, authenticated, service_role;
grant execute on function public.sph_current_account_role() to authenticated;
grant execute on function public.sph_current_account_role() to service_role;

revoke all on function public.sph_dispatch_caller_muted_out(uuid) from public, anon, authenticated, service_role;
grant execute on function public.sph_dispatch_caller_muted_out(uuid) to authenticated;
grant execute on function public.sph_dispatch_caller_muted_out(uuid) to service_role;

revoke all on function public.sph_dispatch_can_access_agreement(uuid,uuid) from public, anon, authenticated, service_role;
grant execute on function public.sph_dispatch_can_access_agreement(uuid,uuid) to authenticated;
grant execute on function public.sph_dispatch_can_access_agreement(uuid,uuid) to service_role;

revoke all on function public.sph_dispatch_can_access_thread(uuid,uuid) from public, anon, authenticated, service_role;
grant execute on function public.sph_dispatch_can_access_thread(uuid,uuid) to authenticated;
grant execute on function public.sph_dispatch_can_access_thread(uuid,uuid) to service_role;

revoke all on function public.sph_dispatch_is_company_admin(uuid) from public, anon, authenticated, service_role;
grant execute on function public.sph_dispatch_is_company_admin(uuid) to authenticated;
grant execute on function public.sph_dispatch_is_company_admin(uuid) to service_role;

revoke all on function public.sph_dispatch_is_platform_admin() from public, anon, authenticated, service_role;
grant execute on function public.sph_dispatch_is_platform_admin() to authenticated;
grant execute on function public.sph_dispatch_is_platform_admin() to service_role;

revoke all on function public.sph_dispatch_mark_read(uuid) from public, anon, authenticated, service_role;
grant execute on function public.sph_dispatch_mark_read(uuid) to authenticated;
grant execute on function public.sph_dispatch_mark_read(uuid) to service_role;

revoke all on function public.sph_find_connectable_user(text) from public, anon, authenticated, service_role;
grant execute on function public.sph_find_connectable_user(text) to authenticated;
grant execute on function public.sph_find_connectable_user(text) to service_role;

revoke all on function public.sph_notify_dispatch_push() from public, anon, authenticated, service_role;
grant execute on function public.sph_notify_dispatch_push() to service_role;

revoke all on function public.sph_sync_load_driver_mode_columns() from public, anon, authenticated, service_role;
grant execute on function public.sph_sync_load_driver_mode_columns() to anon;
grant execute on function public.sph_sync_load_driver_mode_columns() to authenticated;
grant execute on function public.sph_sync_load_driver_mode_columns() to public;
grant execute on function public.sph_sync_load_driver_mode_columns() to service_role;

revoke all on function public.sph_sync_profile_account_role_from_auth() from public, anon, authenticated, service_role;
grant execute on function public.sph_sync_profile_account_role_from_auth() to service_role;
grant execute on function public.sph_sync_profile_account_role_from_auth() to supabase_auth_admin;


-- ---------------------------------------------------------------------
-- 14. Default privileges for objects postgres creates in schema public,
--     exactly as production has them. New hosted branches start without
--     these, which leaves app tables unreadable through the Data API.
-- ---------------------------------------------------------------------
alter default privileges for role postgres in schema public revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant select, update, usage on sequences to anon;
alter default privileges for role postgres in schema public grant select, update, usage on sequences to authenticated;
alter default privileges for role postgres in schema public grant select, update, usage on sequences to service_role;

alter default privileges for role postgres in schema public revoke all on functions from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant execute on functions to anon;
alter default privileges for role postgres in schema public grant execute on functions to authenticated;
alter default privileges for role postgres in schema public grant execute on functions to service_role;

alter default privileges for role postgres in schema public revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant delete, insert, maintain, references, select, trigger, truncate, update on tables to anon;
alter default privileges for role postgres in schema public grant delete, insert, maintain, references, select, trigger, truncate, update on tables to authenticated;
alter default privileges for role postgres in schema public grant delete, insert, maintain, references, select, trigger, truncate, update on tables to service_role;


-- ---------------------------------------------------------------------
-- 15. Realtime publication membership (skipped when the publication is absent).
-- ---------------------------------------------------------------------
do $sph$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'connection_messages') then
    alter publication supabase_realtime add table public.connection_messages;
  end if;
end
$sph$;

do $sph$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'user_connections') then
    alter publication supabase_realtime add table public.user_connections;
  end if;
end
$sph$;


-- ---------------------------------------------------------------------
-- 16. Storage bucket definition only. No objects are created.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('config', 'config', true) on conflict (id) do nothing;
