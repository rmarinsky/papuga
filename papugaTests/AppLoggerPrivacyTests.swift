import OSLog
import XCTest
@testable import papuga

final class AppLoggerPrivacyTests: XCTestCase {
    func test_actionRedactsDynamicMessageFromUnifiedLog() throws {
        let category = "PrivacyTest-\(UUID().uuidString)"
        let logger = Logger(subsystem: Constants.bundleIdentifier, category: category)

        AppLogger.action(logger, "papuga-private-sentinel")

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
        let entries = try JSONDecoder().decode([LogEntry].self, from: output.fileHandleForReading.readDataToEndOfFile())
        XCTAssertEqual(entries.last?.formatString, "%{private}s")
    }

    private struct LogEntry: Decodable {
        let formatString: String
    }
}
