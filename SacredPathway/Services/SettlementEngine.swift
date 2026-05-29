import Foundation

struct SettlementCalculation {
    let totalRevenue: Double
    let totalExpenses: Double
    let grossProfit: Double
    let driverPayPercentage: Double
    let driverPayAmount: Double
    let dispatcherFeePercentage: Double
    let dispatcherFeeAmount: Double
    let factoringFeePercentage: Double
    let factoringFeeAmount: Double
    let authorityFee: Double
    let maintenanceReserve: Double
    let customDeductions: [SettlementCustomDeduction]
    let carrierNetPay: Double

    var customDeductionsTotal: Double {
        customDeductions.reduce(0) { $0 + $1.amount }
    }

    var standardDeductionsTotal: Double {
        totalExpenses
            + dispatcherFeeAmount
            + factoringFeeAmount
            + authorityFee
            + maintenanceReserve
    }

    var totalDeductions: Double {
        standardDeductionsTotal + customDeductionsTotal
    }
}

class SettlementEngine {

    /// Calculate a complete settlement
    static func calculate(
        loads: [Load],
        expenses: [Expense],
        profile: Profile,
        driver: Driver,
        payOnRevenue: Bool = false,
        customDeductions: [SettlementCustomDeduction] = []
    ) -> SettlementCalculation {

        // Step 1: Total revenue from all loads
        let totalRevenue = loads.reduce(0.0) { sum, load in
            sum + (load.totalRevenue ?? 0)
        }

        // Step 2: Total expenses
        let totalExpenses = expenses.reduce(0.0) { sum, expense in
            sum + expense.amount
        }

        // Step 3: Gross profit
        let grossProfit = totalRevenue - totalExpenses

        // Step 4: Driver pay — either a flat per-settlement amount or a percentage
        let driverPct: Double
        let driverPayAmount: Double
        if driver.isFlatRate, let flat = driver.flatRate {
            // Flat-rate drivers get the same amount every settlement, regardless of revenue
            driverPct = 0
            driverPayAmount = flat
        } else {
            driverPct = driver.payPercentage ?? profile.driverPayPercentage ?? 25.0
            let driverPayBase = payOnRevenue ? totalRevenue : grossProfit
            driverPayAmount = driverPayBase * (driverPct / 100.0)
        }

        // Step 5: Dispatcher fee (always on revenue)
        let dispatcherPct = profile.dispatcherFeePercentage ?? 0.0
        let dispatcherFeeAmount = totalRevenue * (dispatcherPct / 100.0)

        // Step 6: Factoring fee (always on revenue)
        let factoringPct = profile.factoringFeePercentage ?? 0.0
        let factoringFeeAmount = totalRevenue * (factoringPct / 100.0)

        // Step 7: Flat fees
        let authorityFee = profile.authorityFee ?? 0.0
        let maintenanceReserve = profile.maintenanceReserve ?? 0.0
        let customDeductionsTotal = customDeductions.reduce(0) { $0 + $1.amount }

        // Step 8: Carrier net pay (what the company keeps)
        let carrierNetPay = grossProfit
            - driverPayAmount
            - dispatcherFeeAmount
            - factoringFeeAmount
            - authorityFee
            - maintenanceReserve
            - customDeductionsTotal

        return SettlementCalculation(
            totalRevenue: totalRevenue,
            totalExpenses: totalExpenses,
            grossProfit: grossProfit,
            driverPayPercentage: driverPct,
            driverPayAmount: driverPayAmount,
            dispatcherFeePercentage: dispatcherPct,
            dispatcherFeeAmount: dispatcherFeeAmount,
            factoringFeePercentage: factoringPct,
            factoringFeeAmount: factoringFeeAmount,
            authorityFee: authorityFee,
            maintenanceReserve: maintenanceReserve,
            customDeductions: customDeductions,
            carrierNetPay: carrierNetPay
        )
    }
}
