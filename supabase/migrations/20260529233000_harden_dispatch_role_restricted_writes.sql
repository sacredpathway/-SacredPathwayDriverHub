-- Sacred DISPATCH role-restricted write hardening.
--
-- The previous company-admin helper treated company_id = auth.uid() as admin
-- for every account role. That made role-gated write policies too permissive
-- because users could set company_id to their own profile id. Keep platform
-- admin separate, and require the correct account role for role-specific
-- writes.

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
            or (
                public.sph_current_account_role() in ('carrier', 'owner_operator')
                and (
                    target_company_id = auth.uid()
                    or exists (
                        select 1
                        from public.dispatch_participants p
                        where p.company_id = target_company_id
                          and p.profile_id = auth.uid()
                          and p.role in ('carrier', 'admin')
                          and p.is_active = true
                    )
                )
            )
       );
$$;

drop policy if exists "dispatcher profiles scoped insert" on public.dispatcher_profiles;
create policy "dispatcher profiles scoped insert"
on public.dispatcher_profiles for insert
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and user_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatcher profiles scoped update" on public.dispatcher_profiles;
create policy "dispatcher profiles scoped update"
on public.dispatcher_profiles for update
using (
    (
        public.sph_current_account_role() = 'dispatcher'
        and user_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
)
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and user_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatcher reviews scoped insert" on public.dispatcher_reviews;
create policy "dispatcher reviews scoped insert"
on public.dispatcher_reviews for insert
with check (
    (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and carrier_profile_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch participants scoped insert" on public.dispatch_participants;
create policy "dispatch participants scoped insert"
on public.dispatch_participants for insert
with check (
    public.sph_dispatch_is_platform_admin()
    or (
        profile_id = auth.uid()
        and (
            (public.sph_current_account_role() = 'dispatcher' and role = 'dispatcher')
            or (public.sph_current_account_role() = 'driver' and role = 'driver')
            or (public.sph_current_account_role() in ('carrier', 'owner_operator') and role = 'carrier')
        )
    )
);

drop policy if exists "dispatch participants scoped update" on public.dispatch_participants;
create policy "dispatch participants scoped update"
on public.dispatch_participants for update
using (
    public.sph_dispatch_is_platform_admin()
    or (
        profile_id = auth.uid()
        and (
            (public.sph_current_account_role() = 'dispatcher' and role = 'dispatcher')
            or (public.sph_current_account_role() = 'driver' and role = 'driver')
            or (public.sph_current_account_role() in ('carrier', 'owner_operator') and role = 'carrier')
        )
    )
)
with check (
    public.sph_dispatch_is_platform_admin()
    or (
        profile_id = auth.uid()
        and (
            (public.sph_current_account_role() = 'dispatcher' and role = 'dispatcher')
            or (public.sph_current_account_role() = 'driver' and role = 'driver')
            or (public.sph_current_account_role() in ('carrier', 'owner_operator') and role = 'carrier')
        )
    )
);

drop policy if exists "dispatch requests scoped insert" on public.dispatch_service_requests;
create policy "dispatch requests scoped insert"
on public.dispatch_service_requests for insert
with check (
    (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and requested_by_profile_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch requests scoped update" on public.dispatch_service_requests;
create policy "dispatch requests scoped update"
on public.dispatch_service_requests for update
using (
    (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and requested_by_profile_id = auth.uid()
    )
    or (
        public.sph_current_account_role() = 'dispatcher'
        and dispatcher_user_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
)
with check (
    (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and requested_by_profile_id = auth.uid()
    )
    or (
        public.sph_current_account_role() = 'dispatcher'
        and dispatcher_user_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
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
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch agreements scoped update" on public.dispatch_agreements;
create policy "dispatch agreements scoped update"
on public.dispatch_agreements for update
using (
    (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and carrier_profile_id = auth.uid()
    )
    or (
        public.sph_current_account_role() = 'dispatcher'
        and (
            dispatcher_user_id = auth.uid()
            or exists (
                select 1
                from public.dispatcher_profiles dp
                where dp.id = dispatch_agreements.dispatcher_profile_id
                  and dp.user_id = auth.uid()
            )
        )
    )
    or public.sph_dispatch_is_platform_admin()
)
with check (
    (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and carrier_profile_id = auth.uid()
    )
    or (
        public.sph_current_account_role() = 'dispatcher'
        and (
            dispatcher_user_id = auth.uid()
            or exists (
                select 1
                from public.dispatcher_profiles dp
                where dp.id = dispatch_agreements.dispatcher_profile_id
                  and dp.user_id = auth.uid()
            )
        )
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch threads scoped insert" on public.dispatch_threads;
create policy "dispatch threads scoped insert"
on public.dispatch_threads for insert
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and dispatcher_user_id = auth.uid()
    )
    or (
        public.sph_current_account_role() = 'driver'
        and driver_profile_id = auth.uid()
    )
    or (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and company_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch threads scoped update" on public.dispatch_threads;
create policy "dispatch threads scoped update"
on public.dispatch_threads for update
using (
    public.sph_dispatch_can_access_thread(id, company_id)
)
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and dispatcher_user_id = auth.uid()
    )
    or (
        public.sph_current_account_role() = 'driver'
        and driver_profile_id = auth.uid()
    )
    or (
        public.sph_current_account_role() in ('carrier', 'owner_operator')
        and (
            company_id = auth.uid()
            or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
        )
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch messages scoped insert" on public.dispatch_messages;
create policy "dispatch messages scoped insert"
on public.dispatch_messages for insert
with check (
    (
        sender_profile_id = auth.uid()
        and public.sph_dispatch_can_access_thread(thread_id, company_id)
        and (
            (public.sph_current_account_role() = 'dispatcher' and sender_role = 'dispatcher')
            or (public.sph_current_account_role() = 'carrier' and sender_role = 'carrier')
            or (public.sph_current_account_role() = 'driver' and sender_role = 'driver')
            or (public.sph_current_account_role() = 'owner_operator' and sender_role in ('carrier', 'driver'))
        )
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch offers scoped insert" on public.dispatch_load_offers;
create policy "dispatch offers scoped insert"
on public.dispatch_load_offers for insert
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and dispatcher_user_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch offers scoped update" on public.dispatch_load_offers;
create policy "dispatch offers scoped update"
on public.dispatch_load_offers for update
using (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_platform_admin()
)
with check (
    (
        public.sph_current_account_role() = 'dispatcher'
        and dispatcher_user_id = auth.uid()
    )
    or (
        public.sph_current_account_role() in ('driver', 'carrier', 'owner_operator')
        and driver_profile_id = auth.uid()
    )
    or public.sph_dispatch_is_platform_admin()
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
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch payments scoped update" on public.dispatcher_payment_records;
create policy "dispatch payments scoped update"
on public.dispatcher_payment_records for update
using (
    driver_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or public.sph_dispatch_is_platform_admin()
)
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
    or public.sph_dispatch_is_platform_admin()
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
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch fee records scoped update" on public.dispatcher_fee_records;
create policy "dispatch fee records scoped update"
on public.dispatcher_fee_records for update
using (
    carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or public.sph_dispatch_is_platform_admin()
)
with check (
    (
        public.sph_current_account_role() in ('dispatcher', 'carrier', 'owner_operator')
        and (
            carrier_profile_id = auth.uid()
            or dispatcher_user_id = auth.uid()
            or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
        )
    )
    or public.sph_dispatch_is_platform_admin()
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
    or public.sph_dispatch_is_platform_admin()
);

drop policy if exists "dispatch invoices scoped update" on public.dispatcher_invoices;
create policy "dispatch invoices scoped update"
on public.dispatcher_invoices for update
using (
    carrier_profile_id = auth.uid()
    or dispatcher_user_id = auth.uid()
    or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
    or public.sph_dispatch_is_platform_admin()
)
with check (
    (
        public.sph_current_account_role() in ('dispatcher', 'carrier', 'owner_operator')
        and (
            carrier_profile_id = auth.uid()
            or dispatcher_user_id = auth.uid()
            or (agreement_id is not null and public.sph_dispatch_can_access_agreement(agreement_id, company_id))
        )
    )
    or public.sph_dispatch_is_platform_admin()
);

comment on function public.sph_dispatch_is_company_admin(uuid) is
    'Returns true for Sacred platform admins or carrier/owner-operator accounts that own or administer the dispatch company. Does not grant admin solely by company_id to dispatcher or driver roles.';

comment on table public.dispatch_load_offers is
    'Sacred DISPATCH load offers. Inserts are restricted to dispatcher accounts or Sacred platform admins; recipients can only update their own received offers.';

comment on table public.dispatcher_fee_records is
    'Sacred DISPATCH fee records. Inserts are restricted to dispatcher, carrier, or owner-operator accounts with a direct agreement relationship; drivers cannot create fee records.';
