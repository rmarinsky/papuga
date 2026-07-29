import XCTest
@testable import papuga

final class AIAnalysisRunnerTests: XCTestCase {
    private func executable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-fake-ai-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test_executeTransportsPromptThroughStdinAndDrainsStderr() async throws {
        let script = try executable("cat; printf diagnostic >&2")
        let output = try await AIAnalysisRunner().execute(
            executable: script,
            arguments: [],
            prompt: "papuga prompt",
            timeout: 2
        )
        XCTAssertEqual(output.stdout, "papuga prompt")
        XCTAssertEqual(output.stderr, "diagnostic")
    }

    func test_executeReportsNonZeroExit() async throws {
        let script = try executable("printf nope >&2; exit 7")
        do {
            _ = try await AIAnalysisRunner().execute(executable: script, arguments: [], prompt: "", timeout: 2)
            XCTFail("Expected non-zero exit")
        } catch let error as AIAnalysisRunner.Error {
            XCTAssertEqual(error, .nonZeroExit(7, "nope"))
        }
    }

    func test_executeTimesOutAndCanBeCancelled() async throws {
        let script = try executable("sleep 5")
        do {
            _ = try await AIAnalysisRunner().execute(executable: script, arguments: [], prompt: "", timeout: 0.05)
            XCTFail("Expected timeout")
        } catch let error as AIAnalysisRunner.Error {
            XCTAssertEqual(error, .timedOut)
        }

        let task = Task {
            try await AIAnalysisRunner().execute(executable: script, arguments: [], prompt: "", timeout: 5)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func test_executeRejectsOversizedOutput() async throws {
        let script = try executable("yes x | head -c 2100000")
        do {
            _ = try await AIAnalysisRunner().execute(executable: script, arguments: [], prompt: "", timeout: 2)
            XCTFail("Expected output limit")
        } catch let error as AIAnalysisRunner.Error {
            XCTAssertEqual(error, .outputTooLarge)
        }
    }

    func test_threeExecutablesCompleteIndependently() async throws {
        let success = try executable("cat")
        let failure = try executable("exit 2")
        let targets = [success, failure, success]
        let results = await AIAnalysisRunner().executeAll(
            targets.map { ($0, [String]()) },
            prompt: "same prompt",
            timeout: 2
        )
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.compactMap { try? $0.get().stdout }, ["same prompt", "same prompt"])
    }
}
