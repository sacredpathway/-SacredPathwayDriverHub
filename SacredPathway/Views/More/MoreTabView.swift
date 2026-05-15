import SwiftUI

/// Aggregator menu reachable from the bottom-tab "More" entry.
///
/// Holds everything that used to be a top-level tab (IFTA, Brokers, Scan,
/// plus drill-ins for Drivers and Document Vault) so the primary tab bar
/// can stay focused on Home / Loads / Compliance / Paystubs / More.
struct MoreTabView: View {
    @EnvironmentObject var supabase: SupabaseService

    var body: some View {
        NavigationStack {
            ZStack {
                Color.spBackground.ignoresSafeArea()

                List {
                    Section("Operations") {
                        navRow(
                            icon: "fuelpump.fill",
                            title: "IFTA",
                            subtitle: "Track fuel tax miles by jurisdiction"
                        ) {
                            IFTAHubView()
                                .environmentObject(supabase)
                        }

                        navRow(
                            icon: "building.2.fill",
                            title: "Brokers",
                            subtitle: "Manage brokers and broker contacts"
                        ) {
                            BrokersListView()
                                .environmentObject(supabase)
                        }

                        navRow(
                            icon: "person.3.fill",
                            title: "Drivers",
                            subtitle: "Manage drivers, pay rates, assignments"
                        ) {
                            DriversListView()
                                .environmentObject(supabase)
                        }

                        navRow(
                            icon: "archivebox.fill",
                            title: "Document Vault",
                            subtitle: "Browse rate cons, BOLs, receipts"
                        ) {
                            DocumentVaultView()
                                .environmentObject(supabase)
                        }
                    }
                    .listRowBackground(Color.spCardBg)
                    .headerProminence(.increased)

                    Section("Capture") {
                        navRow(
                            icon: "plus.circle.fill",
                            title: "Scan or Upload",
                            subtitle: "Camera, photo library, or Files"
                        ) {
                            ScanUploadView()
                                .environmentObject(supabase)
                        }
                    }
                    .listRowBackground(Color.spCardBg)
                    .headerProminence(.increased)

                    Section("Settings") {
                        navRow(
                            icon: "gearshape.fill",
                            title: "Settings",
                            subtitle: "Company, fees, branding, account"
                        ) {
                            SettingsView()
                                .environmentObject(supabase)
                        }
                    }
                    .listRowBackground(Color.spCardBg)
                    .headerProminence(.increased)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color.spBackground)
            }
            .navigationTitle("More")
        }
    }

    @ViewBuilder
    private func navRow<Destination: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color.spGold)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Color.spTextPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.spTextSecondary)
                }
            }
        }
    }
}

#Preview {
    MoreTabView()
        .environmentObject(SupabaseService())
}
