import Foundation

/// Runs user-installed AI CLIs without a shell. Prompts go through stdin and
/// stdout/stderr are drained concurrently so a noisy provider cannot deadlock.
final class AIAnalysisRunner {
    static let outputLimit = 2_000_000
    private let session: URLSession
    private let ollamaBaseURL: URL

    init(
        session: URLSession = .shared,
        ollamaBaseURL: URL = URL(string: "http://127.0.0.1:11434")!
    ) {
        self.session = session
        self.ollamaBaseURL = ollamaBaseURL
    }

    struct ProcessOutput: Equatable {
        let stdout: String
        let stderr: String
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case launchFailed(String)
        case nonZeroExit(Int32, String)
        case timedOut
        case outputTooLarge
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message):
                return "Не вдалося запустити CLI: \(Self.safeDiagnostic(message))"
            case .nonZeroExit(let code, let stderr):
                let diagnostic = Self.safeDiagnostic(stderr)
                return diagnostic.isEmpty
                    ? "CLI завершився з кодом \(code)"
                    : "\(diagnostic) (код \(code))"
            case .timedOut: return "CLI не відповів за 180 секунд"
            case .outputTooLarge: return "Відповідь CLI перевищила 2 MB"
            case .invalidUTF8: return "CLI повернув невалідний текст"
            }
        }

        private static func safeDiagnostic(_ value: String) -> String {
            String(SecretScrubber.sanitizeDiagnostic(value).suffix(600))
        }
    }

    enum OllamaError: Swift.Error, Equatable {
        case invalidResponse
        case http(Int)
        case missingModel(String)
    }

    func discoverOllamaModels() async throws -> [String] {
        let (data, response) = try await session.data(from: ollamaBaseURL.appendingPathComponent("api/tags"))
        guard let http = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OllamaError.http(http.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw OllamaError.invalidResponse
        }
        return models.compactMap { $0["name"] as? String }
    }

    func runOllama(model: String, prompt: String) async throws -> String {
        guard try await discoverOllamaModels().contains(model) else {
            throw OllamaError.missingModel(model)
        }
        var request = URLRequest(url: ollamaBaseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "options": ["temperature": 0],
            "format": Self.responseSchema
        ])
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.outputLimit else { throw Error.outputTooLarge }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OllamaError.http(http.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OllamaError.invalidResponse
        }
        return content
    }

    private static let responseSchema: [String: Any] = [
        "type": "object",
        "required": ["version", "predictions"],
        "properties": [
            "version": ["type": "integer", "const": 2],
            "predictions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "required": ["id", "rankedTargets", "target", "confidence", "explanation"],
                    "properties": [
                        "id": ["type": "string"],
                        "rankedTargets": ["type": "array", "items": ["type": "string"]],
                        "target": ["type": "string"],
                        "otherTarget": ["type": ["string", "null"]],
                        "confidence": ["type": "number"],
                        "explanation": ["type": "string", "maxLength": 240]
                    ]
                ]
            ]
        ]
    ]

    func execute(
        executable: URL,
        arguments: [String],
        prompt: String,
        timeout: TimeInterval = 180
    ) async throws -> ProcessOutput {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let buffers = OutputBuffers(limit: Self.outputLimit)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            buffers.append(handle.availableData, toStdout: true, process: process)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            buffers.append(handle.availableData, toStdout: false, process: process)
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        do {
            try process.run()
        } catch {
            throw Error.launchFailed(error.localizedDescription)
        }
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            if buffers.isOversized {
                process.terminate()
                while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                throw Error.outputTooLarge
            }
            if Date() >= deadline {
                process.terminate()
                while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                throw Error.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        // Let the readability handlers consume their final EOF chunk.
        try await Task.sleep(for: .milliseconds(10))
        let data = buffers.snapshot()
        if data.oversized { throw Error.outputTooLarge }
        guard let stdout = String(data: data.stdout, encoding: .utf8),
              let stderr = String(data: data.stderr, encoding: .utf8) else {
            throw Error.invalidUTF8
        }
        guard process.terminationStatus == 0 else {
            throw Error.nonZeroExit(process.terminationStatus, stderr)
        }
        return ProcessOutput(stdout: stdout, stderr: stderr)
    }

    func executeAll(
        _ commands: [(URL, [String])],
        prompt: String,
        timeout: TimeInterval = 180
    ) async -> [Result<ProcessOutput, Swift.Error>] {
        await withTaskGroup(of: (Int, Result<ProcessOutput, Swift.Error>).self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await self.execute(
                            executable: command.0,
                            arguments: command.1,
                            prompt: prompt,
                            timeout: timeout
                        )))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = Array<Result<ProcessOutput, Swift.Error>?>(repeating: nil, count: commands.count)
            for await (index, result) in group { results[index] = result }
            return results.map { $0! }
        }
    }
}

struct AIProviderBatchFailure: Equatable {
    let batchIndex: Int
    let message: String
}

struct AIProviderBatchExecution: Equatable {
    var progress: AIProviderBatchProgress
    var suggestions: [AISuggestion]
    var failure: AIProviderBatchFailure?
}

@MainActor
enum AIProviderBatchExecutor {
    static func run(
        batches: [AIPromptBatch],
        resuming previous: AIProviderBatchExecution? = nil,
        onProgress: ((AIProviderBatchExecution) -> Void)? = nil,
        execute: (AIPromptBatch) async throws -> String
    ) async throws -> AIProviderBatchExecution {
        var result = previous ?? AIProviderBatchExecution(
            progress: AIProviderBatchProgress(
                totalItems: batches.reduce(0) { $0 + $1.itemCount },
                totalBatches: batches.count
            ),
            suggestions: [],
            failure: nil
        )
        result.failure = nil

        for index in result.progress.nextBatchIndex..<batches.count {
            let batch = batches[index]
            let raw: String
            do {
                raw = try await execute(batch)
            } catch let error as CancellationError {
                throw error
            } catch {
                result.failure = AIProviderBatchFailure(
                    batchIndex: index,
                    message: error.localizedDescription
                )
                return result
            }

            let validation = AIResponseValidator.validate(raw, context: batch.context)
            if let blocked = validation.blocked {
                result.failure = AIProviderBatchFailure(batchIndex: index, message: blocked.message)
                return result
            }
            result.suggestions.append(contentsOf: validation.recognized)
            result.progress.recordCompletedBatch(
                itemCount: batch.itemCount,
                resultCount: validation.recognizedCount,
                missingCount: validation.missingAliases.count
            )
            onProgress?(result)
        }
        return result
    }
}

private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var stdout = Data()
    private var stderr = Data()
    private var oversized = false

    init(limit: Int) { self.limit = limit }

    var isOversized: Bool { lock.withLock { oversized } }

    func append(_ data: Data, toStdout: Bool, process: Process) {
        guard !data.isEmpty else { return }
        let shouldTerminate = lock.withLock {
            guard !oversized else { return false }
            if stdout.count + stderr.count + data.count > limit {
                oversized = true
                return true
            }
            if toStdout { stdout.append(data) } else { stderr.append(data) }
            return false
        }
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func snapshot() -> (stdout: Data, stderr: Data, oversized: Bool) {
        lock.withLock { (stdout, stderr, oversized) }
    }
}
