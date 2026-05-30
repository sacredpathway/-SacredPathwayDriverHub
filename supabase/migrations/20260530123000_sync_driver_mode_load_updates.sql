-- Keep driver-mode load columns and legacy dashboard columns synchronized on
-- both inserts and updates. This protects cross-device sync when one client
-- writes the newer driver-mode names and another reads the existing load
-- dashboard fields.

create or replace function public.sph_sync_load_driver_mode_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    pay_inputs_changed boolean := false;
begin
    if tg_op = 'UPDATE' then
        if new.loaded_miles is distinct from old.loaded_miles then
            new.total_miles := new.loaded_miles;
        elsif new.total_miles is distinct from old.total_miles then
            new.loaded_miles := new.total_miles;
        end if;

        if new.gross_load_pay is distinct from old.gross_load_pay then
            new.total_revenue := new.gross_load_pay;
            new.line_haul_rate := new.gross_load_pay;
        elsif new.total_revenue is distinct from old.total_revenue then
            new.gross_load_pay := new.total_revenue;
        end if;

        if new.pay_type is distinct from old.pay_type then
            new.driver_pay_type := new.pay_type;
        elsif new.driver_pay_type is distinct from old.driver_pay_type then
            new.pay_type := new.driver_pay_type;
        end if;

        pay_inputs_changed :=
            new.loaded_miles is distinct from old.loaded_miles
            or new.gross_load_pay is distinct from old.gross_load_pay
            or new.pay_type is distinct from old.pay_type
            or new.driver_percentage is distinct from old.driver_percentage
            or new.driver_rate_per_mile is distinct from old.driver_rate_per_mile;
    end if;

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

    if new.driver_gross_pay is null or pay_inputs_changed then
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
