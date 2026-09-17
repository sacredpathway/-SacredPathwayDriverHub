-- ============================================================================
-- Sacred Pathway Driver Hub — Carrier HQ · Phase W4
-- 20260524000000_profile_branding.sql
-- ----------------------------------------------------------------------------
-- Adds carrier branding + company-profile columns to public.profiles, and
-- a private `branding` storage bucket for company logos.
--
-- Used by:
--   • /settings              (company profile form)
--   • /settings/paystub      (paystub theme + footer legal)
--   • <Nav>                  (renders company_name + logo)
--   • (future) PaystubPDFService — pulls theme + footer + logo at render time
--
-- Rules:
--   • ADDITIVE ONLY — no DROP, no RENAME, no NOT NULL tightening.
--   • Every new column is nullable (or has a default) so existing iOS-created
--     profile rows decode cleanly. iOS Swift `Profile` Codable ignores unknown
--     keys, so this migration is invisible to the live mobile app.
--   • Idempotent — IF NOT EXISTS / DO blocks / DROP-AND-RECREATE policies.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Profile branding + company columns
-- ----------------------------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS logo_storage_path     TEXT,
  ADD COLUMN IF NOT EXISTS paystub_theme         TEXT DEFAULT 'navy_gold',
  ADD COLUMN IF NOT EXISTS paystub_footer_legal  TEXT,
  ADD COLUMN IF NOT EXISTS company_address       TEXT,
  ADD COLUMN IF NOT EXISTS company_city          TEXT,
  ADD COLUMN IF NOT EXISTS company_state         TEXT,
  ADD COLUMN IF NOT EXISTS company_zip           TEXT,
  ADD COLUMN IF NOT EXISTS company_ein           TEXT;
-- Theme is a string (not an enum) so we can add new themes via web only,
-- without a follow-up migration. Validated server-side in actions.ts.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'profiles_paystub_theme_check'
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_paystub_theme_check
      CHECK (
        paystub_theme IS NULL
        OR paystub_theme IN ('navy_gold','forest_gold','black_silver','blue_gray')
      );
  END IF;
END$$;
-- ----------------------------------------------------------------------------
-- 2. Branding storage bucket (private)
-- ----------------------------------------------------------------------------
-- Logos live under "<profile_id>/logo.<ext>". RLS keyed on the same prefix
-- shape every other private bucket uses (documents, compliance-docs).
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'branding',
  'branding',
  false,
  5242880,  -- 5 MB
  ARRAY['image/png','image/jpeg','image/jpg','image/webp','image/svg+xml']
)
ON CONFLICT (id) DO UPDATE
  SET
    public            = EXCLUDED.public,
    file_size_limit   = EXCLUDED.file_size_limit,
    allowed_mime_types= EXCLUDED.allowed_mime_types;
-- Storage RLS — each carrier owns objects under "<profile_id>/..."
DROP POLICY IF EXISTS "branding_select_own" ON storage.objects;
CREATE POLICY "branding_select_own" ON storage.objects FOR SELECT
  USING (
    bucket_id = 'branding'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
DROP POLICY IF EXISTS "branding_insert_own" ON storage.objects;
CREATE POLICY "branding_insert_own" ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'branding'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
DROP POLICY IF EXISTS "branding_update_own" ON storage.objects;
CREATE POLICY "branding_update_own" ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'branding'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
DROP POLICY IF EXISTS "branding_delete_own" ON storage.objects;
CREATE POLICY "branding_delete_own" ON storage.objects FOR DELETE
  USING (
    bucket_id = 'branding'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
-- ----------------------------------------------------------------------------
-- 3. updated_at trigger — reuse if present, otherwise no-op (profiles already
--    has an `updated_at` column from the base schema).
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'set_updated_at' AND pronamespace = 'public'::regnamespace
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'profiles_set_updated_at'
  ) THEN
    EXECUTE 'CREATE TRIGGER profiles_set_updated_at
             BEFORE UPDATE ON public.profiles
             FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()';
  END IF;
END$$;
