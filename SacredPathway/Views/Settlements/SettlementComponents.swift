import SwiftUI

// =============================================================================
//  SettlementComponents — shared building blocks for the Settlements screens
// -----------------------------------------------------------------------------
//  Added 2026-09-16 (Phase B). Uses the existing Sacred Pathway palette
//  (BrandColors.swift). Money is always displayed from `Money`, never Double.
// =============================================================================

// MARK: - Status badge

struct SettlementStatusBadge: View {
    let status: SettlementStatus
    var isEstimate: Bool = false

    var body: some View {
        Label(isEstimate ? "Estimated" : status.displayName,
              systemImage: isEstimate ? "hourglass" : status.systemImage)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
            .accessibilityLabel("Status \(isEstimate ? "Estimated" : status.displayName)")
    }

    private var tint: Color {
        if isEstimate { return .spWarning }
        switch status {
        case .draft:          return .spTextSecondary
        case .readyForReview: return .spWarning
        case .approved:       return .spGold
        case .paid:           return .spSuccess
        case .voided:         return .spDanger
        }
    }
}

// MARK: - Money text

/// Right-aligned, monospaced currency. Credits green with "+", debits red
/// with "−", totals neutral.
struct SettlementMoneyText: View {
    enum Style { case plain, credit, debit }

    let amount: Money
    var style: Style = .plain
    var font: Font = .system(.subheadline, design: .monospaced).weight(.semibold)

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var text: String {
        switch style {
        case .plain:  return amount.formatted
        case .credit: return amount.formattedSigned(asCredit: true)
        case .debit:  return amount.formattedSigned(asCredit: false)
        }
    }

    private var color: Color {
        switch style {
        case .plain:  return amount.isNegative ? .spDanger : .spTextPrimary
        case .credit: return amount.isZero ? .spTextSecondary : .spSuccess
        case .debit:  return amount.isZero ? .spTextSecondary : .spDanger
        }
    }
}

// MARK: - Rows & cards

struct SettlementAmountRow: View {
    let title: String
    var subtitle: String? = nil
    let amount: Money
    var style: SettlementMoneyText.Style = .plain

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Color.spTextPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            SettlementMoneyText(amount: amount, style: style)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettlementCard<Content: View>: View {
    var title: String? = nil
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title.uppercased())
                        .font(.caption.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.spTextSecondary)
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.spTextSecondary)
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// The big number. Used on the review screen, the estimate card and the
/// driver portal.
struct SettlementNetPayHero: View {
    let amount: Money
    var isEstimate: Bool = false
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isEstimate ? "ESTIMATED NET PAY" : "NET PAY")
                .font(.caption.weight(.heavy))
                .tracking(1.6)
                .foregroundStyle(Color.spGoldLight)
            Text(amount.formatted)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(amount.isNegative ? Color.spDanger : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spBlack)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.spGold).frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct SettlementMetricTile: View {
    let title: String
    let value: String
    var icon: String = "chart.bar.fill"
    var tint: Color = .spGold
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.spTextSecondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(.headline, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.spTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct SettlementEstimateTag: View {
    var body: some View {
        Text("ESTIMATED")
            .font(.caption2.weight(.heavy))
            .tracking(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.spWarning.opacity(0.18))
            .foregroundStyle(Color.spWarning)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Validation list

struct SettlementIssuesView: View {
    let issues: [SettlementValidationIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: issue.severity == .error
                              ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? Color.spDanger : Color.spWarning)
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(Color.spTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((issues.contains { $0.severity == .error } ? Color.spDanger : Color.spWarning).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Inputs

/// Currency entry that only ever produces a `Money`.
struct SettlementMoneyField: View {
    let title: String
    @Binding var amount: Money
    /// The decimal pad has no minus key; fields that accept a negative
    /// amount (chargebacks) use the punctuation keyboard instead.
    var allowsNegative: Bool = false
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            TextField(allowsNegative ? "±$0.00" : "$0.00", text: $text)
                .keyboardType(allowsNegative ? .numbersAndPunctuation : .decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .frame(maxWidth: 160)
                .onChange(of: text) { _, newValue in
                    if let parsed = Money(input: newValue) { amount = parsed }
                    else if newValue.isEmpty { amount = .zero }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { text = amount.isZero ? "" : plain(amount) }
                }
        }
        .onAppear { text = amount.isZero ? "" : plain(amount) }
        .onChange(of: amount) { _, newAmount in
            // Keep the text in step when the value is set from outside
            // (e.g. an editor loading an existing line).
            if !focused { text = newAmount.isZero ? "" : plain(newAmount) }
        }
    }

    private func plain(_ m: Money) -> String {
        NSDecimalNumber(decimal: m.amount).stringValue
    }
}

/// Decimal entry (percent, rate per mile, hours, miles).
struct SettlementDecimalField: View {
    let title: String
    @Binding var value: Decimal
    var suffix: String = ""
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Color.spTextPrimary)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 120)
                .focused($focused)
                .onChange(of: text) { _, newValue in
                    if let d = Decimal(userInput: newValue) { value = d }
                    else if newValue.isEmpty { value = 0 }
                }
            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(Color.spTextSecondary)
            }
        }
        .onAppear { text = value == 0 ? "" : NSDecimalNumber(decimal: value).stringValue }
        .onChange(of: value) { _, newValue in
            if !focused { text = newValue == 0 ? "" : NSDecimalNumber(decimal: newValue).stringValue }
        }
    }
}

// MARK: - Empty state

struct SettlementEmptyState: View {
    let title: String
    let message: String
    var systemImage: String = "doc.text.magnifyingglass"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Color.spTextSecondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.spTextPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.spTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Formatting helpers

enum SettlementFormat {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func date(_ d: Date?) -> String {
        d.map { mediumDate.string(from: $0) } ?? "—"
    }

    static func miles(_ m: Decimal) -> String {
        "\(SettlementInsights.milesString(m)) mi"
    }

    static func perMile(_ m: Money) -> String {
        m.isZero ? "—" : "\(m.rounded.formatted)/mi"
    }

    static func percent(_ d: Decimal) -> String {
        "\(Money.round(d * 100, scale: 1))%"
    }
}

/// Wraps an error message for `.alert(item:)`.
struct SettlementAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(_ title: String, _ message: String) {
        self.title = title
        self.message = message
    }

    init(error: Error) {
        self.title = "Couldn't Complete"
        self.message = error.localizedDescription
    }
}
