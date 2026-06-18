import AppKit
import Defaults
import Foundation

@Observable
final class ClipboardHistoryManager {
    var entries: [ClipboardHistoryEntry] = []

    private let clipboardManager = ClipboardManager()
    private let pasteboard = NSPasteboard.general
    private let logger = AppLogger.clipboard
    private let ioQueue = DispatchQueue(label: "ua.com.rmarinsky.papuga.clipboard-history", qos: .utility)
    private let fileURL: URL

    private var monitorTimer: Timer?
    private var lastObservedChangeCount: Int
    private var suspensionCount = 0

    private let maxEntries: Int
    private let pollInterval: TimeInterval
    private let cleanupInterval: TimeInterval = 60
    private let fileSizeCap = 150 * 1024 * 1024
    private var lastCleanupAt: Date = .distantPast

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

    init(
        maxEntries: Int = 1000,
        pollInterval: TimeInterval = 0.35,
        fileURL: URL? = nil
    ) {
        self.maxEntries = maxEntries
        self.pollInterval = pollInterval
        self.lastObservedChangeCount = NSPasteboard.general.changeCount

        if let fileURL {
            self.fileURL = fileURL
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } else {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("papuga", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.fileURL = dir.appendingPathComponent("clipboard-history.jsonl")
        }

        Defaults.observe(.clipboardHistoryRetention) { [weak self] _ in
            DispatchQueue.main.async {
                self?.pruneExpiredEntries(now: Date(), force: true)
            }
        }.tieToLifetime(of: self)
        AppLogger.post(logger, "ClipboardHistoryManager initialized: maxEntries=\(maxEntries), pollInterval=\(pollInterval)")
    }

    deinit {
        stopMonitoring()
    }

    func bootstrap(completion: (() -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.loadEntriesFromDisk()
            let pruned = self.prunedSnapshot(loaded, now: Date())
            if pruned != loaded {
                self.rewriteDisk(with: pruned)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.entries = self.mergedSnapshot(loaded: pruned, current: self.entries)
                AppLogger.post(self.logger, "Clipboard history bootstrapped: entries=\(self.entries.count)")
                completion?()
            }
        }
    }

    func startMonitoring() {
        AppLogger.pre(logger, "ClipboardHistoryManager.startMonitoring()")
        guard monitorTimer == nil else {
            AppLogger.warn(logger, "ClipboardHistoryManager.startMonitoring() ignored: already running")
            return
        }

        lastObservedChangeCount = pasteboard.changeCount
        pruneExpiredEntries(now: Date(), force: true)
        captureCurrentStateIfNeeded(force: true)

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.captureCurrentStateIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
        AppLogger.post(logger, "Clipboard history monitoring started")
    }

    func refreshNow() {
        if monitorTimer == nil {
            startMonitoring()
            return
        }

        captureCurrentStateIfNeeded(force: true)
    }

    func stopMonitoring() {
        AppLogger.pre(logger, "ClipboardHistoryManager.stopMonitoring()")
        monitorTimer?.invalidate()
        monitorTimer = nil
        AppLogger.post(logger, "Clipboard history monitoring stopped")
    }

    func suspendTracking(reason: String) {
        suspensionCount += 1
        AppLogger.action(logger, "Clipboard history suspended (count=\(suspensionCount), reason=\(reason))")
    }

    func resumeTracking(reason: String) {
        guard suspensionCount > 0 else {
            AppLogger.warn(logger, "Clipboard history resume ignored (reason=\(reason)): counter is already zero")
            return
        }
        suspensionCount -= 1
        lastObservedChangeCount = pasteboard.changeCount
        AppLogger.action(logger, "Clipboard history resumed (count=\(suspensionCount), reason=\(reason))")
    }

    func restoreEntry(_ entry: ClipboardHistoryEntry) {
        AppLogger.pre(logger, "restoreEntry(id=\(entry.id.uuidString))")
        suspendTracking(reason: "restoreEntry")
        defer { resumeTracking(reason: "restoreEntry") }

        clipboardManager.restore(entry.state)
        lastObservedChangeCount = pasteboard.changeCount
        promoteEntryToTop(entryID: entry.id)
        AppLogger.post(logger, "Clipboard history entry restored")
    }

    func clearAll() {
        entries.removeAll()
        removeDiskFile()
        AppLogger.action(logger, "Clipboard history cleared")
    }

    func clear(where shouldRemove: (ClipboardHistoryEntry) -> Bool) {
        let beforeCount = entries.count
        entries.removeAll(where: shouldRemove)
        if beforeCount != entries.count {
            persistSnapshot(entries)
            AppLogger.action(logger, "Clipboard history cleared: \(beforeCount) -> \(entries.count)")
        }
    }

    private func captureCurrentStateIfNeeded(force: Bool = false) {
        let now = Date()
        pruneExpiredEntries(now: now)

        let currentChangeCount = pasteboard.changeCount

        if !force {
            guard currentChangeCount != lastObservedChangeCount else { return }
            guard suspensionCount == 0 else {
                lastObservedChangeCount = currentChangeCount
                return
            }
        } else if suspensionCount > 0 {
            return
        }

        lastObservedChangeCount = currentChangeCount
        let state = clipboardManager.save()
        guard !state.items.isEmpty else {
            AppLogger.warn(logger, "Clipboard history skipped capture: no items")
            return
        }

        let signature = ClipboardHistorySignature.make(for: state)
        if entries.first?.signature == signature {
            return
        }

        let hadDuplicate = entries.contains { $0.signature == signature }
        entries.removeAll(where: { $0.signature == signature })
        let preview = previewForState(state)

        let entry = ClipboardHistoryEntry(
            id: UUID(),
            state: state,
            capturedAt: Date(),
            title: preview.title,
            subtitle: preview.subtitle,
            systemImage: preview.systemImage,
            signature: signature
        )

        entries.insert(entry, at: 0)
        let didTrim = enforceMaxEntriesLimit()

        if hadDuplicate || didTrim {
            persistSnapshot(entries)
        } else {
            appendToDisk(entry)
        }

        AppLogger.post(logger, "Clipboard history captured: entries=\(entries.count), title=\(entry.title)")
    }

    private func promoteEntryToTop(entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        guard index != 0 else { return }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
    }

    private func pruneExpiredEntries(now: Date, force: Bool = false) {
        guard force || now.timeIntervalSince(lastCleanupAt) >= cleanupInterval else { return }
        lastCleanupAt = now

        let retention = currentRetentionPreset
        let cutoffDate = retention.timeInterval.map { now.addingTimeInterval(-$0) }
        let beforeCount = entries.count
        entries.removeAll { entry in
            guard let cutoffDate else { return false }
            return entry.capturedAt < cutoffDate
        }
        var didTrim = enforceMaxEntriesLimit()
        if isDiskOverFileSizeCap {
            entries = entriesFittingFileBudget(entries, targetBytes: fileSizeCap / 2)
            didTrim = true
        }

        if beforeCount != entries.count || didTrim {
            persistSnapshot(entries)
            AppLogger.action(
                logger,
                "Clipboard history pruned by retention (\(retention.rawValue)): \(beforeCount) -> \(entries.count)"
            )
        }
    }

    @discardableResult
    private func enforceMaxEntriesLimit() -> Bool {
        guard entries.count > maxEntries else { return false }
        entries.removeLast(entries.count - maxEntries)
        return true
    }

    private func appendToDisk(_ entry: ClipboardHistoryEntry) {
        ioQueue.async { [weak self] in
            self?.appendToDiskSync(entry)
        }
    }

    private func persistSnapshot(_ snapshot: [ClipboardHistoryEntry]) {
        ioQueue.async { [weak self, snapshot] in
            self?.rewriteDisk(with: snapshot)
        }
    }

    private func removeDiskFile() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    private func appendToDiskSync(_ entry: ClipboardHistoryEntry) {
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
            AppLogger.warn(logger, "Clipboard history append failed: \(error.localizedDescription)")
        }
    }

