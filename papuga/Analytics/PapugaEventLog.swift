import Foundation

final class PapugaEventLog {
    static let shared = PapugaEventLog()

    private let queue = DispatchQueue(label: "ua.com.rmarinsky.papuga.eventlog", qos: .utility)
    private let fileURL: URL
    private let logger = AppLogger.analytics

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    private static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let maxFileSizeBytes: Int = 50 * 1024 * 1024

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("papuga", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.fileURL = dir.appendingPathComponent("events.jsonl")
        AppLogger.post(logger, "PapugaEventLog initialized at \(fileURL.path)")
    }

    func track(_ event: AnalyticsEvent) {
        queue.async { [weak self] in
            self?.appendSync(event)
        }
    }

    private func appendSync(_ event: AnalyticsEvent) {
        do {
            let data = try encoder.encode(event)
            var line = data
            line.append(0x0A) // newline

            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        } catch {
            AppLogger.warn(logger, "PapugaEventLog append failed: \(error.localizedDescription)")
        }
    }

    func pruneOldEntries() {
        queue.async { [weak self] in
            self?.pruneSync()
        }
    }

    private func pruneSync() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)

        guard size > 1024 * 1024 || size > Self.maxFileSizeBytes else {
            return
        }

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var keptLines: [String] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(AnalyticsEvent.self, from: lineData) else {
                continue
            }
            if event.timestamp >= cutoff {
                keptLines.append(String(line))
            }
        }

        if size > Self.maxFileSizeBytes {
            let target = Self.maxFileSizeBytes / 2
            var totalBytes = 0
            var trimmed: [String] = []
            for line in keptLines.reversed() {
                totalBytes += line.utf8.count + 1
                if totalBytes > target { break }
                trimmed.append(line)
            }
            keptLines = trimmed.reversed()
        }

        let newContent = keptLines.joined(separator: "\n") + (keptLines.isEmpty ? "" : "\n")
        do {
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
            AppLogger.action(logger, "PapugaEventLog pruned: kept \(keptLines.count) entries")
        } catch {
            AppLogger.warn(logger, "PapugaEventLog prune failed: \(error.localizedDescription)")
        }
    }
}
