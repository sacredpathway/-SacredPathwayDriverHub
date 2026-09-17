-- Let users who can access a dispatch thread see the participant rows for
-- that thread. This powers the dispatcher Driver Contact Book without opening
-- unrelated company or cross-thread participant data.

drop policy if exists "dispatch participants scoped select" on public.dispatch_participants;
create policy "dispatch participants scoped select"
on public.dispatch_participants for select
using (
    profile_id = auth.uid()
    or public.sph_dispatch_is_platform_admin()
    or (
        thread_id is not null
        and public.sph_dispatch_can_access_thread(thread_id, company_id)
    )
    or public.sph_dispatch_is_company_admin(company_id)
);
