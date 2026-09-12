# Driver Pay & Settlements — Phase 1 Audit

Repo: `~/Developer/SacredPathwayDriverHub`
Branch created: `feature/driver-pay-settlements` (off `agent/load-lifecycle-review` @ `4ab7b8b`)
Backup tag: `pre-settlements-2026-09-12`
Date: 2026-09-12

> ⚠️ Version note: this working copy is **2.1.4 (35)**. The sibling
> `~/Developer/SacredPathway-stable` is **2.3.3 (43)** with the same bundle id,
> 166 Swift files, Maps, StoreKit config and a wired `SacredPathwayTests` target.
> You chose this copy — recorded here so the divergence is not a surprise later.

---

## 1. Framework and language
- Swift 5.9 / SwiftUI, iOS 17 minimum.
- Xcode project `SacredPathway.xcodeproj`, `objectVersion = 56` (explicit file
  references — **every new .swift file needs a pbxproj entry**, there is no
  Xcode-16 synchronized folder group).
- `Package.swift` exists for SPM deps only: `supabase-swift` 2.x, `TPPDF` 2.x.
- 119 Swift files, ~48k lines.

## 2. Navigation structure
Role-routed at `ContentView.swift`. Four root tab bars:

| Role | Tabs |
|---|---|
| Dispatcher | Dispatch · Account |
| Carrier | Home · Loads · Expenses · Dispatch · Settings |
| Driver | Dashboard · Loads · Paycheck · Expenses · Messages |
| Owner Operator | Home · Loads · Expenses · Dispatch · Settings |

Settlement screens are **not** top-level today — they are buried in
`SettingsView` rows (`SettlementGeneratorView`, `ManualPaystubView`,
`PaystubDraftsListView`, `DriversListView`, `DocumentVaultView`) and in
`MoreTabView`.

## 3. Driver model — `Models/Driver.swift`
`id, profileId, name, truckNumber, payPercentage, payType ("percent"|"flat"),
flatRate, phone, email, active, createdAt`.
Helper `isFlatRate`.

> Live Supabase `drivers` table is **far wider** than the Swift struct: it already
> has `worker_type`, `escrow_per_settlement`, `escrow_balance`, `comp_type`,
> `hourly_rate`, `salary_annual`, `mileage_rate`, `per_load_rate`,
> `per_diem_daily`, `overtime_multiplier`, W-4 fields, CDL fields and PII
> (`ssn_encrypted`, `dob`, `address`). The app never reads them. These are the
> columns the new pay-method work should bind to — no new columns needed for
> per-mile / salary / hourly / per-load.

## 4. Truck / Unit model
**None in Swift.** Truck is a free-text `truck_number` string on `Profile`,
`Driver` and `Load`. Live Supabase already has `trucks` and `trailers` tables
(unit_number, make, model, year, vin, plate, state, status) that the app does
not use.

## 5. Load model — `Models/Load.swift`
Has: `loadNumber, brokerName, brokerMcNumber, truckNumber, trailerNumber,
pickupDate, deliveryDate, origin, destination, totalMiles, emptyMiles,
lineHaulRate, fuelSurcharge, accessorialCharges, totalRevenue, driverPayType,
driverPercentage, driverRatePerMile, driverGrossPay, weight, dispatch linkage,
broker-rep snapshot fields, status`.
`LoadStatus`: `unassigned | assigned | ready_for_settlement | settled`.
Custom `Codable` with legacy-column aliasing (`loaded_miles`, `gross_load_pay`,
`pay_type`).
**Missing for the brief:** detention, layover, TONU, lumper reimbursement as
discrete fields (today they collapse into `accessorialCharges`).

## 6. Expense model — `Models/Expense.swift`
`id, loadId, profileId, category, amount, vendorName, description, gallons,
pricePerGallon, defGallons, defPricePerGallon, defTotal, receiptDate, createdAt`.
No driver linkage, no settlement linkage, no responsibility split.

## 7. Document / upload system
`Models/TruckDocument.swift` → Supabase `documents` table + Storage bucket.
Scan pipeline: VisionKit (`DocumentScannerCoordinator`) → `LocalDocumentParser`
(3.3k lines, on-device) or `DocumentExtractionService` (Edge Function).
Viewer: `DocumentVaultView`. Linkage today is `load_id` only.

## 8. Authentication and roles
- Supabase Auth (email/password, OTP, Sign in with Apple) in `SupabaseService`.
- `AccountRole`: `dispatcher | carrier | driver | owner_operator` on `profiles`.
- `AccessGate` gates on auth + StoreKit entitlement
  (`unauthenticated → needsSubscription → subscribed`).
- `PinLockService` = local PIN lock. **Not** per-driver auth — there is no
  driver login separate from the account owner in this copy.
- DB has `carrier_members` (role/status/linked_driver_id) — unused by the app.

## 9. Database — dual mode
`AppMode` = `.local` | `.cloud`.
- **Local:** `LocalStore` JSON files in `Documents/DriverHub/*.json`, one
  repository per entity (`LocalLoadsRepository`, `LocalExpensesRepository`, …).
