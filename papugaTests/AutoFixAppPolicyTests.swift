import XCTest
@testable import papuga

final class AutoFixAppPolicyTests: XCTestCase {
    func test_vscode_defaults_to_suggest_only() {
        XCTAssertEqual(
            AutoFixAppPolicyResolver.defaultPolicy(for: "com.microsoft.VSCode"),
            .suggestOnly
        )
    }

    func test_cursor_defaults_to_suggest_only() {
        XCTAssertEqual(
            AutoFixAppPolicyResolver.defaultPolicy(for: "com.todesktop.230313mzl4w4u92"),
            .suggestOnly
        )
    }

    func test_jetbrains_defaults_to_suggest_only() {
        XCTAssertEqual(
            AutoFixAppPolicyResolver.defaultPolicy(for: "com.jetbrains.intellij"),
            .suggestOnly
        )
    }

    func test_terminal_apps_default_to_disabled() {
        XCTAssertEqual(
            AutoFixAppPolicyResolver.defaultPolicy(for: "com.apple.Terminal"),
            .disabled
        )
        XCTAssertEqual(
            AutoFixAppPolicyResolver.defaultPolicy(for: "com.googlecode.iterm2"),
            .disabled
        )
    }

    func test_native_unknown_apps_default_to_auto_mutate() {
        XCTAssertEqual(
            AutoFixAppPolicyResolver.defaultPolicy(for: "com.apple.Notes"),
            .autoMutate
        )
    }
}
