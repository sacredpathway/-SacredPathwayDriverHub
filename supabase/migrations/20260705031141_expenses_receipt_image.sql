-- Phase 1 · Task 3 (2026-07-04): receipt image reference on expenses.
-- Mirrors repo file supabase/migrations/20260704200000_expenses_receipt_image.sql
-- Additive + nullable; rides existing RLS policies. Idempotent.

alter table public.expenses
  add column if not exists receipt_image_filename text;

comment on column public.expenses.receipt_image_filename is
  'Filename of the on-device receipt image (ReceiptImageStore). No path, no URL — device-local artifact reference. Added Phase 1 Task 3, 2026-07-04.';
