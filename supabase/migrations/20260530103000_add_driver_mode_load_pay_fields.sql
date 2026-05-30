-- Driver mode per-load pay support.
-- Safe for existing rows: all new columns are nullable and default to NULL.

alter table public.loads
    add column if not exists empty_miles numeric,
    add column if not exists driver_pay_type text,
    add column if not exists driver_percentage numeric,
    add column if not exists driver_rate_per_mile numeric,
    add column if not exists driver_gross_pay numeric;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'loads_driver_pay_type_check'
          and conrelid = 'public.loads'::regclass
    ) then
        alter table public.loads
            add constraint loads_driver_pay_type_check
            check (driver_pay_type is null or driver_pay_type in ('percentage', 'rate_per_mile'));
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conname = 'loads_driver_pay_amounts_nonnegative_check'
          and conrelid = 'public.loads'::regclass
    ) then
        alter table public.loads
            add constraint loads_driver_pay_amounts_nonnegative_check
            check (
                (empty_miles is null or empty_miles >= 0)
                and (driver_percentage is null or driver_percentage >= 0)
                and (driver_rate_per_mile is null or driver_rate_per_mile >= 0)
                and (driver_gross_pay is null or driver_gross_pay >= 0)
            );
    end if;
end $$;
