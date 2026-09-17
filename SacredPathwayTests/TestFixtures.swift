import Foundation
@testable import SacredPathway

// Shared factories so every test builds models the same way. Only the fields
// a test cares about are surfaced; everything else gets a stable default.
@MainActor
enum Fixtures {

    static let profileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    static func profile(
        driverPayPct: Double? = nil,
        dispatcherPct: Double? = nil,
        factoringPct: Double? = nil,
        authorityFee: Double? = nil,
        maintenanceReserve: Double? = nil
    ) -> Profile {
        Profile(
            id: profileID,
            accountRole: .ownerOperator,
            companyName: "Test Trucking LLC",
            mcNumber: nil,
            dotNumber: nil,
            phone: nil,
            truckNumber: nil,
            trailerNumber: nil,
            subscriptionTier: nil,
            subscriptionStatus: nil,
            driverPayPercentage: driverPayPct,
            dispatcherFeePercentage: dispatcherPct,
            factoringFeePercentage: factoringPct,
            authorityFee: authorityFee,
            maintenanceReserve: maintenanceReserve,
            payBasis: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    static func driver(
        payPercentage: Double? = nil,
        payType: String? = nil,
        flatRate: Double? = nil
    ) -> Driver {
        Driver(
            id: UUID(),
            profileId: profileID,
            name: "Test Driver",
            truckNumber: nil,
            payPercentage: payPercentage,
            payType: payType,
            flatRate: flatRate,
            phone: nil,
            email: nil,
            active: true,
            createdAt: nil
        )
    }

    static func load(
        id: UUID? = UUID(),
        revenue: Double?,
        pickupDate: Date? = nil,
        deliveryDate: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        loadNumber: String? = nil
    ) -> Load {
        Load(
            id: id,
            profileId: profileID,
            loadNumber: loadNumber,
            pickupDate: pickupDate,
            deliveryDate: deliveryDate,
            totalRevenue: revenue,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func expense(
        id: UUID? = UUID(),
        loadId: UUID? = nil,
        category: String = "fuel",
        amount: Double,
        vendorName: String? = nil,
        receiptDate: Date? = nil,
        createdAt: Date? = nil
    ) -> Expense {
        Expense(
            id: id,
            loadId: loadId,
            profileId: profileID,
            category: category,
            amount: amount,
            vendorName: vendorName,
            receiptDate: receiptDate,
            createdAt: createdAt
        )
    }

    /// Deterministic date builder (local calendar) — keeps window tests
    /// readable: `Fixtures.date(2026, 3, 31, hour: 14)`.
    static func date(_ year: Int, _ month: Int, _ day: Int,
                     hour: Int = 12, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }
}
