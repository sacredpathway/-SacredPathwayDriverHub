-- Sacred Pathway account roles
-- Adds the persisted account role used by iOS onboarding/routing.
-- Existing profiles remain valid because account_role is nullable.

alter table public.profiles
    add column if not exists account_role text;

alter table public.profiles
    drop constraint if exists profiles_account_role_check;

alter table public.profiles
    add constraint profiles_account_role_check
    check (
        account_role is null
        or account_role in ('dispatcher', 'carrier', 'driver', 'owner_operator')
    );

create index if not exists idx_profiles_account_role
    on public.profiles (account_role);

comment on column public.profiles.account_role is
    'Sacred Pathway account role used for app routing: dispatcher, carrier, driver, or owner_operator.';

create or replace function public.sph_current_account_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
    select p.account_role
    from public.profiles p
    where p.id = auth.uid()
$$;

comment on function public.sph_current_account_role() is
    'Returns the authenticated user account role from profiles for role-aware RLS checks.';

create or replace function public.sph_sync_profile_account_role_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    selected_role text;
begin
    selected_role := new.raw_user_meta_data ->> 'account_role';

    if selected_role in ('dispatcher', 'carrier', 'driver', 'owner_operator') then
        insert into public.profiles (id, account_role)
        values (new.id, selected_role)
        on conflict (id) do update
        set account_role = coalesce(public.profiles.account_role, excluded.account_role),
            updated_at = now();
    end if;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created_account_role on auth.users;

create trigger on_auth_user_created_account_role
after insert on auth.users
for each row execute function public.sph_sync_profile_account_role_from_auth();

drop policy if exists "dispatcher profiles scoped insert" on public.dispatcher_profiles;
create policy "dispatcher profiles scoped insert"
on public.dispatcher_profiles for insert
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and user_id = auth.uid()
    )
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatcher profiles scoped update" on public.dispatcher_profiles;
create policy "dispatcher profiles scoped update"
on public.dispatcher_profiles for update
using (
    (
        public.sph_current_account_role() = 'dispatcher'
        and user_id = auth.uid()
    )
    or public.sph_dispatch_is_company_admin(company_id)
)
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and user_id = auth.uid()
    )
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch requests scoped insert" on public.dispatch_service_requests;
create policy "dispatch requests scoped insert"
on public.dispatch_service_requests for insert
with check (
    (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and requested_by_profile_id = auth.uid()
    )
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch agreements scoped insert" on public.dispatch_agreements;
create policy "dispatch agreements scoped insert"
on public.dispatch_agreements for insert
with check (
    (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and carrier_profile_id = auth.uid()
    )
    or (
        public.sph_current_account_role() = 'dispatcher'
        and dispatcher_user_id = auth.uid()
    )
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch messages scoped insert" on public.dispatch_messages;
create policy "dispatch messages scoped insert"
on public.dispatch_messages for insert
with check (
    sender_profile_id = auth.uid()
    and public.sph_dispatch_can_access_thread(thread_id, company_id)
    and (
        (public.sph_current_account_role() = 'dispatcher' and sender_role = 'dispatcher')
        or (public.sph_current_account_role() = 'carrier' and sender_role = 'carrier')
        or (public.sph_current_account_role() = 'driver' and sender_role = 'driver')
        or (public.sph_current_account_role() = 'owner_operator' and sender_role in ('carrier', 'driver'))
        or public.sph_dispatch_is_company_admin(company_id)
    )
);

drop policy if exists "dispatch offers scoped insert" on public.dispatch_load_offers;
create policy "dispatch offers scoped insert"
on public.dispatch_load_offers for insert
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and dispatcher_user_id = auth.uid()
    )
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch payments scoped insert" on public.dispatcher_payment_records;
create policy "dispatch payments scoped insert"
on public.dispatcher_payment_records for insert
with check (
    (
        public.sph_current_account_role() = 'driver'
        and driver_profile_id = auth.uid()
    )
    or (
        public.sph_current_account_role() in ('dispatcher', 'carrier', 'owner_operator')
        and (
            driver_profile_id = auth.uid()
            or dispatcher_user_id = auth.uid()
        )
    )
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch fee records scoped insert" on public.dispatcher_fee_records;
create policy "dispatch fee records scoped insert"
on public.dispatcher_fee_records for insert
with check (
    (
        public.sph_current_account_role() in ('dispatcher', 'carrier', 'owner_operator')
        and (
            carrier_profile_id = auth.uid()
            or dispatcher_user_id = auth.uid()
            or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
        )
    )
    or public.sph_dispatch_is_company_admin(company_id)
);

drop policy if exists "dispatch invoices scoped insert" on public.dispatcher_invoices;
create policy "dispatch invoices scoped insert"
on public.dispatcher_invoices for insert
with check (
    (
        public.sph_current_account_role() in ('dispatcher', 'carrier', 'owner_operator')
        and (
            carrier_profile_id = auth.uid()
            or dispatcher_user_id = auth.uid()
            or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
        )
    )
    or public.sph_dispatch_is_company_admin(company_id)
);

comment on table public.dispatcher_profiles is
    'Sacred DISPATCH marketplace profiles. Inserts/updates are role-gated to dispatcher accounts or company admins.';

comment on table public.dispatch_load_offers is
    'Sacred DISPATCH load offers. Inserts are role-gated to dispatcher accounts; recipients remain scoped by relationship policies.';

comment on table public.dispatch_messages is
    'Sacred DISPATCH messages. Inserts require the sender role to match the authenticated account role and an accessible thread.';

-- RLS review notes:
-- 1. Dispatch select/update policies remain relationship-scoped by profile id,
--    dispatcher user id, company id, thread participants, agreement access,
--    or company admin helper functions.
-- 2. Role-aware insert policies above prevent normal driver/carrier accounts
--    from creating dispatcher profiles or outbound dispatcher load offers.
-- 3. This migration does not enable payment processing. Dispatcher invoices,
--    fee records, and payment rows remain payment-tracking records only.
