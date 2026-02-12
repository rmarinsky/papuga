import AppKit
import Foundation

@Observable
final class ClipboardHistoryManager {
    var entries: [ClipboardHistoryEntry] = []

    private let clipboardManager = ClipboardManager()
    private let pasteboard = NSPasteboard.general
    private let logger = AppLogger.clipboard

    private var monitorTimer: Timer?
    private var lastObservedChangeCount: Int
    private var suspensionCount = 0

    private let maxEntries: Int
    private let pollInterval: TimeInterval

    init(maxEntries: Int = 30, pollInterval: TimeInterval = 0.35) {
        self.maxEntries = maxEntries
        self.pollInterval = pollInterval
        self.lastObservedChangeCount = NSPasteboard.general.changeCount
        AppLogger.post(logger, "ClipboardHistoryManager initialized: maxEntries=\(maxEntries), pollInterval=\(pollInterval)")
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        AppLogger.pre(logger, "ClipboardHistoryManager.startMonitoring()")
        guard monitorTimer == nil else {
            AppLogger.warn(logger, "ClipboardHistoryManager.startMonitoring() ignored: already running")
            return
        }

        lastObservedChangeCount = pasteboard.changeCount
        captureCurrentStateIfNeeded(force: true)

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.captureCurrentStateIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
        AppLogger.post(logger, "Clipboard history monitoring started")
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

    private func captureCurrentStateIfNeeded(force: Bool = false) {
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

        let signature = signatureForState(state)
        if entries.first?.signature == signature {
            return
        }

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
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        AppLogger.post(logger, "Clipboard history captured: entries=\(entries.count), title=\(entry.title)")
    }

    private func promoteEntryToTop(entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        guard index != 0 else { return }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
    }

    private func signatureForState(_ state: SavedPasteboardState) -> Int {
        var hasher = Hasher()
        hasher.combine(state.items.count)

        for item in state.items {
            let sortedTypes = item.types.sorted { $0.rawValue < $1.rawValue }
            hasher.combine(sortedTypes.count)

            for type in sortedTypes {
                hasher.combine(type.rawValue)
                guard let data = item.data[type] else {
                    hasher.combine(0)
                    continue
                }

                hasher.combine(data.count)
                hasher.combine(Data(data.prefix(128)))
                if data.count > 128 {
                    hasher.combine(Data(data.suffix(64)))
                }
            }
        }

        return hasher.finalize()
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
