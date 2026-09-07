import Foundation

/// Shell preferences only. Replicated business data will use the Core Data layer.
@MainActor
protocol ShellPersistence: AnyObject {
    var showSetupHelp: Bool { get set }
}

@MainActor
final class DefaultsShellPersistence: ShellPersistence {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var showSetupHelp: Bool {
        get { defaults.object(forKey: "showSetupHelp") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showSetupHelp") }
    }
}

@MainActor
final class MemoryShellPersistence: ShellPersistence {
    var showSetupHelp: Bool
    init(showSetupHelp: Bool = true) { self.showSetupHelp = showSetupHelp }
}

enum CloudStatus: String {
    case notConfigured = "Cloud sharing is not set up yet."
    case unavailable = "iCloud is unavailable. You can still use this device."
}

@MainActor
struct AppDependencies {
    let persistence: any ShellPersistence
    var now: () -> Date = Date.init
    var makeUUID: () -> UUID = UUID.init
    var cloudStatus: () -> CloudStatus = { .notConfigured }

    static func live() -> Self { Self(persistence: DefaultsShellPersistence()) }

    static func forLaunch(arguments: [String]) -> Self {
        #if DEBUG
        if arguments.contains("--ui-testing") {
            // A fresh in-memory store on EVERY launch: no production data is read,
            // written, or deleted, and parallel runs never share a fixture store.
            return Self(
                persistence: MemoryShellPersistence(showSetupHelp: !arguments.contains("--fixture-help-hidden")),
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! },
                cloudStatus: { .unavailable }
            )
        }
        #endif
        return .live()
    }
}
