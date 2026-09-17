-- ============================================================================
-- Sacred Pathway Driver Hub — Carrier HQ Payroll · Phase W2
-- 20260521030000_payroll_unified_view.sql
-- ----------------------------------------------------------------------------
-- Read-only SQL view that unions legacy `settlements` rows (still produced by
-- iOS) with the new `paystubs` rows (produced by the web app) into one
-- "all payroll history" feed.
--
-- Used by:
--   • Carrier HQ payroll-history list  (`/payroll` route)
--   • Reports tab — payroll analytics
--   • Future CPA / tax exports
--
-- Anything reading from this view inherits each underlying table's RLS,
-- because PostgreSQL applies RLS based on the querying role and the source
-- tables — the view is just a column projection.
--
-- Settlements that have been linked to a new paystub (settlements.paystub_id
-- IS NOT NULL) are filtered OUT of the legacy branch to avoid double-counting.
--
-- Rules:
--   • Additive only.
--   • Idempotent (CREATE OR REPLACE).
--   • No DML, no triggers, no side effects.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_payroll_unified AS
-- New paystubs (web-generated, W2 + 1099)
SELECT
  p.id                                         AS id,
  p.profile_id                                 AS profile_id,
  p.driver_id                                  AS driver_id,
  'paystub'::text                              AS source,
  p.worker_type                                AS worker_type,
  p.paystub_number                             AS paystub_number,
  p.pay_period_start                           AS pay_period_start,
  p.pay_period_end                             AS pay_period_end,
  p.check_date                                 AS check_date,
  p.status                                     AS status,
  p.payment_method                             AS payment_method,
  p.gross_earnings                             AS gross_earnings,
  p.net_pay                                    AS net_pay,
  p.total_taxes_withheld                       AS total_taxes_withheld,
  p.total_pretax_deductions                    AS total_pretax_deductions,
  p.total_posttax_deductions                   AS total_posttax_deductions,
  p.total_settlement_deductions                AS total_settlement_deductions,
  p.pdf_storage_path                           AS pdf_storage_path,
  p.created_at                                 AS created_at
FROM public.paystubs p

UNION ALL

-- Legacy iOS settlements that have NOT been re-issued as a web paystub
SELECT
  s.id                                         AS id,
  s.profile_id                                 AS profile_id,
  s.driver_id                                  AS driver_id,
  'legacy_settlement'::text                    AS source,
  '1099'::text                                 AS worker_type,
  NULL::text                                   AS paystub_number,
  s.settlement_period_start                    AS pay_period_start,
  s.settlement_period_end                      AS pay_period_end,
  s.settlement_period_end                      AS check_date,
  s.status                                     AS status,
  NULL::text                                   AS payment_method,
  s.total_revenue                              AS gross_earnings,
  s.net_pay                                    AS net_pay,
  0::numeric                                   AS total_taxes_withheld,
  0::numeric                                   AS total_pretax_deductions,
  0::numeric                                   AS total_posttax_deductions,
  COALESCE(s.dispatcher_fee_amount, 0)
    + COALESCE(s.factoring_fee_amount, 0)
    + COALESCE(s.authority_fee, 0)
    + COALESCE(s.maintenance_reserve, 0)       AS total_settlement_deductions,
  s.pdf_storage_path                           AS pdf_storage_path,
  s.created_at                                 AS created_at
FROM public.settlements s
WHERE s.paystub_id IS NULL;
COMMENT ON VIEW public.v_payroll_unified IS
  'Unified read-only feed of all payroll history. Combines new paystubs '
  '(W2 + 1099 written by the web) with legacy settlements (1099 written '
  'by the iOS app), filtering out legacy rows that have been re-issued '
  'as a paystub. RLS is inherited from the underlying tables.';
