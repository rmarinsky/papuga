import Defaults
import OSLog
import XCTest
@testable import papuga

final class AppLoggerPrivacyTests: XCTestCase {
    func test_actionRedactsDynamicMessageFromUnifiedLog() throws {
        let category = "PrivacyTest-\(UUID().uuidString)"
        let logger = Logger(subsystem: Constants.bundleIdentifier, category: category)
        let sentinel = "papuga-private-sentinel"

        AppLogger.action(logger, "Private value: \(sentinel)")

        let entries = try logEntries(category: category)
        XCTAssertEqual(entries.last?.formatString, "%{private}s")
    }

    @MainActor
    func test_ignoreWordDoesNotAppearInDiagnosticLogs() throws {
        let originalAllowlist = Defaults[.autoFixAllowlist]
        let originalRules = Defaults[.customAutoReplaceRules]
        defer {
            Defaults[.autoFixAllowlist] = originalAllowlist
            Defaults[.customAutoReplaceRules] = originalRules
        }
        let sentinel = "PapugaSecret\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        let result = IgnoreWordService.add(
            sentinel,
            teachAppleSpelling: false,
            removeReplacementRules: false
        )

        XCTAssertEqual(result?.word, sentinel)
        XCTAssertFalse(try logEntries(category: "AutoFix").contains { $0.eventMessage.contains(sentinel) })
    }

    private func logEntries(category: String) throws -> [LogEntry] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "1m", "--style", "json",
            "--predicate", "subsystem == \"\(Constants.bundleIdentifier)\" AND category == \"\(category)\""
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        return try JSONDecoder().decode([LogEntry].self, from: output.fileHandleForReading.readDataToEndOfFile())
    }

    private struct LogEntry: Decodable {
        let formatString: String
        let eventMessage: String
    }
}
