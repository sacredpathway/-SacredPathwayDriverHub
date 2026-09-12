# Driver Pay & Settlements — Phase A Report

Repo: `~/Developer/SacredPathwayDriverHub`
Branch: `feature/driver-pay-settlements`
Backup tag: `pre-settlements-2026-09-12`
Date: 2026-09-12

**Nothing has been published, deployed, submitted or applied to the live database.**

---

## ✅ What shipped in Phase A

| Area | Status |
|---|---|
| Decimal-safe money type | Done |
| Settlement data model (header + 7 child types) | Done |
| Centralised calculation engine | Done |
| Pay methods: %, flat/load, per-mile, salary, hourly, manual, combination | Done |
| Lease-operator responsibility rules | Done |
| Recurring deductions | Done |
| Driver advances + repayment ledger | Done |
| Settlement numbers | Done |
| Validation / guardrails | Done |
| Audit trail | Done |
| Supabase migration (written, **not applied**) | Done |
| Unit tests | 162 passing |

---

## 1. Files added (app target)

| File | Lines | Purpose |
|---|---:|---|
| `SacredPathway/Models/Money.swift` | 215 | Decimal currency type. Half-away-from-zero at cents, full precision in between. |
| `SacredPathway/Models/SettlementModels.swift` | 1,120 | Every new record type + enum. |
| `SacredPathway/Services/SettlementCalculationEngine.swift` | 700 | The only place settlement math happens. |
| `SacredPathway/Services/SettlementValidation.swift` | 560 | Errors block approval, warnings don't. |
| `SacredPathway/Services/DriverAdvanceService.swift` | 250 | Balances, recovery planning, the over-recovery cap. |
| `SacredPathway/Services/RecurringDeductionService.swift` | 230 | Standing rules → draft deduction lines. |
| `SacredPathway/Services/SettlementAuditService.swift` | 350 | Append-only event builders. |
| `SacredPathway/Services/SettlementNumberService.swift` | 130 | `SP-2026-0042` generation + duplicate detection. |

All eight are wired into `SacredPathway.xcodeproj` (PBXBuildFile, PBXFileReference, group, Sources phase). Project file verified: braces/parens balanced, zero undefined object ids.

## 2. Files changed

| File | Change |
|---|---|
| `SacredPathway/Models/Settlement.swift` | **Extended, not replaced.** Every pre-existing field keeps its name, type and coding key. 30 new optional fields added (identity, pay rule, decimal totals, mileage, lifecycle timestamps, provenance). A settlement row written by build 35 still decodes — there is a test for exactly that. |
| `SacredPathway.xcodeproj/project.pbxproj` | 8 file references added. Backup at `/tmp/pbxproj.backup.1789237725` on your Mac. |

`SettlementEngine.swift`, `SettlementGeneratorView`, `ManualPaystubView`, `PaystubExpenseReviewView`, `SettlementHTMLPDFService`, `PaystubPDFService` and `SettlementSheetPDFService` are **untouched**. Nothing existing changed behaviour.

## 3. Files added (test target)

`SacredPathwayTests/` — `SettlementTestFixtures`, `MoneyTests`, `SettlementCalculationEngineTests`, `DriverAdvanceServiceTests`, `RecurringDeductionServiceTests`, `SettlementValidationTests`, `SettlementSupportTests`, `SettlementAcceptanceTests`.

## 4. Database / schema changes

`supabase/migrations/20260912120000_driver_pay_and_settlements.sql` — **written, not applied.**

**New tables (7):** `settlement_loads`, `settlement_additions`, `settlement_deductions`, `recurring_deductions`, `driver_advances`, `driver_advance_repayments`, `settlement_audit_events`.

**Altered (additive columns only):** `settlements` (+27), `drivers` (+6), `documents` (+4).

Additive only — no drops, renames, retypes or backfills. Every statement is `IF NOT EXISTS` / `DROP POLICY IF EXISTS`, so it is safe to re-run.

RLS on all 7 new tables mirrors the existing pattern: `profile_id = auth.uid()`. `settlement_audit_events` deliberately has **SELECT + INSERT policies only** — there is no way to rewrite the trail from a client.

Key relationships:

