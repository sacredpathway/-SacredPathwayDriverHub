import SwiftUI

/// Settings screen letting the user pick the day their pay week starts.
/// Every weekly total in the app — Dashboard, Loads list, Smart Insights —
/// is bucketed by `PayWeekService.shared.weekInterval(...)`, so changes
/// here propagate immediately to all weekly totals.
struct PayWeekSettingsView: View {
    @ObservedObject private var payWeek = PayWeekService.shared

    /// 1 = Sunday ... 7 = Saturday. UI is a single Picker for compactness.
    private let weekdays = Array(1...7)

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()
            List {
                Section {
                    Picker("Pay Week Starts", selection: $payWeek.firstWeekday) {
                        ForEach(weekdays, id: \.self) { day in
                            Text(PayWeekService.dayName(for: day)).tag(day)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.spGold)
                    .foregroundStyle(Color.spTextPrimary)
                } header: {
                    Text("Pay Week Starts")
                } footer: {
                    Text("Pay week runs \(payWeek.displayName) → \(payWeek.endDayDisplayName). Every weekly total in the app — Dashboard, Loads, Insights — uses this start day.")
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
                .listRowBackground(Color.spCardBg)
                .headerProminence(.increased)

                Section("Current Pay Week") {
                    let interval = payWeek.weekInterval()
                    HStack {
                        Text("Start")
                            .foregroundStyle(Color.spTextSecondary)
                        Spacer()
                        Text(interval.start, style: .date)
                            .foregroundStyle(Color.spTextPrimary)
                    }
                    HStack {
                        Text("End")
                            .foregroundStyle(Color.spTextSecondary)
                        Spacer()
                        // `interval.end` is exclusive (next-period start).
                        // Show end-of-week as one second earlier.
                        Text(interval.end.addingTimeInterval(-1), style: .date)
                            .foregroundStyle(Color.spTextPrimary)
                    }
                }
                .listRowBackground(Color.spCardBg)
                .headerProminence(.increased)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Pay Week")
    }
}

#Preview {
    NavigationStack { PayWeekSettingsView() }
}
