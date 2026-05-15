import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject var supabase: SupabaseService
    let contact: BrokerContact
    let brokerName: String

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Contact header
                    VStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.spGreenAccent.opacity(0.15)).frame(width: 72, height: 72)
                            Image(systemName: "person.circle.fill").foregroundStyle(Color.spGreenAccent).font(.system(size: 36))
                        }
                        Text(contact.contactName).font(.title3.weight(.bold)).foregroundStyle(Color.spTextPrimary)
                        Text(brokerName).font(.caption).foregroundStyle(Color.spTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Contact info
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle.fill").foregroundStyle(Color.spGold)
                            Text("Contact Info").font(.headline).foregroundStyle(Color.spGold)
                        }

                        if let email = contact.email {
                            infoRow("Email", value: email, icon: "envelope.fill", color: Color(red: 0.2, green: 0.6, blue: 0.9))
                        }

                        if let phone = contact.phone {
                            infoRow("Phone", value: phone, icon: "phone.fill", color: .spGreenAccent)
                        }

                        if let created = contact.createdAt {
                            infoRow("First Contact", value: formatted(created), icon: "calendar", color: .spTextSecondary)
                        }

                        if let lastInteraction = contact.lastInteractionAt {
                            infoRow("Last Interaction", value: formatted(lastInteraction), icon: "clock.fill", color: .spWarning)
                        }

                        if contact.email == nil && contact.phone == nil {
                            Text("No email or phone detected yet. More document scans may reveal contact details.")
                                .font(.caption).foregroundStyle(Color.spTextSecondary)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Broker association
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "building.2.fill").foregroundStyle(Color.spGold)
                            Text("Broker").font(.headline).foregroundStyle(Color.spGold)
                        }
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(Color.spGold.opacity(0.15)).frame(width: 42, height: 42)
                                Image(systemName: "building.2.fill").foregroundStyle(Color.spGold)
                            }
                            Text(brokerName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.spTextPrimary)
                            Spacer()
                        }
                    }
                    .padding()
                    .background(Color.spCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
        }
        .navigationTitle("Contact")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(Color.spTextSecondary)
                Text(value).font(.subheadline).foregroundStyle(Color.spTextPrimary)
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
