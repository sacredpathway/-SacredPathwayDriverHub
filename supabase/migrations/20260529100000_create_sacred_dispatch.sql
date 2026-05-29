-- Sacred DISPATCH Network
-- Marketplace, dispatch agreements, dispatcher revenue protection, invoice
-- tracking, settlement/OCR fee records, and future payment automation hooks.
-- All load columns are nullable so existing rows remain unchanged.

create extension if not exists pgcrypto;

alter table public.loads
    add column if not exists dispatch_thread_id uuid,
    add column if not exists dispatch_load_offer_id uuid,
    add column if not exists dispatcher_name text,
    add column if not exists dispatcher_company text;

create unique index if not exists loads_dispatch_load_offer_id_unique
    on public.loads (dispatch_load_offer_id)
    where dispatch_load_offer_id is not null;

create table if not exists public.dispatcher_profiles (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    user_id uuid not null,
    display_name text,
    company_name text,
    years_experience integer,
    equipment_types text[] not null default '{}',
    service_regions text[] not null default '{}',
    languages_spoken text[] not null default '{}',
    services_offered text[] not null default '{}',
    phone text,
    email text,
    contact_info text,
    is_active boolean not null default true,
    is_trusted boolean not null default false,
    platform_fee_percentage numeric,
    rating_average numeric not null default 0,
    rating_count integer not null default 0,
    future_payment_provider text,
    future_payment_account_id text,
    future_payment_ready boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (company_id, user_id)
);

alter table public.dispatcher_profiles
    add column if not exists years_experience integer,
    add column if not exists equipment_types text[] not null default '{}',
    add column if not exists service_regions text[] not null default '{}',
    add column if not exists languages_spoken text[] not null default '{}',
    add column if not exists services_offered text[] not null default '{}',
    add column if not exists contact_info text,
    add column if not exists is_active boolean not null default true,
    add column if not exists future_payment_provider text,
    add column if not exists future_payment_account_id text,
    add column if not exists future_payment_ready boolean not null default false;

