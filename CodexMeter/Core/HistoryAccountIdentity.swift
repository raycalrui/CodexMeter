import CryptoKit
import Foundation

/// A pseudonymous local key used to keep history from different accounts separate.
struct HistoryAccountIdentity: Equatable, Sendable {
    nonisolated static let legacyKey = "legacy"

    let key: String
    let isStable: Bool

    static func make(accountType: String, email: String?, salt: String) -> Self {
        let normalizedType = accountType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let normalizedEmail = email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))

        let stableEmail = normalizedEmail.flatMap { $0.isEmpty ? nil : $0 }
        let identityMaterial = [salt, normalizedType, stableEmail ?? "anonymous"]
            .joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identityMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let prefix = stableEmail == nil ? "anonymous" : normalizedType

        return Self(key: "\(prefix):\(digest)", isStable: stableEmail != nil)
    }
}
