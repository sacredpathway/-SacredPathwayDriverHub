# Unit-test target

**Status (2026-09-16): the `SacredPathwayTests` unit-test target is now defined
in `SacredPathway.xcodeproj` and included in the shared `SacredPathway` scheme.**
You no longer need to create it by hand.

Run the tests with **Product → Test (⌘U)**, or from Terminal:

```bash
cd ~/Developer/SacredPathwayDriverHub
xcodebuild test \
  -project SacredPathway.xcodeproj \
  -scheme SacredPathway \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SacredPathwayTests
```

The target builds these files from this folder:

| File | What it covers |
|---|---|
| `SettlementTestFixtures.swift` | isolated, obviously-fake test data |
| `MoneyTests.swift` | decimal money, rounding |
| `SettlementCalculationEngineTests.swift` | pay methods, deductions, fees, metrics |
| `DriverAdvanceServiceTests.swift` | advance balances and recovery caps |
| `RecurringDeductionServiceTests.swift` | recurring rules |
| `SettlementValidationTests.swift` | approval guardrails |
| `SettlementSupportTests.swift` | numbering, audit, record decoding |
| `SettlementAcceptanceTests.swift` | Phase A acceptance ($1,595.00) |
| `SettlementWorkflowTests.swift` | draft / approve / pay / void / reopen, duplicate-load and advance rules |
| `SettlementPhaseBAcceptanceTests.swift` | engine = database = statement = HTML ($1,595.00 and $2,500.00) |
| `SettlementPermissionsTests.swift` | driver authorization, cross-driver privacy |
| `SettlementInsightsTests.swift` | history search, YTD, dashboard, reports, CSV, estimate separation |
| `SettlementStorageAndStatementTests.swift` | local store safety, Supabase row shape, statement |
| `SettlementPDFRenderingTests.swift` | real PDF render on iOS (skipped off-device) |

The same sources also run on Linux in a Foundation-only harness
(`Tools/settlements-harness`), which is how they were verified in the
build session. The files use

```swift
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif
```

so one set of tests serves both.

If the target ever needs to be removed, every object it added in
`project.pbxproj` has an id starting with `5E78000000000000000004` or
`5E78000000000000000005`.