    private func rewriteDisk(with entries: [ClipboardHistoryEntry]) {
        do {
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }

            var data = Data()
            for entry in entries {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLogger.warn(logger, "Clipboard history rewrite failed: \(error.localizedDescription)")
        }
    }

    private func loadEntriesFromDisk() -> [ClipboardHistoryEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var result: [ClipboardHistoryEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(ClipboardHistoryEntry.self, from: lineData) else {
                continue
            }
            result.append(entry)
        }
        return result
    }

    private func prunedSnapshot(_ entries: [ClipboardHistoryEntry], now: Date) -> [ClipboardHistoryEntry] {
        let cutoffDate = currentRetentionPreset.timeInterval.map { now.addingTimeInterval(-$0) }
        var snapshot = entries.filter { entry in
            guard let cutoffDate else { return true }
            return entry.capturedAt >= cutoffDate
        }

        snapshot.sort { $0.capturedAt > $1.capturedAt }
        snapshot = deduplicated(snapshot)

        if snapshot.count > maxEntries {
            snapshot = Array(snapshot.prefix(maxEntries))
        }

        if isDiskOverFileSizeCap {
            snapshot = entriesFittingFileBudget(snapshot, targetBytes: fileSizeCap / 2)
        }

        return snapshot
    }

    private func mergedSnapshot(
        loaded: [ClipboardHistoryEntry],
        current: [ClipboardHistoryEntry]
    ) -> [ClipboardHistoryEntry] {
        var snapshot = loaded
        let loadedSignatures = Set(loaded.map(\.signature))
        snapshot.append(contentsOf: current.filter { !loadedSignatures.contains($0.signature) })
        snapshot.sort { $0.capturedAt > $1.capturedAt }
        snapshot = deduplicated(snapshot)
        if snapshot.count > maxEntries {
            snapshot = Array(snapshot.prefix(maxEntries))
        }
        return snapshot
    }

