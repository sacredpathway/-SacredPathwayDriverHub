# Adding the Unit-Test Target (one-time, ~3 minutes in Xcode)

The 4 test files in this folder are written and ready, but the project has no
test target yet — Xcode must create it (this is safer than hand-editing the
project file for a whole new target).

## Steps

1. Open `SacredPathway.xcodeproj` in Xcode.
2. Menu **File → New → Target…**
3. Pick **Unit Testing Bundle** (under iOS → Test). Click **Next**.
4. Set exactly:
   - Product Name: `SacredPathwayTests`
   - Team: (your team)
   - Target to be Tested: `SacredPathway`
5. Click **Finish**. Xcode creates a `SacredPathwayTests` group with a
   placeholder `SacredPathwayTests.swift` — **delete that placeholder file**
   (Move to Trash).
6. In Finder, this folder (`SacredPathway/SacredPathwayTests/`) already
   contains the real tests. In Xcode's left sidebar, right-click the
   `SacredPathwayTests` group → **Add Files to "SacredPathway"…** → select
   these 4 files:
   - `TestFixtures.swift`
   - `SettlementEngineTests.swift`
   - `CustomFeeAndMatcherTests.swift`
   - `WeeklyStatsAndIFTATests.swift`
   - `ReceiptPersistenceTests.swift`
   - `LocalStoreQuarantineTests.swift`
   In the add dialog: **check the `SacredPathwayTests` target checkbox only**
   (NOT the app target), then Add.
7. Run the tests: **⌘U** (or Product → Test).

## What the suite covers (42 tests)

| Area | Guarantees |
|---|---|
| SettlementEngine (7) | driver % on net vs revenue; flat-rate; % fallback chain (driver→profile→25); custom deductions in net; zero-revenue sanity; nil-revenue loads |
| CustomFeeService (5) | %-of-gross math; flat fees; zero/negative skipped; sortOrder; canonical 5000→350 regression |
| PaystubExpenseMatcher (6) | load-attached always included; unselected-load skipped; end-of-day window edge; undated-unattached dropped+counted; override amounts; category synonyms |
| WeeklyStatsService (6) | dedupe newest-wins; pickup→delivery→created fallback; nil-pickup counts via fallback; load-aware `contains` matches revenue; 30-day half-open window; all-time includes undated |
| IFTA (5+) | quarter last-day boundary fix; quarter-from-date; fleet-MPG taxable gallons; out-of-quarter exclusion; rate-overlay end-to-end ($0.20 TX → $24); malformed matrix rejected |
| Receipt persistence (11) | save→resolve→load round-trip; relaunch-style resolution; 1800px downscale; empty-data throws; missing-file nil; idempotent delete; orphan sweep; path-traversal guard; Expense codable + key-absent-when-nil; backup payload v2 + v1 manifest decode; restore preferred-filename byte-exact |
| LocalStore quarantine (5) | corrupt file → preserved `.corrupt-*` copy + empty result + reusable slot; wrong-shape JSON quarantines; healthy round-trip untouched; missing file ≠ corruption; loadObject path guarded |
| Performance (1) | 5k-load dedupe/bucket/sum `measure` baseline |

## If a test fails

That's the suite doing its job — a failing money test means a behavior change
in paystub/IFTA/weekly math. Fix the code or consciously update the expected
value **and** the comment explaining the business rule.
