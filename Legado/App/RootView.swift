import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container
    @State private var selection: AppTab = {
        #if DEBUG
        return DebugLaunch.initialTab ?? .shelf
        #else
        return .shelf
        #endif
    }()

    var body: some View {
        TabView(selection: $selection) {
            Tab("书架", systemImage: "books.vertical", value: AppTab.shelf) {
                BookshelfView()
            }
            Tab("发现", systemImage: "safari", value: AppTab.explore) {
                SearchView()
            }
            Tab("书源", systemImage: "square.stack.3d.up", value: AppTab.sources) {
                BookSourceListView()
            }
            Tab("我的", systemImage: "person.crop.circle", value: AppTab.profile) {
                SettingsView()
            }
        }
    }
}

enum AppTab: Hashable {
    case shelf, explore, sources, profile
}
