-- Sacred Pathway Driver Hub
-- Migration: add pay_type + flat_rate columns to drivers
--
-- Originally maintained as supabase_migration_drivers_paytype.sql at
-- the project root. Moved into the migrations pipeline so
-- `supabase db push` rebuilds correctly from zero. Fully idempotent.

-- 1. Add columns
ALTER TABLE drivers
    ADD COLUMN IF NOT EXISTS pay_type TEXT DEFAULT 'percent',
    ADD COLUMN IF NOT EXISTS flat_rate DECIMAL(10,2);
-- 2. Enforce valid pay_type values (only once)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'drivers_pay_type_check'
    ) THEN
        ALTER TABLE drivers
        ADD CONSTRAINT drivers_pay_type_check
        CHECK (pay_type IN ('percent', 'flat'));
    END IF;
END $$;
-- 3. Backfill existing records
UPDATE drivers
SET pay_type = 'percent'
WHERE pay_type IS NULL;
-- 4. Ensure flat_rate is not negative
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'drivers_flat_rate_positive_check'
    ) THEN
        ALTER TABLE drivers
        ADD CONSTRAINT drivers_flat_rate_positive_check
        CHECK (flat_rate IS NULL OR flat_rate >= 0);
    END IF;
END $$;
