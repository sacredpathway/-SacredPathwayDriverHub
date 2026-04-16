import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var supabase: SupabaseService

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 0) {
                    // Sacred Pathway Logo Header
                    VStack(spacing: 12) {
                        Image(systemName: "truck.box.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.spGold)
                        Text("Sacred Pathway")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.spGold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(Color.spCardBg)

                    List {
                        Section("Company") {
                            NavigationLink {
                                EditCompanyView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "building.2.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(supabase.currentProfile?.companyName ?? "Not set")
                                            .foregroundStyle(Color.spTextPrimary)
                                        HStack(spacing: 8) {
                                            Text("MC# \(supabase.currentProfile?.mcNumber ?? "—")")
                                            Text("DOT# \(supabase.currentProfile?.dotNumber ?? "—")")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        Section("Financial") {
                            NavigationLink {
                                ExpensesListView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "receipt")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Expenses")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Track fuel, lumper, toll, repair costs")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        Section("Fees & Deductions") {
                            NavigationLink {
                                FeeSettingsView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "percent")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Fee Percentages")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Driver pay, dispatcher, factoring, reserves")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        Section("Branding") {
                            NavigationLink {
                                BrandingSettingsView()
                            } label: {
                                HStack {
                                    Image(systemName: "paintpalette.fill")
                                        .foregroundStyle(Color.spGold)
                                    Text("Logo & Color Scheme")
                                        .foregroundStyle(Color.spTextPrimary)
                                    Spacer()
                                    if BrandingService.shared.hasCustomBranding {
                                        Text("Custom")
                                            .font(.caption)
                                            .foregroundStyle(Color.spSuccess)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        Section("Operations") {
                            NavigationLink {
                                DriversListView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "person.3.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Drivers")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Manage drivers, pay rates, assignments")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                SettlementGeneratorView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Settlements & Paystubs")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Auto-calculate from your loads & expenses")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                ManualPaystubView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Create Paystub Manually")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Type in loads, expenses, fees — export PDF")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                PaystubDraftsListView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "tray.full.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Payroll Drafts")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("Resume unfinished paystubs")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                DocumentVaultView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "archivebox.fill")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Document Vault")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("All scanned docs, searchable by load or broker")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }

                            NavigationLink {
                                SmartInsightsView()
                                    .environmentObject(supabase)
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(Color.spGold)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Smart Insights")
                                            .foregroundStyle(Color.spTextPrimary)
                                        Text("AI-powered summaries, alerts, rate intelligence")
                                            .font(.caption)
                                            .foregroundStyle(Color.spTextSecondary)
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        Section("Subscription") {
                            LabeledContent("Plan", value: (supabase.currentProfile?.subscriptionTier ?? "free").capitalized)
                                .foregroundStyle(Color.spTextPrimary)
                        }
                        .listRowBackground(Color.spCardBg)
                        .headerProminence(.increased)

                        Section {
                            Button("Sign Out", role: .destructive) {
                                Task { try? await supabase.signOut() }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .listRowBackground(Color.spCardBg)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(Color.spBackground)
                }
                .navigationTitle("Settings")
                .toolbarColorScheme(.dark, for: .navigationBar)
            }
        }
    }
}

#Preview {
    SettingsView().environmentObject(SupabaseService())
}