create table if not exists public.dispatcher_reviews (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    dispatcher_profile_id uuid not null references public.dispatcher_profiles(id) on delete cascade,
    carrier_profile_id uuid,
    rating integer not null check (rating between 1 and 5),
    comment text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.dispatch_participants (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    thread_id uuid,
    profile_id uuid not null,
    role text not null check (role in ('driver', 'dispatcher', 'carrier', 'admin')),
    display_name text,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.dispatch_service_requests (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    requested_by_profile_id uuid not null,
    dispatcher_profile_id uuid references public.dispatcher_profiles(id) on delete set null,
    dispatcher_user_id uuid,
    carrier_name text,
    service_notes text,
    status text not null default 'open'
        check (status in ('open', 'pending', 'accepted', 'declined', 'cancelled')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.dispatch_agreements (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    carrier_profile_id uuid not null,
    dispatcher_profile_id uuid not null references public.dispatcher_profiles(id) on delete restrict,
    dispatcher_user_id uuid,
    carrier_name text,
    dispatcher_name text,
    dispatcher_company text,
    effective_date date,
    fee_type text not null check (
        fee_type in ('percentage_gross', 'flat_per_load', 'weekly_fixed', 'monthly_fixed', 'flat', 'percentage')
    ),
    fee_percentage numeric,
    fee_amount numeric,
    status text not null default 'pending'
        check (status in ('draft', 'pending', 'active', 'paused', 'terminated')),
    notes text,
    future_payment_provider text,
    future_payment_method_id text,
    future_auto_collect_enabled boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.dispatch_threads (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    load_offer_id uuid,
    accepted_load_id uuid references public.loads(id) on delete set null,
    agreement_id uuid references public.dispatch_agreements(id) on delete set null,
    load_number text,
    driver_profile_id uuid,
    dispatcher_user_id uuid,
    dispatcher_name text,
    dispatcher_company text,
    subject text,
    last_message_preview text,
    driver_unread_count integer not null default 0,
    dispatcher_unread_count integer not null default 0,
    carrier_unread_count integer not null default 0,
    last_message_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.dispatch_messages (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    thread_id uuid not null references public.dispatch_threads(id) on delete cascade,
    load_offer_id uuid,
    sender_profile_id uuid not null,
    sender_role text not null check (sender_role in ('driver', 'dispatcher', 'carrier', 'admin')),
    sender_name text,
    body text not null,
    kind text not null default 'text' check (kind in ('text', 'load_offer', 'status')),
    read_at timestamptz,
    created_at timestamptz not null default now()
);

create table if not exists public.dispatch_load_offers (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    thread_id uuid,
    dispatcher_profile_id uuid references public.dispatcher_profiles(id) on delete set null,
    dispatcher_user_id uuid,
    driver_profile_id uuid,
    driver_id uuid,
    agreement_id uuid references public.dispatch_agreements(id) on delete set null,
    dispatcher_name text,
    dispatcher_company text,
    load_number text,
    broker_name text,
    broker_mc_number text,
    broker_phone text,
    broker_email text,
    pickup_date date,
    delivery_date date,
    origin text,
    destination text,
    total_miles numeric,
    line_haul_rate numeric,
    fuel_surcharge numeric,
    accessorial_charges numeric,
    load_gross_amount numeric,
    fee_type text not null default 'flat'
        check (fee_type in ('flat', 'percentage', 'percentage_gross', 'flat_per_load')),
    fee_amount numeric,
    fee_percentage numeric,
    invoice_cadence text not null default 'weekly' check (invoice_cadence in ('weekly', 'monthly')),
    due_date date,
    notes text,
    status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'cancelled')),
    accepted_load_id uuid references public.loads(id) on delete set null,
    accepted_at timestamptz,
    declined_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.dispatcher_payment_records (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    dispatcher_profile_id uuid references public.dispatcher_profiles(id) on delete set null,
    dispatcher_user_id uuid,
    driver_profile_id uuid,
    load_id uuid references public.loads(id) on delete set null,
    load_offer_id uuid,
    thread_id uuid,
    dispatcher_name text,
    dispatcher_company text,
    load_number text,
    load_gross_amount numeric not null default 0,
    fee_type text not null check (fee_type in ('flat', 'percentage')),
    fee_amount numeric,
    fee_percentage numeric,
    calculated_dispatch_fee numeric not null default 0,
    invoice_cadence text not null default 'weekly' check (invoice_cadence in ('weekly', 'monthly')),
    payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'pending', 'paid', 'overdue')),
    due_date date,
    notes text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    paid_at timestamptz
);

create table if not exists public.dispatcher_invoices (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    agreement_id uuid references public.dispatch_agreements(id) on delete set null,
    dispatcher_profile_id uuid references public.dispatcher_profiles(id) on delete set null,
    dispatcher_user_id uuid,
    carrier_profile_id uuid,
    invoice_number text,
    period_start date,
    period_end date,
    total_gross_revenue numeric not null default 0,
    total_fees_due numeric not null default 0,
    payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'pending', 'paid', 'overdue')),
    due_date date,
    payment_date date,
    notes text,
    future_payment_intent_id text,
    future_payment_provider text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.dispatcher_fee_records (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    agreement_id uuid references public.dispatch_agreements(id) on delete set null,
    dispatcher_profile_id uuid references public.dispatcher_profiles(id) on delete set null,
    dispatcher_user_id uuid,
    carrier_profile_id uuid,
    load_id uuid references public.loads(id) on delete set null,
    settlement_document_id uuid,
    invoice_id uuid references public.dispatcher_invoices(id) on delete set null,
    load_number text,
    broker_name text,
    gross_revenue numeric not null default 0,
    payment_amount numeric,
    fee_type text not null check (
        fee_type in ('percentage_gross', 'flat_per_load', 'weekly_fixed', 'monthly_fixed', 'flat', 'percentage')
    ),
    fee_percentage numeric,
    fee_amount numeric,
    calculated_dispatch_fee numeric not null default 0,
    payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'pending', 'paid', 'overdue')),
    due_date date,
    payment_date date,
    notes text,
    source_type text,
    ocr_confidence numeric,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_dispatcher_profiles_active on public.dispatcher_profiles (is_active);
create index if not exists idx_dispatcher_profiles_company on public.dispatcher_profiles (company_id);
create index if not exists idx_dispatcher_profiles_user on public.dispatcher_profiles (user_id);
create index if not exists idx_dispatcher_reviews_profile on public.dispatcher_reviews (dispatcher_profile_id);
create index if not exists idx_dispatch_participants_company_profile on public.dispatch_participants (company_id, profile_id);
create index if not exists idx_dispatch_participants_thread on public.dispatch_participants (thread_id);
create index if not exists idx_dispatch_requests_dispatcher on public.dispatch_service_requests (dispatcher_profile_id, status);
create index if not exists idx_dispatch_requests_company_status on public.dispatch_service_requests (company_id, status);
create index if not exists idx_dispatch_agreements_company_status on public.dispatch_agreements (company_id, status);
create index if not exists idx_dispatch_agreements_dispatcher on public.dispatch_agreements (dispatcher_profile_id, status);
create index if not exists idx_dispatch_threads_company on public.dispatch_threads (company_id);
create index if not exists idx_dispatch_threads_driver on public.dispatch_threads (driver_profile_id);
create index if not exists idx_dispatch_threads_dispatcher on public.dispatch_threads (dispatcher_user_id);
create index if not exists idx_dispatch_messages_thread_created on public.dispatch_messages (thread_id, created_at);
create index if not exists idx_dispatch_offers_company_status on public.dispatch_load_offers (company_id, status);
create index if not exists idx_dispatch_offers_driver on public.dispatch_load_offers (driver_profile_id);
create index if not exists idx_dispatch_payments_company_status on public.dispatcher_payment_records (company_id, payment_status);
create index if not exists idx_dispatch_fee_records_company_status on public.dispatcher_fee_records (company_id, payment_status);
create index if not exists idx_dispatch_fee_records_agreement on public.dispatcher_fee_records (agreement_id, created_at);
create index if not exists idx_dispatch_invoices_company_status on public.dispatcher_invoices (company_id, payment_status);
create index if not exists idx_dispatch_invoices_agreement_period on public.dispatcher_invoices (agreement_id, period_start, period_end);

create unique index if not exists dispatcher_payment_records_offer_unique
    on public.dispatcher_payment_records (load_offer_id)
    where load_offer_id is not null;

create unique index if not exists dispatcher_fee_records_agreement_load_unique
    on public.dispatcher_fee_records (agreement_id, load_number)
    where agreement_id is not null and load_number is not null;

create or replace function public.sph_dispatch_is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select coalesce((auth.jwt() -> 'app_metadata' ->> 'sacred_admin')::boolean, false);
$$;

create or replace function public.sph_dispatch_is_company_admin(target_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select auth.uid() is not null
       and (
            public.sph_dispatch_is_platform_admin()
            or target_company_id = auth.uid()
            or exists (
                select 1
                from public.dispatch_participants p
                where p.company_id = target_company_id
                  and p.profile_id = auth.uid()
                  and p.role in ('carrier', 'admin')
                  and p.is_active = true
            )
       );
$$;

create or replace function public.sph_dispatch_can_access_agreement(target_agreement_id uuid, target_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select auth.uid() is not null
       and (
            public.sph_dispatch_is_company_admin(target_company_id)
            or exists (
                select 1
                from public.dispatch_agreements a
                where a.id = target_agreement_id
                  and a.company_id = target_company_id
                  and (
                    a.carrier_profile_id = auth.uid()
                    or a.dispatcher_user_id = auth.uid()
                    or exists (
                        select 1
                        from public.dispatcher_profiles dp
                        where dp.id = a.dispatcher_profile_id
                          and dp.user_id = auth.uid()
                    )
                  )
            )
       );
$$;

create or replace function public.sph_dispatch_can_access_thread(target_thread_id uuid, target_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select auth.uid() is not null
       and (
            public.sph_dispatch_is_company_admin(target_company_id)
            or exists (
                select 1
                from public.dispatch_threads t
                where t.id = target_thread_id
                  and t.company_id = target_company_id
                  and (
                    t.driver_profile_id = auth.uid()
                    or t.dispatcher_user_id = auth.uid()
                    or (
                        t.agreement_id is not null
                        and public.sph_dispatch_can_access_agreement(t.agreement_id, t.company_id)
                    )
                    or exists (
                        select 1
                        from public.dispatch_participants p
                        where p.company_id = target_company_id
                          and (p.thread_id = target_thread_id or p.thread_id is null)
                          and p.profile_id = auth.uid()
                          and p.is_active = true
                    )
                  )
            )
       );
$$;

alter table public.dispatcher_profiles enable row level security;
alter table public.dispatcher_reviews enable row level security;
alter table public.dispatch_participants enable row level security;
alter table public.dispatch_service_requests enable row level security;
alter table public.dispatch_agreements enable row level security;
alter table public.dispatch_threads enable row level security;
alter table public.dispatch_messages enable row level security;
alter table public.dispatch_load_offers enable row level security;
alter table public.dispatcher_payment_records enable row level security;
alter table public.dispatcher_fee_records enable row level security;
alter table public.dispatcher_invoices enable row level security;

drop policy if exists "dispatcher profiles marketplace select" on public.dispatcher_profiles;
create policy "dispatcher profiles marketplace select"
on public.dispatcher_profiles for select
using (
    auth.uid() is not null
    and (
        is_active = true
        or user_id = auth.uid()
        or public.sph_dispatch_is_company_admin(company_id)
    )
);

drop policy if exists "dispatcher profiles scoped insert" on public.dispatcher_profiles;
create policy "dispatcher profiles scoped insert"
on public.dispatcher_profiles for insert
with check (user_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id));

drop policy if exists "dispatcher profiles scoped update" on public.dispatcher_profiles;
create policy "dispatcher profiles scoped update"
on public.dispatcher_profiles for update
using (user_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id))
with check (user_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id));

drop policy if exists "dispatcher reviews scoped select" on public.dispatcher_reviews;
create policy "dispatcher reviews scoped select"
on public.dispatcher_reviews for select
using (
    auth.uid() is not null
    and (
        public.sph_dispatch_is_company_admin(company_id)
        or carrier_profile_id = auth.uid()
        or exists (
            select 1 from public.dispatcher_profiles dp
            where dp.id = dispatcher_reviews.dispatcher_profile_id
              and (dp.is_active = true or dp.user_id = auth.uid())
        )
    )
);

drop policy if exists "dispatcher reviews scoped insert" on public.dispatcher_reviews;
create policy "dispatcher reviews scoped insert"
on public.dispatcher_reviews for insert
with check (carrier_profile_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id));

