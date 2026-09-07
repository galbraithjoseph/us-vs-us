import SwiftUI

@main
struct UsVsUsApp: App {
    @State private var model = ShellModel(
        dependencies: .forLaunch(arguments: ProcessInfo.processInfo.arguments)
    )

    var body: some Scene {
        WindowGroup { ShellView(model: model) }
    }
}

struct ShellView: View {
    @Bindable var model: ShellModel

    var body: some View {
        TabView {
            NavigationStack {
                ContentUnavailableView {
                    Label("Set up your pair", systemImage: "person.2")
                } description: {
                    if model.showSetupHelp {
                        Text("Track the games you play together.")
                            .accessibilityIdentifier("setupHelp")
                    }
                }
                .navigationTitle("Us vs Us")
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                Form {
                    Section("On this device") {
                        Text(model.cloudStatus.rawValue)
                        Toggle("Show setup help", isOn: $model.showSetupHelp)
                            .accessibilityIdentifier("showSetupHelp")
                    }
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
