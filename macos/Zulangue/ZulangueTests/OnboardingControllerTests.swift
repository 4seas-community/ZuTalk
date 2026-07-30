import XCTest
@testable import Zulangue

@MainActor
final class OnboardingControllerTests: XCTestCase {
    private var originalOnboardingCompleted: Any?

    override func setUp() async throws {
        try await super.setUp()
        originalOnboardingCompleted = UserDefaults.standard.object(
            forKey: "zulangue.onboarding.completed"
        )
        UserDefaults.standard.removeObject(forKey: "zulangue.onboarding.completed")
    }

    override func tearDown() async throws {
        if let originalOnboardingCompleted {
            UserDefaults.standard.set(
                originalOnboardingCompleted,
                forKey: "zulangue.onboarding.completed"
            )
        } else {
            UserDefaults.standard.removeObject(forKey: "zulangue.onboarding.completed")
        }
        try await super.tearDown()
    }

    func testCompletedOnboardingDoesNotReappearWhenPermissionNeedsRenewal() {
        UserDefaults.standard.set(true, forKey: "zulangue.onboarding.completed")
        XCTAssertFalse(OnboardingController.shouldShowOnboarding)
    }

    func testInitialPhaseIsWelcome() {
        let controller = OnboardingController()
        XCTAssertEqual(controller.phase, .welcome)
    }

    func testGoToCredentialAdvancesPhase() {
        let controller = OnboardingController()
        controller.goToCredential()
        XCTAssertEqual(controller.phase, .credential)
    }

    func testGoToPermissionsAdvancesPhase() {
        let controller = OnboardingController()
        controller.goToPermissions()
        XCTAssertEqual(controller.phase, .permissions)
    }

    func testFinishDoesNotCollectOrPersistProviderCredentials() {
        let controller = OnboardingController()

        controller.finish()

        XCTAssertEqual(controller.phase, .finished)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "zulangue.onboarding.completed"))
    }

    func testOnboardingIncludesSonioxCredentialPhase() {
        XCTAssertEqual(
            OnboardingController.Phase.allCases,
            [.welcome, .credential, .permissions, .finished]
        )
    }

    func testHelpCanPresentOnboardingAgain() {
        let store = MainNavigationStoreV2()
        store.completeOnboarding()

        store.presentOnboarding()

        XCTAssertTrue(store.needsOnboarding)
    }
}
