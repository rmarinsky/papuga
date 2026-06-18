import Defaults
import Foundation
import OSLog

protocol MistakeObservationRecording: AnyObject {
    func record(_ entry: MistakeObservation)
}

@Observable
final class MistakeObservationStore: MistakeObservationRecording {
    static let shared = MistakeObservationStore()

    private(set) var entries: [MistakeObservation] = []

    private let ioQueue = DispatchQueue(label: "ua.com.rmarinsky.papuga.mistake-observations", qos: .utility)
    private let fileURL: URL
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "Mistakes")

    private let memoryCap = 5000
    private let fileSizeCap = 25 * 1024 * 1024

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("papuga", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.fileURL = dir.appendingPathComponent("mistake-observations.jsonl")
    }

    func bootstrap() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.loadEntriesFromDisk()
            DispatchQueue.main.async {
                self.entries = loaded
                self.logger.notice("MistakeObservationStore bootstrapped with \(loaded.count, privacy: .public) entries")
            }
            self.pruneSync()
        }
    }

    func record(_ entry: MistakeObservation) {
        if Thread.isMainThread {
            entries.insert(entry, at: 0)
            enforceMemoryCap()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.entries.insert(entry, at: 0)
                self.enforceMemoryCap()
            }
        }

        ioQueue.async { [weak self] in
            self?.appendToDisk(entry)
        }
    }

    func updateStatus(for id: UUID, to status: MistakeObservation.Status) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let old = entries[index]
        let updated = MistakeObservation(
            id: old.id,
            timestamp: old.timestamp,
            issueType: old.issueType,
            status: status,
            source: old.source,
            suggestedTarget: old.suggestedTarget,
            language: old.language,
            bundleID: old.bundleID,
            confidence: old.confidence,
            contextHash: old.contextHash
        )
        entries[index] = updated
        rewriteAsync(snapshot: entries)
    }

    func clearAll() {
        entries = []
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
            self.logger.notice("MistakeObservationStore cleared")
        }
    }

    func clear(where shouldRemove: (MistakeObservation) -> Bool) {
        let remaining = entries.filter { !shouldRemove($0) }
        guard remaining.count != entries.count else { return }

        entries = remaining
        rewriteAsync(snapshot: remaining)
    }

    func pruneByRetentionAsync() {
        ioQueue.async { [weak self] in
            self?.pruneSync()
        }
    }

    func entries(status: MistakeObservation.Status? = nil, issueType: MistakeObservation.IssueType? = nil) -> [MistakeObservation] {
        entries.filter { entry in
            if let status, entry.status != status { return false }
            if let issueType, entry.issueType != issueType { return false }
            return true
        }
    }

    private func enforceMemoryCap() {
        guard entries.count > memoryCap else { return }
        entries.removeLast(entries.count - memoryCap)
    }

    private func appendToDisk(_ entry: MistakeObservation) {
        do {
            let data = try encoder.encode(entry)
            var line = data
            line.append(0x0A)

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
            logger.warning("MistakeObservationStore append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadEntriesFromDisk() -> [MistakeObservation] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var result: [MistakeObservation] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(MistakeObservation.self, from: lineData) else {
                continue
            }
            result.append(entry)
        }
        result.sort { $0.timestamp > $1.timestamp }
        if result.count > memoryCap {
            result = Array(result.prefix(memoryCap))
        }
        return result
    }

    private func pruneSync() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        let retention = MistakeObservationRetention(rawValue: Defaults[.mistakeObservationRetention]) ?? .oneMonth
        let cutoff = Date().addingTimeInterval(-retention.timeInterval)

        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        var keptLines: [String] = []
        var keptEntries: [MistakeObservation] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(MistakeObservation.self, from: lineData) else {
                continue
            }
            if entry.timestamp < cutoff { continue }
            keptLines.append(String(line))
            keptEntries.append(entry)
        }

        if size > fileSizeCap {
            let target = fileSizeCap / 2
            var totalBytes = 0
            var trimmed: [String] = []
            var trimmedEntries: [MistakeObservation] = []
            for (line, entry) in zip(keptLines, keptEntries).reversed() {
                totalBytes += line.utf8.count + 1
                if totalBytes > target { break }
                trimmed.append(line)
                trimmedEntries.append(entry)
            }
            keptLines = trimmed.reversed()
            keptEntries = trimmedEntries.reversed()
        }

        writeSnapshotSync(lines: keptLines, entries: keptEntries)
    }

    private func rewriteAsync(snapshot: [MistakeObservation]) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let lines = snapshot.compactMap { entry -> String? in
                guard let data = try? self.encoder.encode(entry) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            self.writeSnapshotSync(lines: lines, entries: snapshot)
        }
    }

    private func writeSnapshotSync(lines: [String], entries: [MistakeObservation]) {
        let newContent = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        do {
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
            var snapshot = entries
            snapshot.sort { $0.timestamp > $1.timestamp }
            if snapshot.count > memoryCap {
                snapshot = Array(snapshot.prefix(memoryCap))
            }
            DispatchQueue.main.async { [weak self] in
                self?.entries = snapshot
            }
            logger.notice("MistakeObservationStore wrote \(snapshot.count, privacy: .public) entries")
        } catch {
            logger.warning("MistakeObservationStore rewrite failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