```
settlements 1─* settlement_loads       (load_id → loads ON DELETE SET NULL)
            1─* settlement_additions
            1─* settlement_deductions  ─* driver_advances
            1─* settlement_audit_events
drivers     1─* recurring_deductions
            1─* driver_advances 1─* driver_advance_repayments
```

### Migration verified against a real PostgreSQL 16

Run locally against a stub of your live schema, with a pre-existing settlement row in place:

| Check | Result |
|---|---|
| Applies cleanly | ✅ |
| Re-running it a second time | ✅ clean, no data change |
| Pre-existing settlement row untouched | ✅ `7250 / 1595 / draft` unchanged |
| RLS enabled on all 7 new tables | ✅ |
| Audit table has only SELECT + INSERT policies | ✅ |
| `recovered_amount > amount` on an advance | ✅ **refused** by CHECK |
| `cash_advance` as a recurring rule | ✅ **refused** by CHECK |
| Split deduction at 150% driver share | ✅ **refused** by CHECK |
| Duplicate settlement number (`sp-` vs `SP-`) | ✅ **refused** by unique index |
| Adjustment line with no `corrects_settlement_id` | ✅ **refused** by CHECK |
| Deleting a load after it was settled | ✅ settlement line survives with frozen `$3,500 / $2,450`; only the link clears |
| `updated_at` trigger | ✅ fires |

## 5. Calculation rules implemented

```
Gross Load Revenue   = Σ load gross rate            (each rounded to cents first)
+ Additions          = Σ credits to the driver
= Settlement Gross

Driver Base Earnings = Σ per-load earnings + Σ per-settlement earnings
+ Additions
− Driver Deductions  = Σ (deduction × driver share)
= Net Driver Pay

Company Expenses     = Σ (deduction × company share), incl. company fees
Company Retained     = Gross Load Revenue − Net Driver Pay − Company Expenses
```

- **Per-load components:** % of gross, flat per load, per mile (loaded / all / deadhead).
- **Per-settlement components:** weekly salary, hourly, manual.
- **Combination pay:** any mix of the above; they simply add.
- **Overrides:** driver-level default, overridable per settlement, overridable per load.
- **Percent-of-net** (your legacy `payOnRevenue: false` rule) is computed once at settlement level, then allocated across loads pro-rata with the rounding residual pushed onto the largest load, so the lines always sum to the total.
- **Company fees** (dispatcher %, factoring %, authority, maintenance reserve) expand into real deduction lines, each independently assignable to driver / company / split. That's how a lease operator carries their own factoring while a company driver doesn't.
- **Metrics:** total / loaded / deadhead miles, revenue per mile, driver earnings per mile, fuel cost per mile, expense ratio.
- **Rounding:** every printed line is rounded to cents, and every total is the sum of the rounded lines. `result.reconciles` asserts this and validation blocks approval if it ever fails.

## 6. Guardrails

Blocking (errors): no driver · reversed period · duplicate settlement number · no pay rule · percentage above the configured cap · negative rate · hourly with no hours · same load twice on one settlement · load already paid on another settlement · adjustment with no stated origin · negative gross (unless flagged as an adjustment) · negative miles · missing description · bad split percentage · duplicate recurring rule · advance recovery above the outstanding balance · totals that don't reconcile · editing a paid/voided settlement.

Warning only: missing driver record (history is preserved) · zero gross · long period · negative addition/deduction · reversed load dates · negative net pay · estimate.

Status machine: `draft → ready_for_review → approved → paid`, with `voided` reachable from any live state. Paid and voided are locked; reopening either requires a stated reason that is written to the audit trail.

## 7. Tests — exact results

Run with Swift 5.10.1 / XCTest:

```
Executed 162 tests, with 0 failures (0 unexpected) in 0.362 seconds
```

| Suite | Tests |
|---|---:|
| MoneyTests | 16 |
| SettlementCalculationEngineTests | 37 |
| DriverAdvanceServiceTests | 19 |
| RecurringDeductionServiceTests | 21 |
| SettlementValidationTests | 32 |
| SettlementNumberServiceTests | 10 |
| SettlementAuditServiceTests | 9 |
| SettlementRecordTests | 9 |
| SettlementAcceptanceTests | 9 |

