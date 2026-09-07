import SwiftUI

@main
struct UsVsUsApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentUnavailableView("Set up your pair", systemImage: "person.2", description: Text("Track the games you play together."))
                    .navigationTitle("Us vs Us")
            }
        }
    }
}
