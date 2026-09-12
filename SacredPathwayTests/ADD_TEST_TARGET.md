# Add the unit-test target (one time, ~2 minutes)

The 8 test files are already on disk in `SacredPathwayTests/`. This project has
no unit-test target yet, and hand-editing `project.pbxproj` to create a whole
new target risks making the project unopenable — so Xcode should create it.

1. Open `SacredPathway.xcodeproj`.
2. **File → New → Target…**
3. iOS → Test → **Unit Testing Bundle** → Next.
4. Product Name: `SacredPathwayTests` · Target to be Tested: `SacredPathway` → Finish.
5. Xcode creates a `SacredPathwayTests` group with a placeholder
   `SacredPathwayTests.swift` — **delete that placeholder** (Move to Trash).
6. Right-click the `SacredPathwayTests` group → **Add Files to "SacredPathway"…**
   and select all 8 files in the `SacredPathwayTests` folder:
   - `SettlementTestFixtures.swift`
   - `MoneyTests.swift`
   - `SettlementCalculationEngineTests.swift`
   - `DriverAdvanceServiceTests.swift`
   - `RecurringDeductionServiceTests.swift`
   - `SettlementValidationTests.swift`
   - `SettlementSupportTests.swift`
   - `SettlementAcceptanceTests.swift`

   In the dialog, tick **only** the `SacredPathwayTests` target checkbox
   (not the app target), then Add.
7. **Product → Test** (⌘U).

Expected: **162 tests, 0 failures.**

The files carry

```swift
#if canImport(SettlementKit)
@testable import SettlementKit
#else
@testable import SacredPathway
#endif
```

so the same sources run both in Xcode against the app target and in the
standalone harness used to verify them.
