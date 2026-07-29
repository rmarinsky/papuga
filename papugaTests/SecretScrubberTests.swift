import XCTest
@testable import papuga

/// Locks the secret scrubber: real words pass, structured/credential-shaped tokens are held
/// back, and the kept/redacted partition is correct.
final class SecretScrubberTests: XCTestCase {

    func testFlagsCredentialShapedTokens() {
        XCTAssertTrue(SecretScrubber.isLikelySecret("sk-ABCDEFGHIJKLMNOP1234"))
        XCTAssertTrue(SecretScrubber.isLikelySecret("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"))
        XCTAssertTrue(SecretScrubber.isLikelySecret("user@example.com"))
        XCTAssertTrue(SecretScrubber.isLikelySecret("https://example.com/secret"))
        XCTAssertTrue(SecretScrubber.isLikelySecret("a1b2c3d4e5f6a7b8c9d0e1f2"))  // 24 hex
        XCTAssertTrue(SecretScrubber.isLikelySecret("path/to/thing"))
    }

    func testKeepsOrdinaryWords() {
        XCTAssertFalse(SecretScrubber.isLikelySecret("привіт"))
        XCTAssertFalse(SecretScrubber.isLikelySecret("ghbdtn"))
        XCTAssertFalse(SecretScrubber.isLikelySecret("темплейту"))
        XCTAssertFalse(SecretScrubber.isLikelySecret("the"))
        XCTAssertFalse(SecretScrubber.isLikelySecret(""))
    }

    func testScrubPartition() {
        let result = SecretScrubber.scrub(["привіт", "sk-ABCDEFGHIJKLMNOP1234", "ghbdtn"])
        XCTAssertEqual(result.kept, ["привіт", "ghbdtn"])
        XCTAssertEqual(result.redactedCount, 1)
    }

    func testSanitizeDiagnosticRedactsWrappedCredentialsBeforeTruncation() {
        XCTAssertEqual(
            SecretScrubber.sanitizeDiagnostic("OPENAI_API_KEY=sk-shortsecret"),
            "OPENAI_API_KEY=[REDACTED]"
        )
        XCTAssertEqual(
            SecretScrubber.sanitizeDiagnostic(#"{"token":"ghp_shortsecret"}"#),
            #"{"token":[REDACTED]}"#
        )
        XCTAssertEqual(
            SecretScrubber.sanitizeDiagnostic("request?access_token=ya29.shortsecret&retry=1"),
            "request?access_token=[REDACTED]&retry=1"
        )
        XCTAssertEqual(
            SecretScrubber.sanitizeDiagnostic("Authorization: Bearer opaque-value"),
            "Authorization: Bearer [REDACTED]"
        )
        XCTAssertEqual(
            SecretScrubber.sanitizeDiagnostic(#"password="hunter two words""#),
            "password=[REDACTED]"
        )
        XCTAssertEqual(
            SecretScrubber.sanitizeDiagnostic("token='opaque value'"),
            "token=[REDACTED]"
        )

        let crossingBoundary = "token=sk-" + String(repeating: "A", count: 700)
        let error = AIAnalysisRunner.Error.nonZeroExit(7, crossingBoundary)
        XCTAssertEqual(error.localizedDescription, "token=[REDACTED] (код 7)")
    }
}
