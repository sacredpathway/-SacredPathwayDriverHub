-- ============================================================================
-- Sacred Pathway Driver Hub — Carrier HQ Payroll · Phase W2
-- 20260521020000_settlements_link_paystub.sql
-- ----------------------------------------------------------------------------
-- Optional FK from legacy `settlements` rows (still used by iOS) to the new
-- `paystubs` parent. Nullable. Set only when a web-generated paystub
-- intentionally replaces or supersedes a legacy settlement row.
--
-- Why nullable / no backfill:
--   • Existing iOS settlements remain valid and untouched.
--   • We never auto-link old rows; the carrier opts in by re-issuing the
--     paystub on the web. The link is for audit clarity only.
--
-- Rules:
--   • Additive only.
--   • Idempotent.
--   • No iOS code or behavior changes.
-- ============================================================================

ALTER TABLE public.settlements
  ADD COLUMN IF NOT EXISTS paystub_id UUID
    REFERENCES public.paystubs(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_settlements_paystub_id
  ON public.settlements (paystub_id)
  WHERE paystub_id IS NOT NULL;
COMMENT ON COLUMN public.settlements.paystub_id IS
  'Optional. Set to the unified paystubs.id when a web-generated paystub '
  'supersedes this legacy iOS-generated settlement. The iOS app continues '
  'to read settlements without referencing this column.';
