import AppKit
import XCTest
@testable import papuga

final class ClipboardHistoryPersistenceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("papuga-clipboard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func test_refreshPersistsClipboardEntryAndBootstrapLoadsIt() {
        let originalClipboard = ClipboardManager().save()
        defer { ClipboardManager().restore(originalClipboard) }

        let fileURL = tempDirectory.appendingPathComponent("clipboard-history.jsonl")
        let manager = ClipboardHistoryManager(maxEntries: 10, pollInterval: 60, fileURL: fileURL)
        waitForBootstrap(manager)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("persistent copy", forType: .string)

        manager.refreshNow()
        XCTAssertTrue(waitForFile(at: fileURL))
        manager.stopMonitoring()

        let reloaded = ClipboardHistoryManager(maxEntries: 10, pollInterval: 60, fileURL: fileURL)
        waitForBootstrap(reloaded)

        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.title, "Текст")
        XCTAssertEqual(reloaded.entries.first?.subtitle, "persistent copy")
        XCTAssertEqual(reloaded.entries.first?.state.items.first?.data[.string].flatMap {
            String(data: $0, encoding: .utf8)
        }, "persistent copy")
    }

    func test_signatureIsStableForSamePasteboardContent() {
        let state = SavedPasteboardState(
            items: [
                SavedPasteboardState.Item(
                    types: [.string, .html],
                    data: [
                        .string: Data("hello".utf8),
                        .html: Data("<b>hello</b>".utf8)
                    ]
                )
            ],
            changeCount: 1
        )
        let sameContentDifferentOrder = SavedPasteboardState(
            items: [
                SavedPasteboardState.Item(
                    types: [.html, .string],
                    data: [
                        .html: Data("<b>hello</b>".utf8),
                        .string: Data("hello".utf8)
                    ]
                )
            ],
            changeCount: 99
        )

        XCTAssertEqual(
            ClipboardHistorySignature.make(for: state),
            ClipboardHistorySignature.make(for: sameContentDifferentOrder)
        )
    }

    private func waitForBootstrap(_ manager: ClipboardHistoryManager) {
        let expectation = expectation(description: "Clipboard history bootstrap")
        manager.bootstrap {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    private func waitForFile(at fileURL: URL) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
