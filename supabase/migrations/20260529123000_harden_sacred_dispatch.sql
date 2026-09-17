-- Sacred DISPATCH stabilization
-- Keep payment collection disabled; this migration only hardens tracking data.

with ranked as (
    select
        id,
        first_value(id) over (
            partition by agreement_id, period_start, period_end
            order by updated_at desc nulls last, created_at desc nulls last, id
        ) as keep_id,
        row_number() over (
            partition by agreement_id, period_start, period_end
            order by updated_at desc nulls last, created_at desc nulls last, id
        ) as rn
    from public.dispatcher_invoices
    where agreement_id is not null
      and period_start is not null
      and period_end is not null
)
update public.dispatcher_fee_records fr
set invoice_id = ranked.keep_id
from ranked
where ranked.rn > 1
  and fr.invoice_id = ranked.id;
with ranked as (
    select
        id,
        row_number() over (
            partition by agreement_id, period_start, period_end
            order by updated_at desc nulls last, created_at desc nulls last, id
        ) as rn
    from public.dispatcher_invoices
    where agreement_id is not null
      and period_start is not null
      and period_end is not null
)
delete from public.dispatcher_invoices invoice
using ranked
where ranked.rn > 1
  and invoice.id = ranked.id;
create unique index if not exists dispatcher_invoices_agreement_period_unique
    on public.dispatcher_invoices (agreement_id, period_start, period_end)
    where agreement_id is not null
      and period_start is not null
      and period_end is not null;
alter table public.dispatch_load_offers
    drop constraint if exists dispatch_load_offers_fee_type_check;
alter table public.dispatch_load_offers
    add constraint dispatch_load_offers_fee_type_check
    check (
        fee_type in (
            'flat',
            'percentage',
            'percentage_gross',
            'flat_per_load',
            'weekly_fixed',
            'monthly_fixed'
        )
    );
alter table public.dispatcher_payment_records
    drop constraint if exists dispatcher_payment_records_fee_type_check;
alter table public.dispatcher_payment_records
    add constraint dispatcher_payment_records_fee_type_check
    check (
        fee_type in (
            'flat',
            'percentage',
            'percentage_gross',
            'flat_per_load',
            'weekly_fixed',
            'monthly_fixed'
        )
    );
comment on index public.dispatcher_invoices_agreement_period_unique is
    'Prevents duplicate Sacred DISPATCH invoices for the same agreement and billing period.';
