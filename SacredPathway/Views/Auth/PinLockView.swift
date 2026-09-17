import SwiftUI

/// Full-screen lock that appears when the app launches (or returns to foreground)
/// while a PIN is set. The user can also opt into Face ID / Touch ID.
struct PinLockView: View {
    @StateObject private var pinService = PinLockService.shared
    @State private var entered: String = ""
    @State private var shake: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.spBackground.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.spGold)

                Text("Enter PIN")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.spTextPrimary)

                // Dot indicator for entered digits
                HStack(spacing: 14) {
                    ForEach(0..<max(4, entered.count), id: \.self) { idx in
                        Circle()
                            .fill(idx < entered.count ? Color.spGold : Color.spTextSecondary.opacity(0.3))
                            .frame(width: 14, height: 14)
                    }
                }
                .offset(x: shake ? -10 : 0)
                .animation(.default, value: shake)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.spDanger)
                }

                keypad

                if pinService.biometricsEnabled {
                    Button {
                        tryBiometrics()
                    } label: {
                        Label("Unlock with Face ID", systemImage: "faceid")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.spGold)
                    }
                    .padding(.top, 6)
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            // Auto-attempt biometrics on first load
            if pinService.biometricsEnabled {
                tryBiometrics()
            }
        }
    }

    // MARK: - Keypad

    private var keypad: some View {
        VStack(spacing: 14) {
            ForEach([["1","2","3"], ["4","5","6"], ["7","8","9"], ["", "0", "<"]], id: \.self) { row in
                HStack(spacing: 14) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
        .padding(.horizontal, 40)
    }

    private func keyButton(_ key: String) -> some View {
        Button {
            handleKey(key)
        } label: {
            Text(key == "<" ? "⌫" : key)
                .font(.title2.weight(.semibold))
                .frame(width: 66, height: 66)
                .foregroundStyle(Color.spTextPrimary)
                .background(key.isEmpty ? Color.clear : Color.spCardBg)
                .clipShape(Circle())
        }
        .disabled(key.isEmpty)
        .opacity(key.isEmpty ? 0 : 1)
    }

    private func handleKey(_ key: String) {
        errorMessage = nil
        if key == "<" {
            if !entered.isEmpty { entered.removeLast() }
            return
        }
        guard entered.count < 6 else { return }
        entered.append(key)
        if entered.count >= 4 {
            checkPin()
        }
    }

    private func checkPin() {
        if PinLockService.shared.verify(entered) {
            PinLockService.shared.isUnlocked = true
        } else {
            shake.toggle()
            errorMessage = "Wrong PIN — try again"
            entered = ""
        }
    }

    private func tryBiometrics() {
        pinService.authenticateWithBiometrics { success in
            if success {
                PinLockService.shared.isUnlocked = true
            }
        }
    }
}

#Preview {
    PinLockView()
}
