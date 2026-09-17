-- ============================================================================
-- Sacred Pathway Driver Hub — Carrier HQ Payroll · Phase W2
-- 20260521010000_paystubs_unified.sql
-- ----------------------------------------------------------------------------
-- Creates the unified paystub model that supports BOTH:
--   • W2 employee payroll  (earnings + pre/post-tax deductions + withholdings)
--   • 1099 contractor settlements (gross + settlement deductions + add-backs)
--
-- Why a new parent table instead of extending `settlements`:
--   • iOS continues to read/write the legacy `settlements` shape unchanged.
--   • The web (Carrier HQ) writes ONLY to `paystubs` going forward.
--   • A separate UNION view (next migration) gives reporting a single feed.
--
-- Rules:
--   • Additive only. Pure CREATE statements.
--   • Idempotent (CREATE IF NOT EXISTS, DROP-AND-RECREATE policies).
--   • All RLS keyed on profile_id = auth.uid(); identical to the rest of
--     the schema so the W4 multi-user RLS extension drops in cleanly later.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. PAYSTUBS — parent record (one per driver per pay period)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paystubs (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id                    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  driver_id                     UUID NOT NULL REFERENCES public.drivers(id)  ON DELETE RESTRICT,

  -- Snapshotted at creation so a driver classification change later never
  -- rewrites historical paystubs.
  worker_type                   TEXT NOT NULL CHECK (worker_type IN ('1099','W2')),

  paystub_number                TEXT,                       -- 'PS-2026-00041'
  pay_period_start              DATE NOT NULL,
  pay_period_end                DATE NOT NULL,
  check_date                    DATE,

  status                        TEXT NOT NULL DEFAULT 'draft'
                                CHECK (status IN ('draft','issued','paid','voided')),
  payment_method                TEXT
                                CHECK (payment_method IS NULL OR payment_method IN
                                  ('ach','zelle','cash','check','direct_deposit','other')),
  check_number                  TEXT,

  -- Totals (computed in app, persisted here for fast queries + immutability).
  gross_earnings                NUMERIC(12,2) DEFAULT 0,
  total_pretax_deductions       NUMERIC(12,2) DEFAULT 0,
  taxable_wages                 NUMERIC(12,2),              -- W2 only; NULL on 1099
  total_taxes_withheld          NUMERIC(12,2) DEFAULT 0,    -- W2 only; 0 on 1099
  total_posttax_deductions      NUMERIC(12,2) DEFAULT 0,
  total_reimbursements          NUMERIC(12,2) DEFAULT 0,
  total_settlement_deductions   NUMERIC(12,2) DEFAULT 0,    -- 1099 only
  net_pay                       NUMERIC(12,2) NOT NULL DEFAULT 0,

  -- YTD snapshot at issuance — denormalized so the printed paystub is frozen.
  ytd_gross_earnings            NUMERIC(12,2) DEFAULT 0,
  ytd_taxable_wages             NUMERIC(12,2) DEFAULT 0,
  ytd_taxes_withheld            NUMERIC(12,2) DEFAULT 0,
  ytd_net_pay                   NUMERIC(12,2) DEFAULT 0,

  -- Distribution
  pdf_storage_path              TEXT,
  emailed_to                    TEXT[],
  emailed_at                    TIMESTAMPTZ,

  -- Multi-user attribution (Phase W4-ready)
  created_by_user_id            UUID REFERENCES auth.users(id) ON DELETE SET NULL,

  notes                         TEXT,
  created_at                    TIMESTAMPTZ DEFAULT NOW(),
  updated_at                    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_paystubs_profile_check_date
  ON public.paystubs (profile_id, check_date DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_paystubs_driver_check_date
  ON public.paystubs (driver_id, check_date DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_paystubs_profile_status
  ON public.paystubs (profile_id, status);
CREATE INDEX IF NOT EXISTS idx_paystubs_profile_worker_type_period
  ON public.paystubs (profile_id, worker_type, pay_period_end);
-- updated_at trigger (reuses the existing public.set_updated_at if available)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'set_updated_at' AND pronamespace = 'public'::regnamespace
  ) THEN
    CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS TRIGGER AS $fn$
    BEGIN
      NEW.updated_at = NOW();
      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql;
  END IF;
END$$;
DROP TRIGGER IF EXISTS paystubs_set_updated_at ON public.paystubs;
CREATE TRIGGER paystubs_set_updated_at
  BEFORE UPDATE ON public.paystubs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
-- ----------------------------------------------------------------------------
-- 2. PAYSTUB_EARNINGS — W2 earnings & 1099 gross lines
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paystub_earnings (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  paystub_id  UUID NOT NULL REFERENCES public.paystubs(id) ON DELETE CASCADE,
  profile_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  kind        TEXT NOT NULL CHECK (kind IN (
                'regular','overtime','doubletime','holiday',
                'sick','vacation','bonus','commission',
                'per_diem','mileage','per_load',
                'settlement_gross',
                'detention','layover','accessorial','reimbursement','other'
              )),
  label       TEXT NOT NULL,
  hours       NUMERIC(8,2),
  units       NUMERIC(10,2),
  rate        NUMERIC(10,4),
  amount      NUMERIC(12,2) NOT NULL,
  is_taxable  BOOLEAN NOT NULL DEFAULT TRUE,
  load_id     UUID REFERENCES public.loads(id) ON DELETE SET NULL,
  ytd_amount  NUMERIC(12,2) DEFAULT 0,
  notes       TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_paystub_earnings_paystub
  ON public.paystub_earnings (paystub_id);
CREATE INDEX IF NOT EXISTS idx_paystub_earnings_profile_kind
  ON public.paystub_earnings (profile_id, kind);
CREATE INDEX IF NOT EXISTS idx_paystub_earnings_load
  ON public.paystub_earnings (load_id) WHERE load_id IS NOT NULL;
-- ----------------------------------------------------------------------------
-- 3. PAYSTUB_DEDUCTIONS — pre-tax + post-tax
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paystub_deductions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  paystub_id  UUID NOT NULL REFERENCES public.paystubs(id) ON DELETE CASCADE,
  profile_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  kind        TEXT NOT NULL CHECK (kind IN (
                -- pre-tax (W2)
                '401k','401k_roth','health_premium','dental_premium','vision_premium',
                'hsa','fsa','commuter','life_insurance','disability',
                -- post-tax (W2 + 1099)
                'garnishment','child_support','union_dues','loan_repayment','uniform',
                'advance_repayment','other'
              )),
  label       TEXT NOT NULL,
  amount      NUMERIC(12,2) NOT NULL,                       -- stored positive
  is_pre_tax  BOOLEAN NOT NULL DEFAULT FALSE,
  ytd_amount  NUMERIC(12,2) DEFAULT 0,
  notes       TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_paystub_deductions_paystub
  ON public.paystub_deductions (paystub_id);
CREATE INDEX IF NOT EXISTS idx_paystub_deductions_profile_kind
  ON public.paystub_deductions (profile_id, kind);
-- ----------------------------------------------------------------------------
-- 4. PAYSTUB_TAXES — W2 federal/state/SS/Medicare + employer placeholders
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paystub_taxes (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  paystub_id           UUID NOT NULL REFERENCES public.paystubs(id) ON DELETE CASCADE,
  profile_id           UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  kind                 TEXT NOT NULL CHECK (kind IN (
                          'federal_income','state_income','local_income',
                          'social_security','medicare','medicare_additional',
                          'sui','sdi','futa','suta','workers_comp','other'
                        )),
  jurisdiction         TEXT,
  label                TEXT NOT NULL,
  employee_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
  employer_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
  ytd_employee_amount  NUMERIC(12,2) DEFAULT 0,
  ytd_employer_amount  NUMERIC(12,2) DEFAULT 0,
  rate_basis           TEXT
                       CHECK (rate_basis IS NULL OR rate_basis IN
                         ('manual','flat_percent','table_lookup')),
  notes                TEXT,
  created_at           TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_paystub_taxes_paystub
  ON public.paystub_taxes (paystub_id);
CREATE INDEX IF NOT EXISTS idx_paystub_taxes_profile_kind
  ON public.paystub_taxes (profile_id, kind);
CREATE INDEX IF NOT EXISTS idx_paystub_taxes_profile_jurisdiction
  ON public.paystub_taxes (profile_id, jurisdiction);
-- ----------------------------------------------------------------------------
-- 5. PAYSTUB_SETTLEMENT_ITEMS — 1099 contractor settlement lines
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.paystub_settlement_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  paystub_id  UUID NOT NULL REFERENCES public.paystubs(id) ON DELETE CASCADE,
  profile_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  kind        TEXT NOT NULL CHECK (kind IN (
                'escrow_deposit','escrow_release',
                'advance','advance_repayment',
                'fuel_advance','fuel_deduction',
                'toll','maintenance','tire','permit',
                'eld_lease','truck_lease','trailer_lease','plate',
                'insurance','occupational_accident','cargo_insurance',
                'chargeback','damage','claim',
                'factoring_fee','dispatcher_fee','authority_fee','maintenance_reserve',
                'reimbursement','bonus','detention_pay','layover_pay',
                'other'
              )),
  label       TEXT NOT NULL,
  amount      NUMERIC(12,2) NOT NULL,                       -- stored positive
  direction   TEXT NOT NULL CHECK (direction IN ('deduct','add')),
  load_id     UUID REFERENCES public.loads(id) ON DELETE SET NULL,
  ytd_amount  NUMERIC(12,2) DEFAULT 0,
  notes       TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_paystub_settlement_items_paystub
  ON public.paystub_settlement_items (paystub_id);
CREATE INDEX IF NOT EXISTS idx_paystub_settlement_items_profile_kind
  ON public.paystub_settlement_items (profile_id, kind);
CREATE INDEX IF NOT EXISTS idx_paystub_settlement_items_load
  ON public.paystub_settlement_items (load_id) WHERE load_id IS NOT NULL;
-- ----------------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY (identical shape on every table)
-- ----------------------------------------------------------------------------
ALTER TABLE public.paystubs                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.paystub_earnings         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.paystub_deductions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.paystub_taxes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.paystub_settlement_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own paystubs"                 ON public.paystubs;
CREATE POLICY "own paystubs" ON public.paystubs
  FOR ALL USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());
DROP POLICY IF EXISTS "own paystub_earnings"         ON public.paystub_earnings;
CREATE POLICY "own paystub_earnings" ON public.paystub_earnings
  FOR ALL USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());
DROP POLICY IF EXISTS "own paystub_deductions"       ON public.paystub_deductions;
CREATE POLICY "own paystub_deductions" ON public.paystub_deductions
  FOR ALL USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());
DROP POLICY IF EXISTS "own paystub_taxes"            ON public.paystub_taxes;
CREATE POLICY "own paystub_taxes" ON public.paystub_taxes
  FOR ALL USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());
