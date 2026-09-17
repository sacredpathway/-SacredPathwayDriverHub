-- ============================================================================
-- Sacred Pathway Driver Hub — Carrier HQ · Phase W9
-- 20260525000000_activity_log.sql
-- ----------------------------------------------------------------------------
-- Adds a single thin table that records every write the web makes against
-- the carrier's primary entities (loads, drivers, expenses, documents,
-- paystubs, settlements). Powers the /dashboard recent-activity feed and
-- gives future audit/RBAC features a single source of truth.
--
-- Rules:
--   • ADDITIVE ONLY — pure CREATE statements. No DROP, no RENAME, no
--     NOT NULL tightening on any existing table.
--   • Idempotent — IF NOT EXISTS / DROP-AND-RECREATE policy.
--   • Zero iOS impact — iOS Swift never reads or writes this table.
--   • Logging is fire-and-forget from the web actions; failures here must
--     never fail the underlying write.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.activity_log (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  -- Who performed the action. NULL when the row was written by a future
  -- background job (Phase W9+); for now this matches profile_id.
  actor_user_id   UUID REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Free-text discriminators so future entities can be added with no
  -- migration. Validated server-side (TS string union); the DB stays loose.
  entity_type     TEXT NOT NULL,             -- 'load' | 'paystub' | 'driver' | 'expense' | 'document' | 'settlement' | 'profile'
  entity_id       UUID,                      -- nullable: bulk uploads log a single row w/ no id
  action          TEXT NOT NULL,             -- 'created' | 'updated' | 'deleted' | 'issued' | 'paid' | 'voided' | 'uploaded' | 'converted' | ...

  -- Small JSON payload for the activity feed: a human-readable label, a
  -- $ amount, a status transition - whatever the originating action wants
  -- to show. Capped indirectly by row size; no schema.
  metadata        JSONB,

  created_at      TIMESTAMPTZ DEFAULT NOW()
);
-- Primary access pattern: "the last N activities for this carrier" - hit by
-- the dashboard on every page load. (profile_id, created_at DESC) covers it
-- and is the only index we expect to actually need.
CREATE INDEX IF NOT EXISTS idx_activity_profile_time
  ON public.activity_log (profile_id, created_at DESC);
-- Secondary: "everything touching this load / driver / paystub" - useful for
-- the future entity-detail history sidebar. Partial so we don't waste an
-- index entry on bulk rows that have no entity_id.
CREATE INDEX IF NOT EXISTS idx_activity_entity
  ON public.activity_log (profile_id, entity_type, entity_id, created_at DESC)
  WHERE entity_id IS NOT NULL;
-- RLS - identical shape to every other carrier-owned table.
ALTER TABLE public.activity_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own activity" ON public.activity_log;
CREATE POLICY "own activity" ON public.activity_log
  FOR ALL
  USING (profile_id = auth.uid())
  WITH CHECK (profile_id = auth.uid());
