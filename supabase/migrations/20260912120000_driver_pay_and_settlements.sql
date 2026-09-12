-- =============================================================================
--  Driver Pay & Settlements
--  Sacred Pathway Driver Hub — 2026-09-12
-- -----------------------------------------------------------------------------
--  ADDITIVE ONLY. This migration:
--    * adds nullable columns to existing tables
--    * creates new tables
--    * creates indexes and RLS policies
--
--  It does NOT drop, rename, retype or default-backfill any existing column,
--  and it does not touch a single existing row. Running it on the live project
--  cannot lose user data.
--
--  RLS mirrors the pattern already used by `loads`, `settlements` and
--  `paystubs`: profile_id = auth.uid().
--
--  Every statement is idempotent (IF NOT EXISTS / DROP POLICY IF EXISTS) so a
--  partial run can be re-applied safely.
-- =============================================================================

begin;

-- =============================================================================
--  1. settlements — extend the header
-- =============================================================================

alter table public.settlements add column if not exists settlement_number      text;
alter table public.settlements add column if not exists settlement_type        text;
alter table public.settlements add column if not exists truck_id               uuid;
alter table public.settlements add column if not exists truck_number           text;

alter table public.settlements add column if not exists pay_rule               jsonb;
alter table public.settlements add column if not exists pay_on_gross_revenue   boolean;
alter table public.settlements add column if not exists hours_worked           numeric(10,2);

alter table public.settlements add column if not exists gross_load_revenue     numeric(14,2);
alter table public.settlements add column if not exists total_driver_earnings  numeric(14,2);
alter table public.settlements add column if not exists total_additions        numeric(14,2);
alter table public.settlements add column if not exists total_deductions       numeric(14,2);
alter table public.settlements add column if not exists company_retained       numeric(14,2);
alter table public.settlements add column if not exists company_expenses       numeric(14,2);

alter table public.settlements add column if not exists loaded_miles           numeric(12,2);
alter table public.settlements add column if not exists deadhead_miles         numeric(12,2);
alter table public.settlements add column if not exists total_miles            numeric(12,2);

alter table public.settlements add column if not exists notes                  text;
alter table public.settlements add column if not exists updated_at             timestamptz default now();
alter table public.settlements add column if not exists approved_at            timestamptz;
alter table public.settlements add column if not exists paid_at                timestamptz;
alter table public.settlements add column if not exists voided_at              timestamptz;
alter table public.settlements add column if not exists created_by             uuid;
alter table public.settlements add column if not exists approved_by            uuid;
alter table public.settlements add column if not exists payment_reference      text;
alter table public.settlements add column if not exists payment_method         text;

alter table public.settlements add column if not exists engine_version         text;
alter table public.settlements add column if not exists is_estimate            boolean default false;

comment on column public.settlements.pay_rule is
  'JSON PayRule: {"components":[{"kind":"percent_of_gross","percent":70,...}]}. Copied onto the settlement at draft time so a later change to the driver''s rate never rewrites a settled week.';
comment on column public.settlements.engine_version is
  'Version of the calculation engine that produced these totals. Lets a rule change be identified in history.';
comment on column public.settlements.is_estimate is
  'True for live projections. Estimates are never approved, paid, or counted as financial history.';

-- Truck link is advisory — a truck row must never be able to delete settlement
-- history, so it is ON DELETE SET NULL.
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'public' and table_name = 'trucks')
     and not exists (select 1 from information_schema.table_constraints
                     where constraint_name = 'settlements_truck_id_fkey'
                       and table_schema = 'public') then
    alter table public.settlements
      add constraint settlements_truck_id_fkey
      foreign key (truck_id) references public.trucks(id) on delete set null;
  end if;
end $$;

-- Settlement numbers are unique per account. Partial index so the many existing
-- rows with a NULL number do not collide.
create unique index if not exists settlements_profile_number_uidx
  on public.settlements (profile_id, upper(settlement_number))
  where settlement_number is not null;

create index if not exists settlements_profile_driver_period_idx
  on public.settlements (profile_id, driver_id, settlement_period_start desc);

create index if not exists settlements_profile_status_idx
  on public.settlements (profile_id, status);

