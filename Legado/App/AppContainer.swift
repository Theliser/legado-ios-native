import Foundation
import SwiftUI

/// 依赖容器（轻量 DI）：显式构造、只注入真正需要的服务，避免全局单例四处散落。
@Observable
final class AppContainer {
    let database: AppDatabase
    let settings: AppSettings
    let bookSourceRepository: BookSourceRepository
    let bookRepository: BookRepository
    let bookGroupRepository: BookGroupRepository
    let cookieStore: CookieStore
    let httpClient: HTTPClient
    let webBook: WebBook

    init(database: AppDatabase, settings: AppSettings = AppSettings()) {
        self.database = database
        self.settings = settings
        self.bookSourceRepository = BookSourceRepository(db: database)
        self.bookRepository = BookRepository(db: database)
        self.bookGroupRepository = BookGroupRepository(db: database)
        let cookieDao = CookieDao(db: database)
        self.cookieStore = CookieStore(dao: cookieDao)
        self.httpClient = HTTPClient(settings: settings, cookieStore: cookieStore)
        self.webBook = WebBook(settings: settings,
                               httpClient: httpClient,
                               cookieStore: cookieStore,
                               bookRepository: bookRepository)
        JSRuntime.shared.configure(cookieStore: cookieStore)
        bookGroupRepository.ensureDefaultGroups()
    }

    static func live() -> AppContainer {
        let container = AppContainer(database: AppDatabase.makeShared())
        #if DEBUG
        DebugLaunch.importSources(into: container)
        #endif
        return container
    }
}
