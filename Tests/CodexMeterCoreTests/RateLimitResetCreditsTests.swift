import XCTest
@testable import CodexMeterCore

final class RateLimitResetCreditsTests: XCTestCase {
    func testMissingAndNullResetCreditSummariesRemainUnavailable() throws {
        XCTAssertNil(try decode("{}"))
        XCTAssertNil(try decode(#"{"rateLimitResetCredits":null}"#))
    }

    func testCountOnlySummaryPreservesUnavailableDetails() throws {
        let summary = try XCTUnwrap(try decode(#"""
        {
            "rateLimitResetCredits": {
                "availableCount": 2,
                "credits": null
            }
        }
        """#))

        XCTAssertEqual(summary.availableCount, 2)
        XCTAssertTrue(summary.hasAvailableCredits)
        XCTAssertNil(summary.credits)
    }

    func testDetailedCreditDecodesBackendMetadataAndTimestamps() throws {
        let summary = try XCTUnwrap(try decode(#"""
        {
            "rateLimitResetCredits": {
                "availableCount": 1,
                "credits": [
                    {
                        "id": "reset-1",
                        "title": "Codex reset",
                        "description": "Resets the eligible Codex windows.",
                        "grantedAt": 1800000000,
                        "expiresAt": 1800086400,
                        "resetType": "codexRateLimits",
                        "status": "available"
                    }
                ]
            }
        }
        """#))
        let credit = try XCTUnwrap(summary.credits?.first)

        XCTAssertEqual(credit.id, "reset-1")
        XCTAssertEqual(credit.title, "Codex reset")
        XCTAssertEqual(credit.description, "Resets the eligible Codex windows.")
        XCTAssertEqual(credit.grantedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(credit.expiresAt, Date(timeIntervalSince1970: 1_800_086_400))
        XCTAssertEqual(credit.resetType, .codexRateLimits)
        XCTAssertEqual(credit.status, .available)
        XCTAssertTrue(credit.isUsable(at: Date(timeIntervalSince1970: 1_800_000_001)))
        XCTAssertEqual(
            try XCTUnwrap(
                credit.remainingLifetimeFraction(
                    at: Date(timeIntervalSince1970: 1_800_043_200)
                )
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                credit.remainingLifetimeFraction(
                    at: Date(timeIntervalSince1970: 1_799_999_999)
                )
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                credit.remainingLifetimeFraction(
                    at: Date(timeIntervalSince1970: 1_800_086_401)
                )
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testExpiredAndNonAvailableCreditsAreNotPresentedAsUsable() throws {
        let summary = try XCTUnwrap(try decode(#"""
        {
            "rateLimitResetCredits": {
                "availableCount": 2,
                "credits": [
                    {
                        "id": "expired",
                        "grantedAt": 1799900000,
                        "expiresAt": 1800000000,
                        "resetType": "codexRateLimits",
                        "status": "available"
                    },
                    {
                        "id": "redeemed",
                        "grantedAt": 1799900000,
                        "expiresAt": null,
                        "resetType": "codexRateLimits",
                        "status": "redeemed"
                    }
                ]
            }
        }
        """#))

        XCTAssertTrue(
            summary.usableCredits(at: Date(timeIntervalSince1970: 1_800_000_001)).isEmpty
        )
    }

    func testUnknownBackendEnumValuesRemainForwardCompatible() throws {
        let summary = try XCTUnwrap(try decode(#"""
        {
            "rateLimitResetCredits": {
                "availableCount": 1,
                "credits": [
                    {
                        "id": "future",
                        "grantedAt": 1800000000,
                        "resetType": "futureResetType",
                        "status": "futureStatus"
                    }
                ]
            }
        }
        """#))
        let credit = try XCTUnwrap(summary.credits?.first)

        XCTAssertEqual(credit.resetType, .unknown)
        XCTAssertEqual(credit.status, .unknown)
        XCTAssertNil(
            credit.remainingLifetimeFraction(at: Date(timeIntervalSince1970: 1_800_000_001))
        )
    }

    private func decode(_ json: String) throws -> CodexRateLimitResetCreditsSummary? {
        try CodexRateLimitResetCreditsSummary.decodeResponseData(Data(json.utf8))
    }
}