    private func deduplicated(_ entries: [ClipboardHistoryEntry]) -> [ClipboardHistoryEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            seen.insert(entry.signature).inserted
        }
    }

    private func entriesFittingFileBudget(
        _ entries: [ClipboardHistoryEntry],
        targetBytes: Int
    ) -> [ClipboardHistoryEntry] {
        var result: [ClipboardHistoryEntry] = []
        var totalBytes = 0

        for entry in entries {
            guard let data = try? encoder.encode(entry) else { continue }
            let lineBytes = data.count + 1
            if !result.isEmpty && totalBytes + lineBytes > targetBytes {
                break
            }
            result.append(entry)
            totalBytes += lineBytes
        }

        return result
    }

    private var isDiskOverFileSizeCap: Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        return size > fileSizeCap
    }

    private var currentRetentionPreset: ClipboardHistoryRetentionPreset {
        ClipboardHistoryRetentionPreset(rawValue: Defaults[.clipboardHistoryRetention]) ?? .oneDay
    }

    private func previewForState(_ state: SavedPasteboardState) -> (title: String, subtitle: String?, systemImage: String) {
        let fileNames = extractFileNames(from: state)
        if !fileNames.isEmpty {
            if fileNames.count == 1, let name = fileNames.first {
                return ("Файл: \(name)", nil, "doc")
            }

            let subtitle = fileNames.prefix(3).joined(separator: ", ")
            return ("\(fileNames.count) \(pluralizedWord(count: fileNames.count, one: "файл", few: "файли", many: "файлів"))",
                    subtitle,
                    "doc.on.doc")
        }

        if let text = extractText(from: state) {
            return ("Текст", shorten(text, maxLength: 72), "text.alignleft")
        }

        if containsImageData(in: state) {
            return ("Зображення", nil, "photo")
        }

        return ("Інший вміст", "\(state.items.count) \(pluralizedWord(count: state.items.count, one: "елемент", few: "елементи", many: "елементів"))", "doc.on.clipboard")
    }

    private func extractFileNames(from state: SavedPasteboardState) -> [String] {
        var names: [String] = []

        for savedItem in state.items {
            if let data = savedItem.data[.fileURL],
               let raw = decodeString(from: data),
               let url = URL(string: raw), url.isFileURL {
                names.append(url.lastPathComponent)
                continue
            }

            if let data = savedItem.data[.URL],
               let raw = decodeString(from: data),
               let url = URL(string: raw), url.isFileURL {
                names.append(url.lastPathComponent)
                continue
            }

            let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            if let data = savedItem.data[fileNamesType],
               let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] {
                names.append(contentsOf: values.map { URL(fileURLWithPath: $0).lastPathComponent })
            }
        }

        return names
    }

    private func extractText(from state: SavedPasteboardState) -> String? {
        for savedItem in state.items {
            if let data = savedItem.data[.string],
               let text = decodeString(from: data),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalized(text)
            }

            if let data = savedItem.data[.rtf],
               let attributedString = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
               ) {
                let value = attributedString.string
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return normalized(value)
                }
            }

            if let data = savedItem.data[.html],
               let attributedString = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
               ) {
                let value = attributedString.string
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return normalized(value)
                }
            }
        }

        return nil
    }

    private func containsImageData(in state: SavedPasteboardState) -> Bool {
        for savedItem in state.items {
            if savedItem.types.contains(.png) || savedItem.types.contains(.tiff) {
                return true
            }

            if savedItem.types.contains(where: { $0.rawValue.contains("image") }) {
                return true
            }
        }
        return false
    }

    private func decodeString(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode)
    }

    private func normalized(_ text: String) -> String {
        let squashed = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return squashed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shorten(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }

    private func pluralizedWord(count: Int, one: String, few: String, many: String) -> String {
        let mod10 = count % 10
        let mod100 = count % 100

        if mod10 == 1 && mod100 != 11 {
            return one
        }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            return few
        }
        return many
    }
}
