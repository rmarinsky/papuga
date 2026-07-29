import Foundation

enum AIProviderState: Equatable {
    case notInstalled
    case needsAuthentication(executable: URL, version: String)
    case ready(executable: URL, version: String)
    case failed(String)
}

struct AIProviderDiscovery {
    private let runner = AIAnalysisRunner()

    func probe(_ target: AIAnalysisTarget) async -> AIProviderState {
        guard target.provider != .ollama else { return .failed("Ollama uses its localhost API.") }
        guard let executable = executable(for: target) else { return .notInstalled }
        do {
            let version = try await runner.execute(
                executable: executable,
                arguments: target.provider.versionArguments,
                prompt: "",
                timeout: 5
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let authArguments = target.provider.authArguments {
                do {
                    _ = try await runner.execute(
                        executable: executable,
                        arguments: authArguments,
                        prompt: "",
                        timeout: 10
                    )
                } catch AIAnalysisRunner.Error.nonZeroExit {
                    return .needsAuthentication(executable: executable, version: version)
                }
            }
            return .ready(executable: executable, version: version)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func executable(for target: AIAnalysisTarget) -> URL? {
        if let path = target.executablePath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        guard let name = target.provider.executableName else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let directories = inherited + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
