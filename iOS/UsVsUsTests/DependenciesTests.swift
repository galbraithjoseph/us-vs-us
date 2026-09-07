import XCTest
@testable import UsVsUs

final class DependenciesTests: XCTestCase {
    @MainActor
    func testModelReadsAndWritesInjectedPersistenceAndCloudStatus() {
        let store = MemoryShellPersistence(showSetupHelp: false)
        let model = ShellModel(dependencies: AppDependencies(persistence: store, cloudStatus: { .unavailable }))
        XCTAssertFalse(model.showSetupHelp)
        XCTAssertEqual(model.cloudStatus, .unavailable)
        model.showSetupHelp = true
        XCTAssertTrue(store.showSetupHelp)
        XCTAssertTrue(ShellModel(dependencies: AppDependencies(persistence: store)).showSetupHelp)
    }

    @MainActor
    func testTimeAndIdentifiersAreInjectable() {
        let instant = Date(timeIntervalSince1970: 123)
        let identifier = UUID()
        let dependencies = AppDependencies(persistence: MemoryShellPersistence(), now: { instant }, makeUUID: { identifier })
        XCTAssertEqual(dependencies.now(), instant)
        XCTAssertEqual(dependencies.makeUUID(), identifier)
    }

    @MainActor
    func testFixtureLaunchesAreDeterministicAndIsolated() {
        let first = AppDependencies.forLaunch(arguments: ["--ui-testing"])
        first.persistence.showSetupHelp = false
        let second = AppDependencies.forLaunch(arguments: ["--ui-testing"])
        XCTAssertTrue(second.persistence.showSetupHelp)
        XCTAssertEqual(first.now(), second.now())
        XCTAssertEqual(first.makeUUID(), second.makeUUID())
        XCTAssertEqual(second.cloudStatus(), .unavailable)
        let seeded = AppDependencies.forLaunch(arguments: ["--ui-testing", "--fixture-help-hidden"])
        XCTAssertFalse(seeded.persistence.showSetupHelp)
        XCTAssertTrue(second.persistence.showSetupHelp)
    }

    @MainActor
    func testPreferencesSurviveRecreationInIsolatedSuite() throws {
        let name = "UsVsUsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(DefaultsShellPersistence(defaults: defaults).showSetupHelp)
        DefaultsShellPersistence(defaults: defaults).showSetupHelp = false
        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertFalse(DefaultsShellPersistence(defaults: reopened).showSetupHelp)
    }
}
