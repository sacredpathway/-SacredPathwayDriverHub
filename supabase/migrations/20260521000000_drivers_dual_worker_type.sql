-- ============================================================================
-- Sacred Pathway Driver Hub — Carrier HQ Payroll · Phase W2
-- 20260521000000_drivers_dual_worker_type.sql
-- ----------------------------------------------------------------------------
-- Extends the existing `drivers` table to support BOTH classifications
-- carriers actually run today:
--   • 1099 owner-operator / contractor drivers (default — matches all
--     pre-existing iOS rows, no backfill required)
--   • W2 employee drivers (new; web-only intake for now)
--
-- Rules:
--   • ADDITIVE ONLY — no DROP, no RENAME, no NOT NULL tightening on existing
--     columns. Existing iOS Driver model continues to decode correctly because
--     every new column is nullable (or has a backward-compatible DEFAULT).
--   • Idempotent: every statement uses IF NOT EXISTS / DO blocks, so this
--     migration is safe to re-run against an already-initialised database.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Worker classification + 1099 escrow tracking
-- ----------------------------------------------------------------------------
ALTER TABLE public.drivers
  ADD COLUMN IF NOT EXISTS worker_type           TEXT        NOT NULL DEFAULT '1099',
  ADD COLUMN IF NOT EXISTS escrow_per_settlement NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS escrow_balance        NUMERIC(12,2) DEFAULT 0;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drivers_worker_type_check'
  ) THEN
    ALTER TABLE public.drivers
      ADD CONSTRAINT drivers_worker_type_check
      CHECK (worker_type IN ('1099','W2'));
  END IF;
END$$;
-- ----------------------------------------------------------------------------
-- 2. W2 compensation fields (used when worker_type = 'W2')
-- ----------------------------------------------------------------------------
ALTER TABLE public.drivers
  ADD COLUMN IF NOT EXISTS employment_status   TEXT,
  ADD COLUMN IF NOT EXISTS pay_frequency       TEXT,
  ADD COLUMN IF NOT EXISTS comp_type           TEXT,
  ADD COLUMN IF NOT EXISTS hourly_rate         NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS salary_annual       NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS mileage_rate        NUMERIC(10,4),
  ADD COLUMN IF NOT EXISTS per_load_rate       NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS per_diem_daily      NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS overtime_multiplier NUMERIC(4,2) DEFAULT 1.5;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drivers_employment_status_check'
  ) THEN
    ALTER TABLE public.drivers
      ADD CONSTRAINT drivers_employment_status_check
      CHECK (employment_status IS NULL OR employment_status IN
        ('active','on_leave','terminated'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drivers_pay_frequency_check'
  ) THEN
    ALTER TABLE public.drivers
      ADD CONSTRAINT drivers_pay_frequency_check
      CHECK (pay_frequency IS NULL OR pay_frequency IN
        ('weekly','biweekly','semimonthly','monthly'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drivers_comp_type_check'
  ) THEN
    ALTER TABLE public.drivers
      ADD CONSTRAINT drivers_comp_type_check
      CHECK (comp_type IS NULL OR comp_type IN
        ('hourly','salary','mileage','per_load'));
  END IF;
END$$;
-- ----------------------------------------------------------------------------
-- 3. Tax setup placeholders (NO compute engine yet — manual values only)
-- ----------------------------------------------------------------------------
ALTER TABLE public.drivers
  ADD COLUMN IF NOT EXISTS filing_status        TEXT,
  ADD COLUMN IF NOT EXISTS federal_allowances   INTEGER,
  ADD COLUMN IF NOT EXISTS w4_extra_withholding NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS state_code           TEXT,
  ADD COLUMN IF NOT EXISTS state_allowances     INTEGER,
  -- SSN/EIN are PLACEHOLDERS. We expect the application layer (Next.js
  -- server actions) to encrypt before insert. The DB only stores the
  -- already-encrypted blob — never plaintext.
  ADD COLUMN IF NOT EXISTS ssn_encrypted        TEXT,
  ADD COLUMN IF NOT EXISTS ein                  TEXT;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drivers_filing_status_check'
  ) THEN
    ALTER TABLE public.drivers
      ADD CONSTRAINT drivers_filing_status_check
      CHECK (filing_status IS NULL OR filing_status IN
        ('single','married','married_separate','head_of_household'));
  END IF;
END$$;
-- ----------------------------------------------------------------------------
-- 4. HR & contact fields
-- ----------------------------------------------------------------------------
ALTER TABLE public.drivers
  ADD COLUMN IF NOT EXISTS hire_date                DATE,
  ADD COLUMN IF NOT EXISTS termination_date         DATE,
  ADD COLUMN IF NOT EXISTS dob                      DATE,
  ADD COLUMN IF NOT EXISTS address                  TEXT,
  ADD COLUMN IF NOT EXISTS city                     TEXT,
  ADD COLUMN IF NOT EXISTS state                    TEXT,
  ADD COLUMN IF NOT EXISTS zip                      TEXT,
  ADD COLUMN IF NOT EXISTS emergency_contact_name   TEXT,
  ADD COLUMN IF NOT EXISTS emergency_contact_phone  TEXT,
  ADD COLUMN IF NOT EXISTS cdl_number               TEXT,
  ADD COLUMN IF NOT EXISTS cdl_state                TEXT,
  ADD COLUMN IF NOT EXISTS cdl_expiration           DATE;
-- ----------------------------------------------------------------------------
-- 5. Indexes for the payroll generator (driver picker queries)
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_drivers_profile_worker_type
  ON public.drivers (profile_id, worker_type);
CREATE INDEX IF NOT EXISTS idx_drivers_profile_active
  ON public.drivers (profile_id, active);
-- ----------------------------------------------------------------------------
-- 6. Column comments — schema self-documents
-- ----------------------------------------------------------------------------
COMMENT ON COLUMN public.drivers.worker_type IS
  'Driver classification: ''1099'' (contractor / owner-operator) or ''W2'' '
  '(employee). Defaults to ''1099'' so existing iOS rows remain valid.';
COMMENT ON COLUMN public.drivers.escrow_per_settlement IS
  '1099 only. Optional. Amount auto-added as an escrow_deposit line item on '
  'every contractor settlement until escrow_balance reaches the carrier''s '
  'target reserve.';
COMMENT ON COLUMN public.drivers.escrow_balance IS
  '1099 only. Running escrow balance held on behalf of the contractor. '
  'Increased by escrow_deposit lines, decreased by escrow_release lines.';
COMMENT ON COLUMN public.drivers.ssn_encrypted IS
  'Application-layer-encrypted SSN. The database never sees plaintext. '
  'Phase W2 leaves the encryption key strategy as a placeholder — '
  'wire to Supabase Vault or an external KMS before storing real PII.';
COMMENT ON COLUMN public.drivers.ein IS
  '1099 contractor EIN if the contractor invoices through an LLC/Inc. '
  'Used on year-end 1099-NEC export.';
