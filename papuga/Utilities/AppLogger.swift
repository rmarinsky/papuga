import Foundation
import OSLog

enum AppLogger {
    static let lifecycle = Logger(subsystem: Constants.bundleIdentifier, category: "Lifecycle")
    static let hotkey = Logger(subsystem: Constants.bundleIdentifier, category: "Hotkey")
    static let switchEngine = Logger(subsystem: Constants.bundleIdentifier, category: "SwitchEngine")
    static let clipboard = Logger(subsystem: Constants.bundleIdentifier, category: "Clipboard")
    static let layout = Logger(subsystem: Constants.bundleIdentifier, category: "Layout")
    static let mapper = Logger(subsystem: Constants.bundleIdentifier, category: "Mapper")
    static let ui = Logger(subsystem: Constants.bundleIdentifier, category: "UI")
    static let autoFix = Logger(subsystem: Constants.bundleIdentifier, category: "AutoFix")
    static let analytics = Logger(subsystem: Constants.bundleIdentifier, category: "Analytics")

    static func pre(_ logger: Logger, _ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func action(_ logger: Logger, _ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func post(_ logger: Logger, _ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func warn(_ logger: Logger, _ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ logger: Logger, _ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
