import XCTest
@testable import papuga

final class AIAnalysisRunnerTests: XCTestCase {
    func test_providerProgressAdvancesOnlyAfterAValidatedBatch() {
        var progress = AIProviderBatchProgress(totalItems: 205, totalBatches: 3)

        progress.recordCompletedBatch(itemCount: 100, resultCount: 92, missingCount: 8)

        XCTAssertEqual(progress.completedItems, 100)
        XCTAssertEqual(progress.completedBatches, 1)
        XCTAssertEqual(progress.resultCount, 92)
        XCTAssertEqual(progress.missingCount, 8)
        XCTAssertEqual(progress.nextBatchIndex, 1)
        XCTAssertEqual(progress.fractionCompleted, 100.0 / 205.0, accuracy: 0.001)
    }

    func test_batchExecutionKeepsCompletedResultsAndRetriesFromFailedBatch() async throws {
        let observations = (1...3).map {
            MistakeObservation(
                issueType: .spelling,
                source: "typo\($0)",
                language: "en",
                confidence: 0.8
            )
        }
        let groups = MistakesScreenDerivation.groups(from: observations, filter: .all, query: "")
        let candidates = Dictionary(uniqueKeysWithValues: (1...3).map {
            ("typo\($0)", [MistakeSuggestionCandidate(kind: .spelling, text: "type\($0)", confidence: 0.9)])
        })
        let plan = AIPromptBuilder.buildComparisonBatches(
            from: groups,
            candidatesBySource: candidates,
            sendAppNames: false,
            scrubSecrets: true,
            batchSize: 1
        )

        let failed = try await AIProviderBatchExecutor.run(batches: plan.batches) { batch in
            let alias = try XCTUnwrap(batch.context.knownAliases.first)
            if alias == "m2" { throw AIAnalysisRunner.Error.nonZeroExit(1, "temporary") }
            return try self.validV2Response(for: batch)
        }

        XCTAssertEqual(failed.progress.completedItems, 1)
        XCTAssertEqual(failed.suggestions.map(\.id), ["m1"])
        XCTAssertEqual(failed.failure?.batchIndex, 1)

        let retried = try await AIProviderBatchExecutor.run(batches: plan.batches, resuming: failed) {
            try self.validV2Response(for: $0)
        }

        XCTAssertEqual(retried.progress.completedItems, 3)
        XCTAssertEqual(retried.suggestions.map(\.id), ["m1", "m2", "m3"])
        XCTAssertNil(retried.failure)
    }

    func test_cursorRunsNonInteractivelyInPapugasTrustedTemporaryWorkspace() {
        XCTAssertEqual(
            AIProvider.cursorAgent.generationArguments,
            ["-p", "--output-format", "text", "--mode", "ask", "--trust"]
        )
    }

    func test_selectionNeverExceedsThreeTargets() {
        let targets = AIProvider.allCases.map { AIAnalysisTarget(provider: $0, model: nil) }
        XCTAssertEqual(AIAnalysisSelection.normalized(targets).count, 3)
        XCTAssertEqual(AIAnalysisSelection.normalized(targets).map(\.provider), Array(AIProvider.allCases.prefix(3)))
        XCTAssertEqual(
            AIAnalysisSelection.normalized([
                AIAnalysisTarget(provider: .ollama, model: "qwen"),
                AIAnalysisTarget(provider: .ollama, model: "gemma")
            ]).count,
            1
        )
    }

    func test_discoveryFindsManualExecutableAndReportsVersion() async throws {
        let script = try executable("printf 'papuga-agent 1.0'")
        let target = AIAnalysisTarget(provider: .codex, model: nil, executablePath: script.path)
        let state = await AIProviderDiscovery().probe(target)
        XCTAssertEqual(state, .ready(executable: script, version: "papuga-agent 1.0"))
    }

    private func executable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-fake-ai-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func validV2Response(for batch: AIPromptBatch) throws -> String {
        let alias = try XCTUnwrap(batch.context.knownAliases.first)
        let target = try XCTUnwrap(batch.items[alias]?.localCandidates.first)
        return #"{"version":2,"predictions":[{"id":"\#(alias)","rankedTargets":["\#(target)"],"target":"\#(target)","otherTarget":null,"confidence":0.9,"explanation":"candidate"}]}"#
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
        let script = try executable("printf 'Workspace Trust Required sk-not-a-real-secret' >&2; exit 7")
        do {
            _ = try await AIAnalysisRunner().execute(executable: script, arguments: [], prompt: "", timeout: 2)
            XCTFail("Expected non-zero exit")
        } catch let error as AIAnalysisRunner.Error {
            XCTAssertEqual(error, .nonZeroExit(7, "Workspace Trust Required sk-not-a-real-secret"))
            XCTAssertEqual(error.localizedDescription, "Workspace Trust Required [REDACTED] (код 7)")
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
