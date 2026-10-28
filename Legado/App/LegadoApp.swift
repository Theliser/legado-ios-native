import SwiftUI

@main
struct LegadoApp: App {
    @State private var container = AppContainer.live()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if DebugLaunch.readSourcesPath != nil {
                    DebugReaderHost(container: container)
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environment(container)
            .tint(Theme.accent)
        }
    }
}