- **Cloud:** Supabase project `rmzqxsfhjqrshhdjzhze`, RLS on every table.
  `settlements` table exists (0 rows) with only the flat legacy column set and
  a `paystub_id` FK.
**Any new settlement feature must ship in both stores.**

## 10. PDF generation
Three engines already exist — do not add a fourth:
- `SettlementHTMLPDFService` — **canonical**. `Resources/sph_template.html` →
  WKWebView → vector PDF. Already accepts statementId, status, YTD,
  adjustments, escrow, payment method, driver address.
- `PaystubPDFService` — TPPDF fallback, same parameter surface.
- `SettlementSheetPDFService` — owner-operator "settlement sheet" layout.
- Plus `CPAPDFGenerator`, `IFTAPDFService`.
Preview/share: `PDFPreviewView`.

## 11. Notifications
No local `UNUserNotificationCenter` usage outside `DispatchService` (push for
dispatch messages). Supabase has an unused `notifications` table.

## 12. Reporting / dashboards
`DashboardView`, `WeeklyStatsService`, `InsightsService` (854 lines),
`SmartInsightsView`, `CPAExportService` + `CPAReadyExportView`, `IFTAHubView`.
Week bucketing is centralised in `PayWeekService` (configurable first weekday,
loads bucket by **pickup date**) — the new settlement period picker must use it.

## 13. Payment-related logic
`SettlementEngine.calculate(...)` — 111 lines, **all `Double`**, single shape:
revenue − expenses = grossProfit; driver % of gross profit or revenue, or flat;
dispatcher %, factoring %, authority fee, maintenance reserve, custom fees;
`carrierNetPay`.
`CustomFeeService` persists user-defined fees (`FeeItem`) →
`SettlementCustomDeduction`.
Call sites: `SettlementGeneratorView` (×2), `PaystubExpenseReviewView`,
`ManualPaystubView` (constructs the struct directly).
**Gaps vs brief:** floating-point money, no settlement numbers, no status
lifecycle, no additions, no recurring deductions, no advances, no audit trail,
no per-load driver earnings persistence, no double-pay protection beyond the
`settled` flag.

## 14. Existing tests
- `SacredPathwayUITests/ReleaseWorkflowUITests.swift` (373 lines, XCUITest).
- **No unit-test target in this copy.** (The sibling stable copy has one with
  `SettlementEngineTests.swift`.) A `SacredPathwayTests` bundle target must be
  added to the pbxproj.
- `Services/Local/LocalSmokeTest.swift` is an in-app smoke test, not XCTest.

## 15. Migrations required
Additive only, no drops, no data loss:

| Object | Type | Notes |
|---|---|---|
| `settlements` | ALTER | add settlement_number, settlement_type, truck_id, pay_method, gross_load_revenue, total_driver_earnings, total_additions, total_deductions, company_retained, notes, updated_at, approved_at, paid_at, created_by, approved_by, payment_reference, voided_at |
| `settlement_loads` | NEW | snapshot of each load's numbers at settlement time |
| `settlement_additions` | NEW | credits |
| `settlement_deductions` | NEW | debits, responsibility split |
| `recurring_deductions` | NEW | per-driver schedule |
| `driver_advances` | NEW | advance + outstanding balance |
| `driver_advance_repayments` | NEW | per-settlement recovery ledger |
| `settlement_audit_events` | NEW | append-only |
| `documents` | ALTER | add settlement_id, addition_id, deduction_id nullable FKs |
| `drivers` | ALTER | add settlement_type, pay_method defaults (columns for per-mile/salary/hourly already exist) |

All with RLS mirroring existing `profile_id = auth.uid()` policies.
**Migration SQL will be written to `supabase/migrations/` only — not applied.**

---

## Decisions taken
1. **Extend, do not duplicate.** `Settlement`, `Load`, `Expense`, `Driver`,
   `TruckDocument`, `SettlementHTMLPDFService`, `LocalStore` repositories and
   `PayWeekService` are all reused.
2. **New money type.** A `Money` value type wrapping `Decimal` with explicit
   half-up rounding at accounting boundaries. Existing `Double` APIs stay for
   backward compatibility; the new engine is Decimal end-to-end and converts
   at the boundary.
3. **Engine, not views.** All math moves into `SettlementCalculationEngine`.
   The legacy `SettlementEngine.calculate` is kept and re-implemented on top of
   the new engine so existing screens and their results do not change.
4. **Navigation.** A `Settlements` tab is added to the Carrier and
   Owner Operator tab bars; the Driver role gets a read-only settlement area
   under its existing `Paycheck` tab. Dispatcher is untouched.
5. **Verification.** A Swift 5.10 toolchain now runs in the session sandbox, so
   the Decimal engine, models and their tests are compiled and executed here.
   The full iOS app build (SwiftUI/UIKit) still requires Xcode on the Mac.
