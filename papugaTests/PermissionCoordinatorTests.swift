import XCTest
@testable import papuga

@MainActor
final class PermissionCoordinatorTests: XCTestCase {
    private final class FakePermissionClient: PermissionClient {
        var granted = false
        var requestResult = false
        var openResult: PermissionSettingsOpenResult = .permissionPane
        var requestCount = 0
        var openCount = 0
        var generalPrivacyPreferences: [Bool] = []

        func isGranted(_ type: PermissionType) -> Bool {
            granted
        }

        func request(_ type: PermissionType) -> Bool {
            requestCount += 1
            if requestResult { granted = true }
            return requestResult
        }

        func openSettings(
            _ type: PermissionType,
            preferGeneralPrivacy: Bool
        ) -> PermissionSettingsOpenResult {
            openCount += 1
            generalPrivacyPreferences.append(preferGeneralPrivacy)
            return openResult
        }
    }

    func test_preflightGrantedDoesNotRequestOrOpenSettings() {
        let client = FakePermissionClient()
        client.granted = true
        let coordinator = PermissionCoordinator(permission: .inputMonitoring, client: client)

        coordinator.performPrimaryAction()

        XCTAssertTrue(coordinator.isGranted)
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertEqual(client.openCount, 0)
    }

    func test_failedInputMonitoringRequestRechecksThenOpensCorrectSettingsPane() {
        let client = FakePermissionClient()
        let coordinator = PermissionCoordinator(permission: .inputMonitoring, client: client)

        coordinator.performPrimaryAction()

        XCTAssertFalse(coordinator.isGranted)
        XCTAssertTrue(coordinator.hasAttemptedRequest)
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(client.openCount, 1)
        XCTAssertEqual(client.generalPrivacyPreferences, [false])
        XCTAssertEqual(coordinator.primaryButtonTitle, "Відкрити «Моніторинг введення»")
        XCTAssertTrue(coordinator.showsManualPath)
    }

    func test_secondSettingsAttemptFallsBackToGeneralPrivacy() {
        let client = FakePermissionClient()
        let coordinator = PermissionCoordinator(permission: .inputMonitoring, client: client)

        coordinator.performPrimaryAction()
        coordinator.performPrimaryAction()

        XCTAssertEqual(client.generalPrivacyPreferences, [false, true])
    }

    func test_generalPrivacyFallbackShowsManualPath() {
        let client = FakePermissionClient()
        client.openResult = .privacyAndSecurity
        let coordinator = PermissionCoordinator(permission: .inputMonitoring, client: client)

        coordinator.performPrimaryAction()

        XCTAssertTrue(coordinator.showsManualPath)
        XCTAssertEqual(
            coordinator.manualPath,
            "Системні параметри → Приватність і безпека → Моніторинг введення"
        )
    }

    func test_refreshAfterReturningFromSettingsTransitionsToGranted() {
        let client = FakePermissionClient()
        let coordinator = PermissionCoordinator(permission: .inputMonitoring, client: client)
        coordinator.performPrimaryAction()
        client.granted = true

        coordinator.refresh()

        XCTAssertTrue(coordinator.isGranted)
    }

    func test_setupCanCompleteOnlyWhenBothRequiredPermissionsAreGranted() {
        XCTAssertFalse(PermissionCompletionPolicy.canComplete(
            PermissionManager.PermissionStatus(accessibility: true, inputMonitoring: false)
        ))
        XCTAssertTrue(PermissionCompletionPolicy.canComplete(
            PermissionManager.PermissionStatus(accessibility: true, inputMonitoring: true)
        ))
    }
}
