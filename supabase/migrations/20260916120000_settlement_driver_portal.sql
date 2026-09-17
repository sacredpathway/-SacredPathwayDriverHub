-- =============================================================================
--  Driver Pay & Settlements — driver portal read access
--  Sacred Pathway Driver Hub — 2026-09-16
-- -----------------------------------------------------------------------------
--  Depends on 20260912120000_driver_pay_and_settlements.sql.
--
--  ADDITIVE ONLY. Adds SELECT-only policies so a signed-in DRIVER account can
--  read its own finalized settlements, using the existing `carrier_members`
--  link (role = 'driver', status = 'active', linked_driver_id).
--
--  What a linked driver can read:
--    * settlements for THEIR driver row, status approved or paid, never an
--      estimate, never a draft
--    * the load / addition lines of those settlements
--    * the deduction lines that actually came off their check
--      (responsibility driver or split — never company-only lines)
--    * their own advances and repayment history
--    * rate confirmations / BOLs / PODs attached to loads on those settlements,
--      plus the settlement PDF itself (row + storage object)
--
--  What a driver can NEVER do: insert, update or delete any of it. No write
--  policy is added for drivers anywhere. Another driver's data is never
--  visible because every check is keyed on (carrier, linked_driver_id,
--  auth.uid()).
--
--  Every statement is idempotent.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
--  Helper functions (SECURITY DEFINER, fixed search_path, no PUBLIC execute)
-- -----------------------------------------------------------------------------

create or replace function public.sph_is_linked_driver(p_carrier uuid, p_driver uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.carrier_members m
     where m.user_id = auth.uid()
       and m.status = 'active'
       and m.role = 'driver'
       and m.carrier_profile_id = p_carrier
       and m.linked_driver_id = p_driver
  );
$$;

create or replace function public.sph_driver_can_read_settlement(p_settlement uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.settlements s
     where s.id = p_settlement
       and s.status in ('approved', 'paid')
       and coalesce(s.is_estimate, false) = false
       and public.sph_is_linked_driver(s.profile_id, s.driver_id)
  );
$$;

create or replace function public.sph_driver_can_read_document(p_document uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.documents d
     where d.id = p_document
       and (
         -- The document must belong to the same carrier as the settlement,
         -- so a line can never expose another account's file.
         (d.settlement_id is not null
            and exists (select 1 from public.settlements s
                         where s.id = d.settlement_id and s.profile_id = d.profile_id)
            and public.sph_driver_can_read_settlement(d.settlement_id))
         or exists (
            select 1
              from public.settlement_loads l
             where l.profile_id = d.profile_id
               and (l.rate_confirmation_document_id = d.id
                    or l.proof_of_delivery_document_id = d.id
                    or (d.load_id is not null
                        and l.load_id = d.load_id
                        and lower(coalesce(d.document_type, '')) in
                            ('rate_confirmation', 'bol', 'pod', 'proof_of_delivery')))
               and public.sph_driver_can_read_settlement(l.settlement_id)
         )
       )
  );
$$;

