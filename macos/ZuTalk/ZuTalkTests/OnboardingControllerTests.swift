import XCTest
@testable import ZuTalk

@MainActor
final class OnboardingControllerTests: XCTestCase {
    // Under test the standard domain is the installed app's real
    // preferences, so "onboarding is done" is kept in a suite of this
    // test's own and thrown away afterwards.
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "OnboardingControllerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeController() -> OnboardingController {
        OnboardingController(defaults: defaults, openSystemSettings: { _ in })
    }

    func testCompletedOnboardingDoesNotReappearWhenPermissionNeedsRenewal() {
        XCTAssertTrue(OnboardingController.shouldShowOnboarding(defaults: defaults))
        defaults.set(true, forKey: OnboardingController.completedKey)
        XCTAssertFalse(OnboardingController.shouldShowOnboarding(defaults: defaults))
    }

    func testInitialPhaseIsWelcome() {
        let controller = makeController()
        XCTAssertEqual(controller.phase, .welcome)
    }

    func testGoToLiveTextAdvancesPhase() {
        let controller = makeController()
        controller.goToLiveText()
        XCTAssertEqual(controller.phase, .liveText)
    }

    func testGoToPermissionsAdvancesPhase() {
        let controller = makeController()
        controller.goToPermissions()
        XCTAssertEqual(controller.phase, .permissions)
    }

    func testFinishDoesNotCollectOrPersistProviderCredentials() {
        let controller = makeController()

        controller.finish()

        XCTAssertEqual(controller.phase, .finished)
        XCTAssertTrue(defaults.bool(forKey: OnboardingController.completedKey))
        // Only the one flag is remembered.
        XCTAssertEqual(
            Array((defaults.persistentDomain(forName: suiteName) ?? [:]).keys),
            [OnboardingController.completedKey]
        )
    }

    /// Welcome, what live text needs, the microphone, done. The second step
    /// is no longer "paste a Soniox key": an invite code is what most people
    /// actually have.
    func testOnboardingPhasesAreWelcomeLiveTextMicrophoneDone() {
        XCTAssertEqual(
            OnboardingController.Phase.allCases,
            [.welcome, .liveText, .permissions, .finished]
        )
        XCTAssertEqual(OnboardingController.Phase.allCases.map(\.stepIndex), [0, 1, 2, 3])
    }

    func testHelpCanPresentOnboardingAgain() {
        let store = MainNavigationStore()
        store.completeOnboarding()

        store.presentOnboarding()

        XCTAssertTrue(store.needsOnboarding)
    }
}
