import Observation

@MainActor
@Observable
final class ShellModel {
    private let dependencies: AppDependencies
    var showSetupHelp: Bool {
        didSet { dependencies.persistence.showSetupHelp = showSetupHelp }
    }
    var cloudStatus: CloudStatus { dependencies.cloudStatus() }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        showSetupHelp = dependencies.persistence.showSetupHelp
    }
}