DROP POLICY IF EXISTS "own paystub_settlement_items" ON public.paystub_settlement_items;
CREATE POLICY "own paystub_settlement_items" ON public.paystub_settlement_items
  FOR ALL USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());
-- ----------------------------------------------------------------------------
-- 7. Table comments
-- ----------------------------------------------------------------------------
COMMENT ON TABLE public.paystubs IS
  'Unified payroll parent record. One row per (driver, pay period). '
  'worker_type drives which child tables are populated: W2 uses '
  'paystub_earnings + paystub_deductions + paystub_taxes; 1099 uses '
  'paystub_earnings + paystub_settlement_items (+ optional deductions).';
COMMENT ON TABLE public.paystub_earnings IS
  'Earnings line items. W2 rows are regular/OT/per-diem/bonus etc. '
  '1099 rows are typically kind=''settlement_gross'' linked to load_id.';
COMMENT ON TABLE public.paystub_deductions IS
  'Pre-tax and post-tax deductions. Used by both worker types but most '
  'common on W2 (401k, health premiums, garnishments).';
COMMENT ON TABLE public.paystub_taxes IS
  'W2-only withholdings. employee_amount is what is taken from the check; '
  'employer_amount is the employer match (SS, Medicare, FUTA, SUTA, WC). '
  'No automatic compute in Phase W2 — all values are manual / placeholder.';
COMMENT ON TABLE public.paystub_settlement_items IS
  '1099-only settlement lines: deductions (fuel, escrow, chargebacks, fees) '
  'and add-backs (reimbursements, bonuses, detention). direction=''deduct'' '
  'or ''add'' controls sign in the net-pay calc.';
