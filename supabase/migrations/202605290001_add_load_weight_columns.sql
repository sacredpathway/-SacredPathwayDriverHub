-- Add nullable shipment weight support to loads.
-- Safe for existing rows: both columns are nullable, and the check constraint
-- allows NULL so old loads remain valid.

alter table public.loads
    add column if not exists weight_value numeric,
    add column if not exists weight_unit text;
do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'loads_weight_unit_check'
          and conrelid = 'public.loads'::regclass
    ) then
        alter table public.loads
            add constraint loads_weight_unit_check
            check (weight_unit is null or weight_unit in ('lbs', 'kg'));
    end if;
end $$;
comment on column public.loads.weight_value is 'Shipment weight value extracted from Smart Scan or entered by the driver.';
comment on column public.loads.weight_unit is 'Shipment weight unit. Allowed values: lbs, kg.';
