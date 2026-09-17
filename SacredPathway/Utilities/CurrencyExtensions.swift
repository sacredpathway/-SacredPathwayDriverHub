import Foundation

extension Double {
    /// Formats a number as currency: 1234.5 → "$1,234.50"
    var asCurrency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: self)) ?? "$0.00"
    }

    /// Formats a number as percentage: 25.0 → "25%"
    var asPercent: String {
        return String(format: "%.0f%%", self)
    }
}
