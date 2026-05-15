import Foundation
import Security
import LocalAuthentication
import SwiftUI

/// Stores a 4–6 digit app lock PIN securely in the iOS Keychain.
///
/// The PIN is hashed with SHA-256 before storage, so even a device restore can't
/// recover the original digits. A separate "enabled" flag lives in UserDefaults
/// so we can cheaply answer `isEnabled` on app launch without a keychain hit.
final class PinLockService: ObservableObject {
    static let shared = PinLockService()

    private let keychainService = "com.sacredpathway.driverhub.pinlock"
    private let keychainAccount = "app_lock_pin_hash"
    private let enabledFlagKey = "pinLockEnabled"
    private let biometricsFlagKey = "pinLockBiometricsEnabled"

    // Global unlocked state — flipped true after a successful unlock and false
    // when the app goes to background (handled in the app root).
    @Published var isUnlocked: Bool = false

    private init() {}

    // MARK: - Public API

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledFlagKey)
    }

    var biometricsEnabled: Bool {
        UserDefaults.standard.bool(forKey: biometricsFlagKey)
    }

    func setBiometricsEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: biometricsFlagKey)
    }

    /// Set or change the PIN. Pass nil to remove the PIN entirely.
    @discardableResult
    func setPin(_ pin: String?) -> Bool {
        guard let pin, !pin.isEmpty else {
            deleteHash()
            UserDefaults.standard.set(false, forKey: enabledFlagKey)
            UserDefaults.standard.set(false, forKey: biometricsFlagKey)
            isUnlocked = true
            return true
        }
        let hash = Self.sha256(pin)
        let ok = saveHash(hash)
        if ok {
            UserDefaults.standard.set(true, forKey: enabledFlagKey)
        }
        return ok
    }

    /// Verify an entered PIN against the stored hash.
    func verify(_ pin: String) -> Bool {
        guard let storedHash = loadHash() else { return false }
        return Self.sha256(pin) == storedHash
    }

    // MARK: - Biometrics (optional)

    /// Attempt Face ID / Touch ID authentication. Completion is always called on the main thread.
    func authenticateWithBiometrics(reason: String = "Unlock Sacred Pathway Driver Hub",
                                    completion: @escaping (Bool) -> Void) {
        guard biometricsEnabled else {
            completion(false)
            return
        }
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// Call when the app returns to foreground so a PIN is required again.
    func lock() {
        if isEnabled { isUnlocked = false }
    }

    // MARK: - Keychain helpers

    private func saveHash(_ hashHex: String) -> Bool {
        deleteHash() // overwrite
        guard let data = hashHex.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func loadHash() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteHash() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Hashing

    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            // Fallback-free SHA256 via CommonCrypto
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// Bridge to CommonCrypto without an Objective-C bridging header
@_silgen_name("CC_SHA256")
private func CC_SHA256(_ data: UnsafeRawPointer?,
                       _ len: CC_LONG,
                       _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>?
private typealias CC_LONG = UInt32
