-- ================================================================
-- SACRED PATHWAY — OpenAI Document Extraction Refactor
-- Filename mirrors Supabase CLI convention: <timestamp>_<name>.sql
-- ----------------------------------------------------------------
-- This migration:
--   1. Extends the `documents` table with the columns the new
--      backend extraction pipeline writes to.
--   2. Creates a private `documents` Storage bucket and locks it
--      down with per-user RLS (objects live under "<profile_id>/").
--   3. Adds an updated_at trigger so the iOS app can sync changes.
-- Idempotent: safe to re-run.
-- ================================================================

-- ---------- 1. EXTEND documents TABLE ----------
ALTER TABLE documents
  ADD COLUMN IF NOT EXISTS raw_text       TEXT,
  ADD COLUMN IF NOT EXISTS status         TEXT NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS error_message  TEXT,
  ADD COLUMN IF NOT EXISTS is_manual      BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS provider       TEXT NOT NULL DEFAULT 'openai',
  ADD COLUMN IF NOT EXISTS model          TEXT,
  ADD COLUMN IF NOT EXISTS file_mime_type TEXT,
  ADD COLUMN IF NOT EXISTS file_size      INTEGER,
  ADD COLUMN IF NOT EXISTS retry_count    INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS updated_at     TIMESTAMPTZ DEFAULT NOW();
-- Constrain status to a known set
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'documents_status_check'
  ) THEN
    ALTER TABLE documents
      ADD CONSTRAINT documents_status_check
      CHECK (status IN ('pending','processing','processed','failed','manual'));
  END IF;
END$$;
-- Indexes for the dashboard queries
CREATE INDEX IF NOT EXISTS documents_profile_status_idx
  ON documents (profile_id, status);
CREATE INDEX IF NOT EXISTS documents_profile_created_idx
  ON documents (profile_id, created_at DESC);
-- updated_at trigger
CREATE OR REPLACE FUNCTION set_documents_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS documents_set_updated_at ON documents;
CREATE TRIGGER documents_set_updated_at
  BEFORE UPDATE ON documents
  FOR EACH ROW EXECUTE FUNCTION set_documents_updated_at();
-- ---------- 2. STORAGE BUCKET ----------
-- Private bucket. Files are downloaded by the Edge Function via the
-- service role; the iOS app uploads using the user's JWT.
--
-- The allowlist still includes application/pdf so you can add a PDF
-- sidecar upload later, but today the iPhone always uploads a JPEG
-- render (including PDF first-page renders) so OpenAI's vision
-- endpoint will accept it.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'documents',
  'documents',
  FALSE,
  20971520,  -- 20 MB cap per file
  ARRAY['image/jpeg','image/png','image/heic','image/heif','application/pdf']
)
ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;
-- Storage RLS: every object lives under "<profile_id>/..." and the
-- carrier owning that profile_id is the only one allowed to touch it.
DROP POLICY IF EXISTS "doc_select_own" ON storage.objects;
DROP POLICY IF EXISTS "doc_insert_own" ON storage.objects;
DROP POLICY IF EXISTS "doc_update_own" ON storage.objects;
DROP POLICY IF EXISTS "doc_delete_own" ON storage.objects;
CREATE POLICY "doc_select_own" ON storage.objects FOR SELECT
  USING (bucket_id = 'documents'
         AND (storage.foldername(name))[1] = auth.uid()::text);
CREATE POLICY "doc_insert_own" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'documents'
              AND (storage.foldername(name))[1] = auth.uid()::text);
CREATE POLICY "doc_update_own" ON storage.objects FOR UPDATE
  USING (bucket_id = 'documents'
         AND (storage.foldername(name))[1] = auth.uid()::text);
CREATE POLICY "doc_delete_own" ON storage.objects FOR DELETE
  USING (bucket_id = 'documents'
         AND (storage.foldername(name))[1] = auth.uid()::text);
-- ---------- 3. BACKFILL ----------
UPDATE documents
   SET status = CASE
                  WHEN processed = TRUE THEN 'processed'
                  ELSE 'pending'
                END
 WHERE processed IS NOT NULL
   AND status = 'pending';