### The brief's acceptance case

```
Load 1                 $3,500.00
Load 2                 $3,750.00
Gross                  $7,250.00
Driver 70%             $5,075.00
  Fuel                −$1,180.00
  Insurance             −$450.00
  Truck Payment       −$1,300.00
  Cash Advance          −$300.00
  Maintenance           −$250.00
NET                    $1,595.00   ✅ exact
```

Also asserted on that same settlement: the five deduction lines sum to $3,480.00; company retained $5,655.00; 1,400 total miles; $5.18/mi revenue; $0.84/mi fuel; the stored record's legacy `net_pay` Double column reads `1595.0`; validation passes; number assignment yields `SP-2026-0003`; draft → approved → paid transitions are permitted and audited; the settlement then reads as locked.

### Second configuration (additions + partial advance repayment)

```
Gross $6,000 · Driver 65%          $3,900.00
+ Detention                          $200.00
+ Safety bonus                       $150.00
− Fuel (recurring)                  −$900.00
− Insurance (recurring)             −$450.00
− Advance recovery (partial)        −$400.00
NET                                $2,500.00   ✅ exact
Advance balance $1,000 → $600 · next settlement capped at $600
```

Plus a full lease-operator week (72/30 split, split repair line, company-borne factoring) landing on $2,585.00 net.

## 8. Not yet built (Phase B)

Settlements tab and navigation · settlement list / create / review screens · PDF statement (extending `SettlementHTMLPDFService`) · driver portal · driver-detail pay panel · advances UI · recurring-deduction UI · dashboard cards · reports/CSV · local + Supabase repositories and the `Load`/`Expense` → `SettlementLoadLine` adapter.

The engine is deliberately storage-free and UI-free, so Phase B is wiring, not re-math.

## 9. Warnings and unresolved issues

1. **This working copy is 2.1.4 (build 35).** `~/Developer/SacredPathway-stable` is 2.3.3 (build 43) with the same bundle id, 166 Swift files, Maps and a wired test target. You picked this one; flagging it again because Phase B builds on top of whatever this is.
2. **The unit-test target does not exist in this project** and I did not hand-create it — a malformed target would stop the project opening at all. It's a 2-minute Xcode wizard step, written up in `ADD_TEST_TARGET.md`. The test files are already on disk.
3. **I cannot run `xcodebuild`.** Terminal/IDE computer access on macOS is click-only — no typing — so the full iOS build is unverified by me. What I *did* verify: all nine Swift files type-check cleanly under Swift 5.10 against your real `SPDate` from `Expense.swift`, and the 162 tests run green.
4. **UIKit/SwiftUI-dependent compilation is unverified.** None of the new files import UIKit or SwiftUI, so the risk is low, but it is not zero until Xcode builds it.
5. **Name collisions checked** — all 40 new type names were grepped against the existing 119 files. None collide. `SettlementAdjustment` (yours, in `SettlementSheetPDFService`) and `SettlementAddition` (new) are distinct.
6. **The live Supabase `drivers` table already has** `worker_type`, `escrow_*`, `hourly_rate`, `salary_annual`, `mileage_rate`, `per_load_rate`, W-4 and CDL fields, plus PII (`ssn_encrypted`, `dob`, `address`) that this app never reads. Phase B's pay-method UI should bind to the existing rate columns rather than adding more. The PII columns should stay out of the iOS client entirely.
7. **`paystubs` / `paystub_*` / `trucks` / `trailers` tables exist in Supabase and are unused by this codebase.** Something else built them. Worth deciding whether settlements should converge on them before Phase B hardens a second shape.

## 10. Safe to build?

**Likely yes, one manual step first.** Add the test target (below), then build. The eight new files are pure Foundation, type-check clean, and collide with nothing. The project file edit is structurally validated.

## 11. Safe to release?

**No — and not close.** Phase A is the engine only. There is no user-facing settlement feature yet, the migration has not been applied, and no build has run through Xcode. Nothing to submit.

## 12. What to test manually once Phase B lands

Nothing user-facing exists yet. After you add the test target, the one thing worth doing now is **Product → Test in Xcode** and confirming 162 green.
