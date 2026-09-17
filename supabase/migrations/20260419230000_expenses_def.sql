-- Add DEF (Diesel Exhaust Fluid) tracking to expenses.
--
-- Drivers often buy DEF in the same fuel stop as diesel but at a
-- different price point. Tracking it as a separate pair of columns
-- on the same expense row (rather than a separate expense) keeps the
-- receipt together and lets rate-per-mile math stay clean on diesel.
alter table public.expenses
  add column if not exists def_gallons           decimal(10,2),
  add column if not exists def_price_per_gallon  decimal(6,3);
