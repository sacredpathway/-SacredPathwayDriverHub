-- ============================================================================
-- Sacred Pathway Driver Hub — Carrier HQ Fleet · Phase W3 step 2
-- 20260522000000_fleet_trucks_trailers.sql
-- ----------------------------------------------------------------------------
-- Adds the fleet foundation: trucks + trailers. Both are carrier-owned (FK to
-- profiles), RLS-secured the same way every other carrier-owned table is, and
-- share a common status enum so the Carrier HQ UI can paint a status pill on
-- either one with one shared component.
--
-- Phase scope: create + list. Edit / delete / link-to-loads ships later.
--
-- Rules:
--   • Additive only — no DROP, no RENAME, no NOT NULL tightening on existing.
--   • Idempotent — IF NOT EXISTS / DROP-AND-RECREATE policies / DO blocks.
--   • No iOS impact — these tables are not referenced by the iOS Swift code.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TRUCKS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trucks (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  unit_number    TEXT NOT NULL,                  -- carrier-facing truck #, e.g. "7"
  make           TEXT,
  model          TEXT,
  year           INTEGER,
  vin            TEXT,
  plate_number   TEXT,
  state          TEXT,                            -- plate state, 2-letter

  status         TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','inactive','maintenance','sold')),

  notes          TEXT,

  created_at     TIMESTAMPTZ DEFAULT NOW(),
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_trucks_profile_status
  ON public.trucks (profile_id, status);
CREATE INDEX IF NOT EXISTS idx_trucks_profile_unit
  ON public.trucks (profile_id, unit_number);
-- ----------------------------------------------------------------------------
-- 2. TRAILERS
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trailers (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  unit_number    TEXT NOT NULL,
  trailer_type   TEXT,                            -- 'dry_van','reefer','flatbed',
                                                  -- 'step_deck','tanker','other'
  make           TEXT,
  model          TEXT,
  year           INTEGER,
  vin            TEXT,
  plate_number   TEXT,
  state          TEXT,

  status         TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','inactive','maintenance','sold')),

  notes          TEXT,

  created_at     TIMESTAMPTZ DEFAULT NOW(),
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'trailers_trailer_type_check'
  ) THEN
    ALTER TABLE public.trailers
      ADD CONSTRAINT trailers_trailer_type_check
      CHECK (trailer_type IS NULL OR trailer_type IN
        ('dry_van','reefer','flatbed','step_deck','tanker','lowboy','car_hauler',
         'container','dump','hopper','other'));
  END IF;
END$$;
CREATE INDEX IF NOT EXISTS idx_trailers_profile_status
  ON public.trailers (profile_id, status);
CREATE INDEX IF NOT EXISTS idx_trailers_profile_unit
  ON public.trailers (profile_id, unit_number);
-- ----------------------------------------------------------------------------
-- 3. updated_at triggers (reuses the existing public.set_updated_at helper)
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'set_updated_at' AND pronamespace = 'public'::regnamespace
  ) THEN
    CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS TRIGGER AS $fn$
    BEGIN
      NEW.updated_at = NOW();
      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql;
  END IF;
END$$;
DROP TRIGGER IF EXISTS trucks_set_updated_at ON public.trucks;
CREATE TRIGGER trucks_set_updated_at
  BEFORE UPDATE ON public.trucks
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS trailers_set_updated_at ON public.trailers;
CREATE TRIGGER trailers_set_updated_at
  BEFORE UPDATE ON public.trailers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
-- ----------------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY (identical shape on both tables)
-- ----------------------------------------------------------------------------
ALTER TABLE public.trucks   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trailers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own trucks"   ON public.trucks;
CREATE POLICY "own trucks" ON public.trucks
  FOR ALL USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());
DROP POLICY IF EXISTS "own trailers" ON public.trailers;
CREATE POLICY "own trailers" ON public.trailers
  FOR ALL USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());
-- ----------------------------------------------------------------------------
-- 5. Comments
-- ----------------------------------------------------------------------------
COMMENT ON TABLE public.trucks IS
  'Carrier-owned power units. Status enum: active/inactive/maintenance/sold. '
  'Phase W3 step 2 lands create+list only — edit, delete, and load linkage '
  'arrive in later W3 steps.';
COMMENT ON TABLE public.trailers IS
  'Carrier-owned trailers. Same status enum as trucks. trailer_type is '
  'optional but normalized so reports can group by equipment class.';
