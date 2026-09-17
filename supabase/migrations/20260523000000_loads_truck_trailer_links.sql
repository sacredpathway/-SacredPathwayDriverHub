-- ============================================================================
-- Sacred Pathway Driver Hub — Carrier HQ Fleet · Phase W3 step 3
-- 20260523000000_loads_truck_trailer_links.sql
-- ----------------------------------------------------------------------------
-- Links loads to fleet units. Both FKs are NULLABLE so:
--   • Existing loads (created by iOS or earlier web flows) keep working
--     unchanged — no backfill needed.
--   • Carriers without a fleet section filled out can still record loads.
--   • Deleting a truck/trailer does NOT cascade-delete loads; the FK uses
--     ON DELETE SET NULL so historical loads keep their attribution metadata
--     but the link is severed.
--
-- Rules:
--   • Additive only — no DROP, no RENAME, no NOT NULL tightening.
--   • Idempotent — ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.
--   • Zero iOS impact — the iOS Swift Load model ignores unknown columns
--     when decoding, so legacy clients keep parsing loads correctly.
-- ============================================================================

ALTER TABLE public.loads
  ADD COLUMN IF NOT EXISTS truck_id   UUID REFERENCES public.trucks(id)   ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS trailer_id UUID REFERENCES public.trailers(id) ON DELETE SET NULL;
-- Indexes for the "loads on this truck" and "loads on this trailer" views the
-- fleet detail screen will need in a later step. Both partial so we don't waste
-- index space on the historic NULL majority.
CREATE INDEX IF NOT EXISTS idx_loads_truck_id
  ON public.loads (truck_id)
  WHERE truck_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_loads_trailer_id
  ON public.loads (trailer_id)
  WHERE trailer_id IS NOT NULL;
COMMENT ON COLUMN public.loads.truck_id IS
  'Fleet power unit assigned to this load. Nullable. ON DELETE SET NULL so '
  'historic loads survive truck deletion without losing the rest of their '
  'attribution. Set/cleared from Carrier HQ web; iOS does not write this column.';
COMMENT ON COLUMN public.loads.trailer_id IS
  'Fleet trailer assigned to this load. Nullable. ON DELETE SET NULL. '
  'Set/cleared from Carrier HQ web; iOS does not write this column.';