-- Carrier + driver context for the signed-in driver account. Returns only the
-- columns the settlement statement prints — never driver PII.
create or replace function public.sph_driver_settlement_context()
returns table (
  carrier_profile_id uuid,
  linked_driver_id   uuid,
  driver_name        text,
  company_name       text,
  mc_number          text,
  dot_number         text,
  phone              text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select m.carrier_profile_id,
         m.linked_driver_id,
         d.name,
         p.company_name,
         p.mc_number,
         p.dot_number,
         p.phone
    from public.carrier_members m
    join public.drivers  d on d.id = m.linked_driver_id
    join public.profiles p on p.id = m.carrier_profile_id
   where m.user_id = auth.uid()
     and m.status = 'active'
     and m.role = 'driver';
$$;

revoke all on function public.sph_is_linked_driver(uuid, uuid)          from public, anon;
revoke all on function public.sph_driver_can_read_settlement(uuid)      from public, anon;
revoke all on function public.sph_driver_can_read_document(uuid)        from public, anon;
revoke all on function public.sph_driver_settlement_context()           from public, anon;
grant execute on function public.sph_is_linked_driver(uuid, uuid)       to authenticated;
grant execute on function public.sph_driver_can_read_settlement(uuid)   to authenticated;
grant execute on function public.sph_driver_can_read_document(uuid)     to authenticated;
grant execute on function public.sph_driver_settlement_context()        to authenticated;

-- -----------------------------------------------------------------------------
--  SELECT-only policies for linked drivers
-- -----------------------------------------------------------------------------

drop policy if exists "linked driver reads finalized settlements" on public.settlements;
create policy "linked driver reads finalized settlements" on public.settlements
  for select to authenticated
  using (
    status in ('approved', 'paid')
    and coalesce(is_estimate, false) = false
    and public.sph_is_linked_driver(profile_id, driver_id)
  );

drop policy if exists "linked driver reads settlement loads" on public.settlement_loads;
create policy "linked driver reads settlement loads" on public.settlement_loads
  for select to authenticated
  using (public.sph_driver_can_read_settlement(settlement_id));

drop policy if exists "linked driver reads settlement additions" on public.settlement_additions;
create policy "linked driver reads settlement additions" on public.settlement_additions
  for select to authenticated
  using (public.sph_driver_can_read_settlement(settlement_id));

drop policy if exists "linked driver reads own deductions" on public.settlement_deductions;
create policy "linked driver reads own deductions" on public.settlement_deductions
  for select to authenticated
  using (
    responsibility <> 'company'
    and public.sph_driver_can_read_settlement(settlement_id)
  );

drop policy if exists "linked driver reads own advances" on public.driver_advances;
create policy "linked driver reads own advances" on public.driver_advances
  for select to authenticated
  using (public.sph_is_linked_driver(profile_id, driver_id));

drop policy if exists "linked driver reads own advance repayments" on public.driver_advance_repayments;
create policy "linked driver reads own advance repayments" on public.driver_advance_repayments
  for select to authenticated
  using (
    exists (
      select 1 from public.driver_advances a
       where a.id = advance_id
         and public.sph_is_linked_driver(a.profile_id, a.driver_id)
    )
  );

drop policy if exists "linked driver reads settlement documents" on public.documents;
create policy "linked driver reads settlement documents" on public.documents
  for select to authenticated
  using (public.sph_driver_can_read_document(id));

-- -----------------------------------------------------------------------------
--  Integrity guards on existing tables (RESTRICTIVE: they only ever narrow
--  what the existing "Users manage own …" policies allow; reads unchanged)
-- -----------------------------------------------------------------------------
--  Every signed-in user has a profiles row, so "profile_id = auth.uid()" alone
--  would let a driver account create a settlement (or a settlement document)
--  under its own profile that points at its carrier's driver row or
--  settlement. The portal would then show that forged row. These guards
--  require the referenced driver / settlement to belong to the same account.
--  (Live check 2026-09-16: 0 existing settlements violate the driver rule.)

drop policy if exists "settlement driver belongs to owner" on public.settlements;
create policy "settlement driver belongs to owner" on public.settlements
  as restrictive for all
  using (true)
  with check (
    settlements.driver_id is null
    or exists (select 1 from public.drivers d
                where d.id = settlements.driver_id and d.profile_id = settlements.profile_id)
  );

drop policy if exists "document settlement belongs to owner" on public.documents;
create policy "document settlement belongs to owner" on public.documents
  as restrictive for all
  using (true)
  with check (
    documents.settlement_id is null
    or exists (select 1 from public.settlements s
                where s.id = documents.settlement_id and s.profile_id = documents.profile_id)
  );

-- Storage: the file behind a readable document row. Only applied when the
-- private `documents` bucket exists (it does on the live project).
do $$
begin
  if exists (select 1 from information_schema.tables
              where table_schema = 'storage' and table_name = 'objects') then
    execute 'drop policy if exists "linked driver reads settlement files" on storage.objects';
    execute $p$
      create policy "linked driver reads settlement files" on storage.objects
        for select to authenticated
        using (
          bucket_id = 'documents'
          and exists (
            select 1 from public.documents d
             where d.storage_path = storage.objects.name
               and public.sph_driver_can_read_document(d.id)
          )
        )
    $p$;
  end if;
end $$;

commit;

-- =============================================================================
--  ROLLBACK (manual)
-- -----------------------------------------------------------------------------
--  drop policy if exists "linked driver reads settlement files"            on storage.objects;
--  drop policy if exists "document settlement belongs to owner"            on public.documents;
--  drop policy if exists "settlement driver belongs to owner"              on public.settlements;
--  drop policy if exists "linked driver reads settlement documents"        on public.documents;
--  drop policy if exists "linked driver reads own advance repayments"      on public.driver_advance_repayments;
--  drop policy if exists "linked driver reads own advances"                on public.driver_advances;
--  drop policy if exists "linked driver reads own deductions"              on public.settlement_deductions;
--  drop policy if exists "linked driver reads settlement additions"        on public.settlement_additions;
--  drop policy if exists "linked driver reads settlement loads"            on public.settlement_loads;
--  drop policy if exists "linked driver reads finalized settlements"       on public.settlements;
--  drop function if exists public.sph_driver_settlement_context();
--  drop function if exists public.sph_driver_can_read_document(uuid);
--  drop function if exists public.sph_driver_can_read_settlement(uuid);
--  drop function if exists public.sph_is_linked_driver(uuid, uuid);
-- =============================================================================
