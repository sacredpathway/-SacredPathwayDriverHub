-- Driver mode cloud persistence column names.
-- Safe for existing rows: all new columns are nullable, backfilled from the
-- legacy load fields, and kept in sync for old and new app clients.

alter table public.loads
    add column if not exists loaded_miles numeric,
    add column if not exists empty_miles numeric,
    add column if not exists gross_load_pay numeric,
    add column if not exists delivery_date date,
    add column if not exists driver_percentage numeric,
    add column if not exists driver_rate_per_mile numeric,
    add column if not exists pay_type text;

update public.loads
set
    loaded_miles = coalesce(loaded_miles, total_miles),
    gross_load_pay = coalesce(gross_load_pay, total_revenue, line_haul_rate),
    pay_type = coalesce(pay_type, driver_pay_type)
where loaded_miles is null
   or gross_load_pay is null
   or pay_type is null;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'loads_pay_type_check'
          and conrelid = 'public.loads'::regclass
    ) then
        alter table public.loads
            add constraint loads_pay_type_check
            check (pay_type is null or pay_type in ('percentage', 'rate_per_mile'));
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conname = 'loads_driver_mode_amounts_nonnegative_check'
          and conrelid = 'public.loads'::regclass
    ) then
        alter table public.loads
            add constraint loads_driver_mode_amounts_nonnegative_check
            check (
                (loaded_miles is null or loaded_miles >= 0)
                and (empty_miles is null or empty_miles >= 0)
                and (gross_load_pay is null or gross_load_pay >= 0)
                and (driver_percentage is null or driver_percentage >= 0)
                and (driver_rate_per_mile is null or driver_rate_per_mile >= 0)
            );
    end if;
end $$;

create or replace function public.sph_sync_load_driver_mode_columns()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if new.loaded_miles is null and new.total_miles is not null then
        new.loaded_miles := new.total_miles;
    elsif new.total_miles is null and new.loaded_miles is not null then
        new.total_miles := new.loaded_miles;
    end if;

    if new.gross_load_pay is null then
        new.gross_load_pay := coalesce(new.total_revenue, new.line_haul_rate);
    end if;
    if new.total_revenue is null and new.gross_load_pay is not null then
        new.total_revenue := new.gross_load_pay;
    end if;
    if new.line_haul_rate is null and new.gross_load_pay is not null then
        new.line_haul_rate := new.gross_load_pay;
    end if;

    if new.pay_type is null and new.driver_pay_type is not null then
        new.pay_type := new.driver_pay_type;
    elsif new.driver_pay_type is null and new.pay_type is not null then
        new.driver_pay_type := new.pay_type;
    end if;

    if new.driver_gross_pay is null then
        if new.pay_type = 'percentage'
           and new.gross_load_pay is not null
           and new.driver_percentage is not null then
            new.driver_gross_pay := new.gross_load_pay * (new.driver_percentage / 100.0);
        elsif new.pay_type = 'rate_per_mile'
           and new.loaded_miles is not null
           and new.driver_rate_per_mile is not null then
            new.driver_gross_pay := new.loaded_miles * new.driver_rate_per_mile;
        end if;
    end if;

    return new;
end;
$$;

drop trigger if exists loads_sync_driver_mode_columns on public.loads;
create trigger loads_sync_driver_mode_columns
before insert or update on public.loads
for each row
execute function public.sph_sync_load_driver_mode_columns();
