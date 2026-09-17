import Foundation

/// Central feature matrix for Driver Hub subscriptions.
///
/// The hierarchy is strict and inherited:
/// Driver < Owner Operator < Carrier.
/// Product IDs are still owned by `Config.IAP`; this manager owns what each
/// product and feature means after StoreKit returns an active entitlement.
enum FeatureAccessManager {
    enum Feature: String, CaseIterable, Identifiable {
        case loadTracking
        case rateConUploads
        case documentStorage
        case settlementTracking
        case expenseTracking
        case fuelTracking
        case weeklyStatistics
        case monthlyStatistics
        case loadHistory
        case basicReports
        case dispatcherMessaging
        case dispatchRequests
        case assignedLoadManagement

        case cpaTaxPackage
        case taxReports
        case mileageReports
        case profitLossReports
        case businessAnalytics
        case revenueAnalytics
        case financialReporting
        case advancedReports

        case carrierDashboard
        case driverManagement
        case dispatcherManagement
        case fleetDashboard
        case fleetAnalytics
        case teamMessaging
        case multiTruckOperations
        case multiDriverOperations
        case companyManagement
        case fleetReporting
        case teamOperations
        case driverRequests
        case driverApprovals

        // Existing code-facing feature names kept as aliases so old call sites
        // compile while the centralized matrix defines their real tier.
        case aiScan
        case pdfExport
        case brokerIntelligence
        case smartInsights
        case multiDriver
        case whiteLabelBranding
        case driverScorecard
        case iftaAutoTracking
        case manualPaystub
        case basicDashboard

        var id: String { rawValue }
    }

    static func tier(for productID: String) -> SubscriptionTier {
        switch productID {
        case Config.IAP.driverHubProMonthly:
            return .driver
        case Config.IAP.proMonthly, Config.IAP.proAnnual:
            return .ownerOperator
        case Config.IAP.carrierMonthly, Config.IAP.carrierAnnual:
            return .carrier
        default:
            return .free
        }
    }

    static func hasAccess(currentTier: SubscriptionTier, to requiredTier: SubscriptionTier) -> Bool {
        currentTier >= requiredTier
    }

    static func hasAccess(currentTier: SubscriptionTier, to feature: Feature) -> Bool {
        hasAccess(currentTier: currentTier, to: requiredTier(for: feature))
    }

    static func requiredTier(for feature: Feature) -> SubscriptionTier {
        switch feature {
        case .loadTracking,
             .rateConUploads,
             .documentStorage,
             .settlementTracking,
             .expenseTracking,
             .fuelTracking,
             .weeklyStatistics,
             .monthlyStatistics,
             .loadHistory,
             .basicReports,
             .dispatcherMessaging,
             .dispatchRequests,
             .assignedLoadManagement,
             .aiScan,
             .pdfExport,
             .manualPaystub,
             .basicDashboard:
            return .driver

        case .cpaTaxPackage,
             .taxReports,
             .mileageReports,
             .profitLossReports,
             .businessAnalytics,
             .revenueAnalytics,
             .financialReporting,
             .advancedReports,
             .brokerIntelligence,
             .smartInsights,
             .iftaAutoTracking:
            return .ownerOperator

        case .carrierDashboard,
             .driverManagement,
             .dispatcherManagement,
             .fleetDashboard,
             .fleetAnalytics,
             .teamMessaging,
             .multiTruckOperations,
             .multiDriverOperations,
             .companyManagement,
             .fleetReporting,
             .teamOperations,
             .driverRequests,
             .driverApprovals,
             .multiDriver,
             .whiteLabelBranding,
             .driverScorecard:
            return .carrier
        }
    }
}
