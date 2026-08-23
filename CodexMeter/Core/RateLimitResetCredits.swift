import Foundation

/// A banked Codex rate-limit reset returned by the local App Server.
struct CodexRateLimitResetCredit: Identifiable, Equatable, Sendable, Decodable {
    enum Status: String, Equatable, Sendable, Decodable {
        case available
        case redeeming
        case redeemed
        case unknown

        init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }
    }

    enum ResetType: String, Equatable, Sendable, Decodable {
        case codexRateLimits
        case unknown

        init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }
    }

    let id: String
    let title: String?
    let description: String?
    let grantedAt: Date
    let expiresAt: Date?
    let resetType: ResetType
    let status: Status

    func isUsable(at date: Date) -> Bool {
        guard status == .available else { return false }
        return expiresAt.map { $0 > date } ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case grantedAt
        case expiresAt
        case resetType
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        resetType = try container.decode(ResetType.self, forKey: .resetType)
        status = try container.decode(Status.self, forKey: .status)

        let grantedTimestamp = try container.decode(Int64.self, forKey: .grantedAt)
        grantedAt = Date(timeIntervalSince1970: TimeInterval(grantedTimestamp))

        if let expiresTimestamp = try container.decodeIfPresent(Int64.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresTimestamp))
        } else {
            expiresAt = nil
        }
    }
}

/// Distinguishes a confirmed zero balance from an unavailable response.
struct CodexRateLimitResetCreditsSummary: Equatable, Sendable, Decodable {
    let availableCount: Int64
    let credits: [CodexRateLimitResetCredit]?

    var hasAvailableCredits: Bool {
        availableCount > 0
    }

    func usableCredits(at date: Date) -> [CodexRateLimitResetCredit] {
        (credits ?? []).filter { $0.isUsable(at: date) }
    }

    private enum CodingKeys: String, CodingKey {
        case availableCount
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = max(0, try container.decode(Int64.self, forKey: .availableCount))
        credits = try container.decodeIfPresent(
            [CodexRateLimitResetCredit].self,
            forKey: .credits
        )
    }

    /// Decodes only the optional reset-credit member from a full rate-limit result.
    static func decode(fromRateLimitsResult result: [String: Any]) -> Self? {
        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result) else {
            return nil
        }
        return try? decodeResponseData(data)
    }

    static func decodeResponseData(_ data: Data) throws -> Self? {
        try JSONDecoder().decode(RateLimitsResponse.self, from: data).rateLimitResetCredits
    }

    private struct RateLimitsResponse: Decodable {
        let rateLimitResetCredits: CodexRateLimitResetCreditsSummary?
    }
}
