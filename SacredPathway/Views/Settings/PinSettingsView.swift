import SwiftUI

/// Settings screen to enable/change/disable the app-lock PIN.
struct PinSettingsView: View {
    @StateObject private var pinService = PinLockService.shared

    @State private var newPin: String = ""
    @State private var confirmPin: String = ""
    @State private var currentPin: String = ""
    @State private var isEditing: Bool = false
    @State private var message: String?
    @State private var messageColor: Color = .spSuccess

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    headerCard

                    if pinService.isEnabled && !isEditing {
                        // Currently enabled, showing status + change/disable controls
                        statusCard

                        Button {
                            isEditing = true
                            currentPin = ""
                            newPin = ""
                            confirmPin = ""
                            message = nil
                        } label: {
                            actionRow(title: "Change PIN", icon: "pencil", color: Color.spGold)
                        }

                        Button(role: .destructive) {
                            disablePin()
                        } label: {
                            actionRow(title: "Remove PIN", icon: "lock.open.fill", color: Color.spDanger)
                        }
                    } else {
                        // Entering / changing PIN
                        if pinService.isEnabled {
                            pinField("Current PIN", text: $currentPin)
                        }
                        pinField("New PIN (4–6 digits)", text: $newPin)
                        pinField("Confirm PIN", text: $confirmPin)

                        Button {
                            savePin()
                        } label: {
                            Text(pinService.isEnabled ? "Save New PIN" : "Enable PIN Lock")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.spGold)
                                .foregroundStyle(Color.spBlack)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        if pinService.isEnabled {
                            Button("Cancel") {
                                isEditing = false
                                newPin = ""
                                confirmPin = ""
                                currentPin = ""
                            }
                            .foregroundStyle(Color.spTextSecondary)
                        }
                    }

                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(messageColor)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("App Lock / PIN")
    }

    // MARK: - Subviews

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.spGold).font(.title2)
                Text("App Lock")
                    .font(.headline).foregroundStyle(Color.spTextPrimary)
                Spacer()
            }
            Text("Require a 4–6 digit PIN every time the app launches or returns from the background. Keeps financial data private on a shared phone.")
                .font(.caption)
                .foregroundStyle(Color.spTextSecondary)
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.spSuccess)
                Text("PIN is enabled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.spTextPrimary)
                Spacer()
            }

            Toggle(isOn: Binding(
                get: { pinService.biometricsEnabled },
                set: { pinService.setBiometricsEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Face ID / Touch ID")
                        .foregroundStyle(Color.spTextPrimary)
                    Text("Skip the PIN when biometrics succeed")
                        .font(.caption).foregroundStyle(Color.spTextSecondary)
                }
            }
            .tint(Color.spGold)
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func pinField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.spTextSecondary)
            SecureField("••••", text: text)
                .keyboardType(.numberPad)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding()
                .background(Color.spCardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Color.spTextPrimary)
                .onChange(of: text.wrappedValue) { _, new in
                    // Digits only, max 6
                    let filtered = new.filter { $0.isNumber }
                    text.wrappedValue = String(filtered.prefix(6))
                }
        }
    }

    private func actionRow(title: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).foregroundStyle(color)
            Spacer()
        }
        .padding()
        .background(Color.spCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func savePin() {
        message = nil

        guard newPin.count >= 4 && newPin.count <= 6 else {
            fail("PIN must be 4–6 digits.")
            return
        }
        guard newPin == confirmPin else {
            fail("PINs don't match.")
            return
        }

        // If changing, verify the current PIN first
        if pinService.isEnabled {
            guard pinService.verify(currentPin) else {
                fail("Current PIN is incorrect.")
                return
            }
        }

        if pinService.setPin(newPin) {
            succeed(pinService.isEnabled && !isEditing ? "PIN enabled." : "PIN updated.")
            isEditing = false
            newPin = ""
            confirmPin = ""
            currentPin = ""
        } else {
            fail("Could not save PIN. Try again.")
        }
    }

    private func disablePin() {
        _ = pinService.setPin(nil)
        succeed("PIN removed. App will no longer lock.")
    }

    private func succeed(_ text: String) {
        messageColor = .spSuccess
        message = text
    }

    private func fail(_ text: String) {
        messageColor = .spDanger
        message = text
    }
}