drop policy if exists "dispatch participants scoped select" on public.dispatch_participants;
create policy "dispatch participants scoped select"
on public.dispatch_participants for select
using (profile_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id));

drop policy if exists "dispatch participants scoped insert" on public.dispatch_participants;
create policy "dispatch participants scoped insert"
on public.dispatch_participants for insert
with check (profile_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id));

drop policy if exists "dispatch participants scoped update" on public.dispatch_participants;
create policy "dispatch participants scoped update"
on public.dispatch_participants for update
using (profile_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id))
with check (profile_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id));

drop policy if exists "dispatch requests scoped select" on public.dispatch_service_requests;
create policy "dispatch requests scoped select"
on public.dispatch_service_requests for select
using (
    requested_by_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch requests scoped insert" on public.dispatch_service_requests;
create policy "dispatch requests scoped insert"
on public.dispatch_service_requests for insert
with check (requested_by_profile_id = auth.uid() or public.sph_dispatch_is_company_admin(company_id));

drop policy if exists "dispatch requests scoped update" on public.dispatch_service_requests;
create policy "dispatch requests scoped update"
on public.dispatch_service_requests for update
using (
    requested_by_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
)
with check (
    requested_by_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch agreements scoped select" on public.dispatch_agreements;
create policy "dispatch agreements scoped select"
on public.dispatch_agreements for select
using (public.sph_dispatch_can_access_agreement(id, company_id));

drop policy if exists "dispatch agreements scoped insert" on public.dispatch_agreements;
create policy "dispatch agreements scoped insert"
on public.dispatch_agreements for insert
with check (
    carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch agreements scoped update" on public.dispatch_agreements;
create policy "dispatch agreements scoped update"
on public.dispatch_agreements for update
using (public.sph_dispatch_can_access_agreement(id, company_id))
with check (public.sph_dispatch_can_access_agreement(id, company_id));

drop policy if exists "dispatch threads scoped select" on public.dispatch_threads;
create policy "dispatch threads scoped select"
on public.dispatch_threads for select
using (public.sph_dispatch_can_access_thread(id, company_id));

drop policy if exists "dispatch threads scoped insert" on public.dispatch_threads;
create policy "dispatch threads scoped insert"
on public.dispatch_threads for insert
with check (
    company_id = auth.uid()
    or driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch threads scoped update" on public.dispatch_threads;
create policy "dispatch threads scoped update"
on public.dispatch_threads for update
using (public.sph_dispatch_can_access_thread(id, company_id))
with check (public.sph_dispatch_can_access_thread(id, company_id));

drop policy if exists "dispatch messages scoped select" on public.dispatch_messages;
create policy "dispatch messages scoped select"
on public.dispatch_messages for select
using (public.sph_dispatch_can_access_thread(thread_id, company_id));

drop policy if exists "dispatch messages scoped insert" on public.dispatch_messages;
create policy "dispatch messages scoped insert"
on public.dispatch_messages for insert
with check (
    sender_profile_id = auth.uid()
    and public.sph_dispatch_can_access_thread(thread_id, company_id)
);

drop policy if exists "dispatch messages scoped update" on public.dispatch_messages;
create policy "dispatch messages scoped update"
on public.dispatch_messages for update
using (public.sph_dispatch_can_access_thread(thread_id, company_id))
with check (public.sph_dispatch_can_access_thread(thread_id, company_id));

drop policy if exists "dispatch offers scoped select" on public.dispatch_load_offers;
create policy "dispatch offers scoped select"
on public.dispatch_load_offers for select
using (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch offers scoped insert" on public.dispatch_load_offers;
create policy "dispatch offers scoped insert"
on public.dispatch_load_offers for insert
with check (
    dispatcher_user_id = auth.uid()
    or driver_profile_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch offers scoped update" on public.dispatch_load_offers;
create policy "dispatch offers scoped update"
on public.dispatch_load_offers for update
using (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
)
with check (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch payments scoped select" on public.dispatcher_payment_records;
create policy "dispatch payments scoped select"
on public.dispatcher_payment_records for select
using (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch payments scoped insert" on public.dispatcher_payment_records;
create policy "dispatch payments scoped insert"
on public.dispatcher_payment_records for insert
with check (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch payments scoped update" on public.dispatcher_payment_records;
create policy "dispatch payments scoped update"
on public.dispatcher_payment_records for update
using (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
)
with check (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch fee records scoped select" on public.dispatcher_fee_records;
create policy "dispatch fee records scoped select"
on public.dispatcher_fee_records for select
using (
    public.sph_dispatch_is_company_admin(company_id)
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
);

drop policy if exists "dispatch fee records scoped insert" on public.dispatcher_fee_records;
create policy "dispatch fee records scoped insert"
on public.dispatcher_fee_records for insert
with check (
    public.sph_dispatch_is_company_admin(company_id)
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
);

drop policy if exists "dispatch fee records scoped update" on public.dispatcher_fee_records;
create policy "dispatch fee records scoped update"
on public.dispatcher_fee_records for update
using (
    public.sph_dispatch_is_company_admin(company_id)
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
)
with check (
    public.sph_dispatch_is_company_admin(company_id)
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
);

drop policy if exists "dispatch invoices scoped select" on public.dispatcher_invoices;
create policy "dispatch invoices scoped select"
on public.dispatcher_invoices for select
using (
    public.sph_dispatch_is_company_admin(company_id)
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
);

drop policy if exists "dispatch invoices scoped insert" on public.dispatcher_invoices;
create policy "dispatch invoices scoped insert"
on public.dispatcher_invoices for insert
with check (
    public.sph_dispatch_is_company_admin(company_id)
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
);

drop policy if exists "dispatch invoices scoped update" on public.dispatcher_invoices;
create policy "dispatch invoices scoped update"
on public.dispatcher_invoices for update
using (
    public.sph_dispatch_is_company_admin(company_id)
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
)
with check (
    public.sph_dispatch_is_company_admin(company_id)
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
);

comment on table public.dispatcher_profiles is
    'Sacred DISPATCH Network marketplace profiles for dispatchers. Active profiles are searchable by carriers.';
comment on table public.dispatcher_reviews is
    'Carrier reviews used to calculate dispatcher marketplace ratings.';
comment on table public.dispatch_service_requests is
    'Carrier-to-dispatcher service requests that can become agreements.';
comment on table public.dispatch_agreements is
    'Legally trackable dispatch service agreements and future payment placeholders.';
comment on table public.dispatcher_fee_records is
    'Settlement/OCR-backed dispatcher compensation records. No real payment processing.';
comment on table public.dispatcher_invoices is
    'Dispatcher invoice summaries with unpaid, pending, paid, and overdue tracking.';
comment on table public.dispatch_threads is
    'Sacred DISPATCH load/agreement conversation threads scoped by company.';
comment on table public.dispatch_messages is
    'Sacred DISPATCH thread messages with sender role labels and read state.';
comment on table public.dispatch_load_offers is
    'Dispatcher-created load offers that a driver can accept or decline.';
comment on table public.dispatcher_payment_records is
    'Legacy load-offer dispatcher fee records kept for backward compatibility.';
