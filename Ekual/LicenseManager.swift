import CryptoKit
import Foundation

@Observable
@MainActor
final class LicenseManager {

    static let shared = LicenseManager()

    // MARK: - Ed25519 Public Key (base64-encoded, 32 bytes)

    private static let publicKeyBase64 = "xAEULAUmM12fIzEwsG+b3q7kyxy1WOKPPtjNqhsjrxM="

    // MARK: - Keys

    private enum Keys {
        static let licenseKey = "licenseKey"
    }

    // MARK: - Stored License

    var licenseKey: String? {
        didSet {
            if let key = licenseKey {
                UserDefaults.standard.set(key, forKey: Keys.licenseKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.licenseKey)
            }
        }
    }

    // MARK: - Computed State

    var isLicensed: Bool {
        guard let key = licenseKey else { return false }
        return Self.verify(licenseKey: key)
    }

    // MARK: - Init

    private init() {
        self.licenseKey = UserDefaults.standard.string(forKey: Keys.licenseKey)
    }

    // MARK: - Activation

    /// Validates the key and stores it if valid.
    func activate(key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.verify(licenseKey: trimmed) else { return false }
        licenseKey = trimmed
        return true
    }

    func deactivate() {
        licenseKey = nil
    }

    // MARK: - Ed25519 Verification

    /// License key format: base64(jsonPayload).base64(signature)
    private static func verify(licenseKey: String) -> Bool {
        let parts = licenseKey.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return false }

        guard let payloadData = Data(base64Encoded: String(parts[0])),
              let signatureData = Data(base64Encoded: String(parts[1])) else {
            return false
        }

        // Validate payload JSON
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let product = json["product"] as? String,
              product == "ekual",
              json["email"] is String else {
            return false
        }

        // Verify Ed25519 signature
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }

        return publicKey.isValidSignature(signatureData, for: payloadData)
    }
}