-- Status vocabulary. Legacy rows carry 'draft' or NULL and both stay valid.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'settlements_status_check') then
    alter table public.settlements
      add constraint settlements_status_check
      check (status is null or status in
        ('draft','ready_for_review','approved','paid','voided'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'settlements_type_check') then
    alter table public.settlements
      add constraint settlements_type_check
      check (settlement_type is null or settlement_type in
        ('company_driver','lease_operator','owner_operator','custom'));
  end if;
end $$;


-- =============================================================================
--  2. drivers — pay defaults
-- -----------------------------------------------------------------------------
--  The per-mile / salary / hourly / per-load rate columns already exist on this
--  table; only the settlement-type and rule columns are new.
-- =============================================================================

alter table public.drivers add column if not exists settlement_type      text;
alter table public.drivers add column if not exists pay_rule             jsonb;
alter table public.drivers add column if not exists pay_on_gross_revenue boolean default true;
alter table public.drivers add column if not exists lease_config         jsonb;
alter table public.drivers add column if not exists default_truck_id     uuid;
alter table public.drivers add column if not exists updated_at           timestamptz default now();

comment on column public.drivers.lease_config is
  'JSON LeaseOperatorConfig — driver/company gross split plus one responsibility rule per deduction category. No lease arrangement is assumed; unlisted categories fall back to the settlement type default.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'drivers_settlement_type_check') then
    alter table public.drivers
      add constraint drivers_settlement_type_check
      check (settlement_type is null or settlement_type in
        ('company_driver','lease_operator','owner_operator','custom'));
  end if;
end $$;


-- =============================================================================
--  3. settlement_loads — frozen per-load snapshot
-- -----------------------------------------------------------------------------
--  load_id is ON DELETE SET NULL on purpose: archiving or deleting an
--  operational load must never destroy the settlement a driver was paid on.
-- =============================================================================

create table if not exists public.settlement_loads (
  id                            uuid primary key default gen_random_uuid(),
  settlement_id                 uuid not null references public.settlements(id) on delete cascade,
  profile_id                    uuid not null,
  load_id                       uuid references public.loads(id) on delete set null,

  load_number                   text,
  broker_name                   text,
  broker_mc_number              text,
  pickup_date                   date,
  delivery_date                 date,
  origin                        text,
  destination                   text,

  loaded_miles                  numeric(12,2) not null default 0,
  deadhead_miles                numeric(12,2) not null default 0,

  linehaul                      numeric(14,2) not null default 0,
  fuel_surcharge                numeric(14,2) not null default 0,
  accessorials                  numeric(14,2) not null default 0,
  detention                     numeric(14,2) not null default 0,
  layover                       numeric(14,2) not null default 0,
  tonu                          numeric(14,2) not null default 0,
  lumper_reimbursement          numeric(14,2) not null default 0,
  gross_rate_override           numeric(14,2),

  pay_rule_override             jsonb,
  hours_worked                  numeric(10,2),
  driver_earnings               numeric(14,2) not null default 0,
  pay_basis_description         text,

  rate_confirmation_document_id uuid references public.documents(id) on delete set null,
  proof_of_delivery_document_id uuid references public.documents(id) on delete set null,

  notes                         text,
  is_adjustment                 boolean not null default false,
  corrects_settlement_id        uuid references public.settlements(id) on delete set null,
  sort_order                    integer not null default 0,
  created_at                    timestamptz not null default now(),

  constraint settlement_loads_adjustment_needs_origin
    check (is_adjustment = false or corrects_settlement_id is not null)
);

comment on table public.settlement_loads is
  'A load AS PAID. Values are frozen at settlement time; editing the operational load later does not rewrite a settled week.';

create index if not exists settlement_loads_settlement_idx
  on public.settlement_loads (settlement_id, sort_order);
create index if not exists settlement_loads_profile_load_idx
  on public.settlement_loads (profile_id, load_id);

-- A load may appear once per settlement, unless the line is a recorded
-- correction of an earlier settlement.
create unique index if not exists settlement_loads_unique_load_per_settlement
  on public.settlement_loads (settlement_id, load_id)
  where load_id is not null and is_adjustment = false;


-- =============================================================================
--  4. settlement_additions — credits
-- =============================================================================

create table if not exists public.settlement_additions (
  id              uuid primary key default gen_random_uuid(),
  settlement_id   uuid not null references public.settlements(id) on delete cascade,
  profile_id      uuid not null,
  category        text not null,
  description     text not null,
  amount          numeric(14,2) not null default 0,
  date            date,
  related_load_id uuid references public.loads(id) on delete set null,
  document_id     uuid references public.documents(id) on delete set null,
  notes           text,
  sort_order      integer not null default 0,
  created_at      timestamptz not null default now(),

  constraint settlement_additions_category_check check (category in (
    'bonus','detention','layover','tonu','lumper_reimbursement','reimbursement',
    'fuel_credit','maintenance_credit','safety_bonus','referral_bonus',
    'manual_credit','other'))
);

create index if not exists settlement_additions_settlement_idx
  on public.settlement_additions (settlement_id, sort_order);


-- =============================================================================
--  5. settlement_deductions — debits, with a responsibility split
-- =============================================================================

create table if not exists public.settlement_deductions (
  id                     uuid primary key default gen_random_uuid(),
  settlement_id          uuid not null references public.settlements(id) on delete cascade,
  profile_id             uuid not null,
  category               text not null,
  description            text not null,
  amount                 numeric(14,2) not null default 0,
  date                   date,
  related_load_id        uuid references public.loads(id) on delete set null,
  related_expense_id     uuid references public.expenses(id) on delete set null,
  document_id            uuid references public.documents(id) on delete set null,
  notes                  text,

  responsibility         text not null default 'driver',
  driver_share_percent   numeric(6,3) not null default 100,

  recurring_deduction_id uuid,
  advance_id             uuid,

  sort_order             integer not null default 0,
  created_at             timestamptz not null default now(),

  constraint settlement_deductions_category_check check (category in (
    'truck_lease','insurance','fuel','fuel_advance','cash_advance','maintenance',
    'repair','escrow','maintenance_reserve','tolls','scale_tickets','permits',
    'violation','damage','trailer_charge','equipment_charge','dispatcher_fee',
    'factoring_fee','authority_fee','other')),
  constraint settlement_deductions_responsibility_check
    check (responsibility in ('driver','company','split')),
  constraint settlement_deductions_share_range
    check (driver_share_percent >= 0 and driver_share_percent <= 100)
);

comment on column public.settlement_deductions.responsibility is
  'driver = whole line comes off the check · company = company absorbs it · split = driver_share_percent of the line comes off the check.';

create index if not exists settlement_deductions_settlement_idx
  on public.settlement_deductions (settlement_id, sort_order);
create index if not exists settlement_deductions_advance_idx
  on public.settlement_deductions (advance_id) where advance_id is not null;

-- One recurring rule may only land on a settlement once.
create unique index if not exists settlement_deductions_unique_recurring
  on public.settlement_deductions (settlement_id, recurring_deduction_id)
  where recurring_deduction_id is not null;


-- =============================================================================
--  6. recurring_deductions — standing instructions
-- =============================================================================

create table if not exists public.recurring_deductions (
  id                   uuid primary key default gen_random_uuid(),
  profile_id           uuid not null,
  driver_id            uuid not null references public.drivers(id) on delete cascade,
  category             text not null,
  description          text not null,
  amount               numeric(14,2) not null default 0,
  percent_of_gross     numeric(6,3),
  frequency            text not null default 'every_settlement',
  effective_start_date date not null,
  effective_end_date   date,
  is_active            boolean not null default true,
  responsibility       text not null default 'driver',
  driver_share_percent numeric(6,3) not null default 100,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint recurring_deductions_frequency_check check (frequency in (
    'every_settlement','weekly','biweekly','monthly','quarterly')),
  constraint recurring_deductions_responsibility_check
    check (responsibility in ('driver','company','split')),
  constraint recurring_deductions_amount_or_percent
    check (percent_of_gross is not null or amount > 0),
  constraint recurring_deductions_percent_range
    check (percent_of_gross is null or (percent_of_gross > 0 and percent_of_gross <= 100)),
  constraint recurring_deductions_date_order
    check (effective_end_date is null or effective_end_date >= effective_start_date),
  -- Advances have a balance cap; a recurring rule does not. Routing an advance
  -- through here would let it over-recover, so it is refused at the database.
  constraint recurring_deductions_not_an_advance
    check (category not in ('cash_advance','fuel_advance'))
);

create index if not exists recurring_deductions_profile_driver_idx
  on public.recurring_deductions (profile_id, driver_id, is_active);


-- =============================================================================
--  7. driver_advances + repayment ledger
-- =============================================================================

create table if not exists public.driver_advances (
  id               uuid primary key default gen_random_uuid(),
  profile_id       uuid not null,
  driver_id        uuid not null references public.drivers(id) on delete cascade,
  type             text not null default 'cash',
  date             date not null,
  amount           numeric(14,2) not null,
  description      text not null,
  document_id      uuid references public.documents(id) on delete set null,
  notes            text,
  recovered_amount numeric(14,2) not null default 0,
  is_closed        boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint driver_advances_type_check check (type in ('cash','fuel','emergency','other')),
  constraint driver_advances_amount_positive check (amount > 0),
  -- The invariant the whole advance feature rests on.
  constraint driver_advances_no_over_recovery
    check (recovered_amount >= 0 and recovered_amount <= amount)
);

comment on column public.driver_advances.recovered_amount is
  'Cache of the repayment ledger. The app rebuilds it from driver_advance_repayments on read; the CHECK above makes over-recovery impossible even if a client sends a bad value.';

create index if not exists driver_advances_profile_driver_idx
  on public.driver_advances (profile_id, driver_id, is_closed, date);

create table if not exists public.driver_advance_repayments (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null,
  advance_id    uuid not null references public.driver_advances(id) on delete cascade,
  settlement_id uuid references public.settlements(id) on delete set null,
  deduction_id  uuid references public.settlement_deductions(id) on delete set null,
  amount        numeric(14,2) not null,
  date          date not null,
  created_at    timestamptz not null default now(),

  constraint driver_advance_repayments_amount_positive check (amount > 0)
);

create index if not exists driver_advance_repayments_advance_idx
  on public.driver_advance_repayments (advance_id, date);
create index if not exists driver_advance_repayments_settlement_idx
  on public.driver_advance_repayments (settlement_id);

-- Late-added FKs for the deduction back-references (the target tables only
-- exist by this point in the file).
do $$
begin
  if not exists (select 1 from information_schema.table_constraints
                 where constraint_name = 'settlement_deductions_recurring_fkey'
                   and table_schema = 'public') then
    alter table public.settlement_deductions
      add constraint settlement_deductions_recurring_fkey
      foreign key (recurring_deduction_id)
      references public.recurring_deductions(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.table_constraints
                 where constraint_name = 'settlement_deductions_advance_fkey'
                   and table_schema = 'public') then
    alter table public.settlement_deductions
      add constraint settlement_deductions_advance_fkey
      foreign key (advance_id)
      references public.driver_advances(id) on delete set null;
  end if;
end $$;


-- =============================================================================
--  8. settlement_audit_events — append only
-- =============================================================================

create table if not exists public.settlement_audit_events (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null,
  settlement_id  uuid not null references public.settlements(id) on delete cascade,
  action         text not null,
  summary        text not null,
  field_name     text,
  previous_value text,
  new_value      text,
  actor_user_id  uuid,
  actor_name     text,
  timestamp      timestamptz not null default now()
);

comment on table public.settlement_audit_events is
  'Append-only trail of every financial change to a settlement. Nothing in the app updates or deletes a row here; RLS below enforces insert + select only.';

create index if not exists settlement_audit_events_settlement_idx
  on public.settlement_audit_events (settlement_id, timestamp desc);


-- =============================================================================
--  9. documents — attach to settlement objects
-- =============================================================================

alter table public.documents add column if not exists settlement_id uuid;
alter table public.documents add column if not exists addition_id   uuid;
alter table public.documents add column if not exists deduction_id  uuid;
alter table public.documents add column if not exists advance_id    uuid;

do $$
begin
  if not exists (select 1 from information_schema.table_constraints
                 where constraint_name = 'documents_settlement_fkey' and table_schema='public') then
    alter table public.documents add constraint documents_settlement_fkey
      foreign key (settlement_id) references public.settlements(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.table_constraints
                 where constraint_name = 'documents_addition_fkey' and table_schema='public') then
    alter table public.documents add constraint documents_addition_fkey
      foreign key (addition_id) references public.settlement_additions(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.table_constraints
                 where constraint_name = 'documents_deduction_fkey' and table_schema='public') then
    alter table public.documents add constraint documents_deduction_fkey
      foreign key (deduction_id) references public.settlement_deductions(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.table_constraints
                 where constraint_name = 'documents_advance_fkey' and table_schema='public') then
    alter table public.documents add constraint documents_advance_fkey
      foreign key (advance_id) references public.driver_advances(id) on delete set null;
  end if;
end $$;

create index if not exists documents_settlement_idx
  on public.documents (settlement_id) where settlement_id is not null;


-- =============================================================================
--  10. Row Level Security
-- -----------------------------------------------------------------------------
--  Same shape as the existing tables: profile_id = auth.uid(). One driver's
--  financial data is therefore never visible to another account.
-- =============================================================================

alter table public.settlement_loads          enable row level security;
alter table public.settlement_additions      enable row level security;
alter table public.settlement_deductions     enable row level security;
alter table public.recurring_deductions      enable row level security;
alter table public.driver_advances           enable row level security;
alter table public.driver_advance_repayments enable row level security;
alter table public.settlement_audit_events   enable row level security;

drop policy if exists "own settlement loads"        on public.settlement_loads;
drop policy if exists "own settlement additions"    on public.settlement_additions;
drop policy if exists "own settlement deductions"   on public.settlement_deductions;
drop policy if exists "own recurring deductions"    on public.recurring_deductions;
drop policy if exists "own driver advances"         on public.driver_advances;
drop policy if exists "own advance repayments"      on public.driver_advance_repayments;
drop policy if exists "read own audit events"       on public.settlement_audit_events;
drop policy if exists "insert own audit events"     on public.settlement_audit_events;

create policy "own settlement loads" on public.settlement_loads
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy "own settlement additions" on public.settlement_additions
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy "own settlement deductions" on public.settlement_deductions
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy "own recurring deductions" on public.recurring_deductions
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy "own driver advances" on public.driver_advances
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create policy "own advance repayments" on public.driver_advance_repayments
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- Audit events are insert + select only. There is deliberately no UPDATE or
-- DELETE policy, so the trail cannot be rewritten from a client.
create policy "read own audit events" on public.settlement_audit_events
  for select using (profile_id = auth.uid());

create policy "insert own audit events" on public.settlement_audit_events
  for insert with check (profile_id = auth.uid());


-- =============================================================================
--  11. updated_at triggers
-- =============================================================================

create or replace function public.sph_touch_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists settlements_touch_updated_at on public.settlements;
create trigger settlements_touch_updated_at
  before update on public.settlements
  for each row execute function public.sph_touch_updated_at();

drop trigger if exists recurring_deductions_touch_updated_at on public.recurring_deductions;
create trigger recurring_deductions_touch_updated_at
  before update on public.recurring_deductions
  for each row execute function public.sph_touch_updated_at();

drop trigger if exists driver_advances_touch_updated_at on public.driver_advances;
create trigger driver_advances_touch_updated_at
  before update on public.driver_advances
  for each row execute function public.sph_touch_updated_at();

drop trigger if exists drivers_touch_updated_at on public.drivers;
create trigger drivers_touch_updated_at
  before update on public.drivers
  for each row execute function public.sph_touch_updated_at();

commit;

-- =============================================================================
--  ROLLBACK (manual — run only if you need to undo this migration)
-- -----------------------------------------------------------------------------
--  drop table if exists public.settlement_audit_events cascade;
--  drop table if exists public.driver_advance_repayments cascade;
--  drop table if exists public.driver_advances cascade;
--  drop table if exists public.recurring_deductions cascade;
--  drop table if exists public.settlement_deductions cascade;
--  drop table if exists public.settlement_additions cascade;
--  drop table if exists public.settlement_loads cascade;
--  -- The settlements/drivers/documents columns added above are additive and
--  -- safe to leave in place; drop them individually only if you are certain
--  -- no build in the field is still writing them.
-- =============================================================================
