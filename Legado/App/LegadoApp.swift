import SwiftUI

@main
struct LegadoApp: App {
    @State private var container = AppContainer.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .tint(Theme.accent)
        }
    }
}
