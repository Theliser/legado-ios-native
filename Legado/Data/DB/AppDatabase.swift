import Foundation
import GRDB

/// 本地数据库。表结构对齐上游 Room（表名、列名一致），方便将来做备份互通。
final class AppDatabase {

    let dbQueue: DatabaseQueue

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    /// 内存库（测试用）
    init(inMemory: Bool) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(configuration: config)
        try migrator.migrate(dbQueue)
    }

    static func defaultPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("legado.db").path
    }

    static func makeShared() -> AppDatabase {
        do {
            return try AppDatabase(path: defaultPath())
        } catch {
            DebugLog.shared.log("DB", "数据库初始化失败，降级到内存库: \(error)")
            // swiftlint:disable:next force_try
            return try! AppDatabase(inMemory: true)
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: Self.bookSourcesDDL)
            try db.execute(sql: Self.booksDDL)
            try db.execute(sql: Self.chaptersDDL)
            try db.execute(sql: Self.cookiesDDL)
            try db.execute(sql: Self.bookGroupsDDL)
            try db.execute(sql: Self.readRecordsDDL)
            try db.execute(sql: Self.searchBooksDDL)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS index_book_sources_bookSourceUrl ON book_sources(bookSourceUrl)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS index_books_name_author ON books(name, author)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS index_books_durChapterTime ON books(durChapterTime)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS index_chapters_bookUrl ON chapters(bookUrl)")
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS index_chapters_bookUrl_index ON chapters(bookUrl, \"index\")")
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS index_cookies_url ON cookies(url)")
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS index_searchBooks_bookUrl ON searchBooks(bookUrl)")
        }
        return migrator
    }

    // MARK: - DDL

    private static let bookSourcesDDL = """
    CREATE TABLE IF NOT EXISTS book_sources (
        bookSourceUrl TEXT PRIMARY KEY NOT NULL,
        bookSourceName TEXT NOT NULL DEFAULT '',
        bookSourceGroup TEXT,
        bookSourceType INTEGER NOT NULL DEFAULT 0,
        bookUrlPattern TEXT,
        customOrder INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        enabledExplore INTEGER NOT NULL DEFAULT 1,
        jsLib TEXT,
        enabledCookieJar INTEGER,
        concurrentRate TEXT,
        header TEXT,
        loginUrl TEXT,
        loginUi TEXT,
        loginCheckJs TEXT,
        coverDecodeJs TEXT,
        bookSourceComment TEXT,
        variableComment TEXT,
        lastUpdateTime INTEGER NOT NULL DEFAULT 0,
        respondTime INTEGER NOT NULL DEFAULT 180000,
        weight INTEGER NOT NULL DEFAULT 0,
        exploreUrl TEXT,
        exploreScreen TEXT,
        ruleExplore TEXT,
        searchUrl TEXT,
        ruleSearch TEXT,
        ruleBookInfo TEXT,
        ruleToc TEXT,
        ruleContent TEXT,
        ruleReview TEXT,
        eventListener INTEGER NOT NULL DEFAULT 0,
        customButton INTEGER NOT NULL DEFAULT 0,
        homepageModules TEXT
    )
    """

    private static let booksDDL = """
    CREATE TABLE IF NOT EXISTS books (
        bookUrl TEXT PRIMARY KEY NOT NULL,
        tocUrl TEXT NOT NULL DEFAULT '',
        origin TEXT NOT NULL DEFAULT 'loc_book',
        originName TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        kind TEXT,
        customTag TEXT,
        coverUrl TEXT,
        customCoverUrl TEXT,
        intro TEXT,
        customIntro TEXT,
        remark TEXT,
        charset TEXT,
        type INTEGER NOT NULL DEFAULT 0,
        "group" INTEGER NOT NULL DEFAULT 0,
        isPrivate INTEGER NOT NULL DEFAULT 0,
        latestChapterTitle TEXT,
        latestChapterTime INTEGER NOT NULL DEFAULT 0,
        lastCheckTime INTEGER NOT NULL DEFAULT 0,
        lastCheckCount INTEGER NOT NULL DEFAULT 0,
        totalChapterNum INTEGER NOT NULL DEFAULT 0,
        durChapterTitle TEXT,
        durChapterIndex INTEGER NOT NULL DEFAULT 0,
        durChapterPos INTEGER NOT NULL DEFAULT 0,
        durChapterTime INTEGER NOT NULL DEFAULT 0,
        wordCount TEXT,
        canUpdate INTEGER NOT NULL DEFAULT 1,
        disableReadRecord INTEGER NOT NULL DEFAULT 0,
        "order" INTEGER NOT NULL DEFAULT 0,
        originOrder INTEGER NOT NULL DEFAULT 0,
        variable TEXT,
        readConfig TEXT,
        syncTime INTEGER NOT NULL DEFAULT 0,
        listIntro TEXT
    )
    """

    private static let chaptersDDL = """
    CREATE TABLE IF NOT EXISTS chapters (
        url TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        isVolume INTEGER NOT NULL DEFAULT 0,
        tocLevel INTEGER NOT NULL DEFAULT 0,
        baseUrl TEXT NOT NULL DEFAULT '',
        bookUrl TEXT NOT NULL DEFAULT '',
        "index" INTEGER NOT NULL DEFAULT 0,
        isVip INTEGER NOT NULL DEFAULT 0,
        isPay INTEGER NOT NULL DEFAULT 0,
        resourceUrl TEXT,
        tag TEXT,
        wordCount TEXT,
        start INTEGER,
        end INTEGER,
        startFragmentId TEXT,
        endFragmentId TEXT,
        variable TEXT,
        reviewImg TEXT,
        PRIMARY KEY (url, bookUrl),
        FOREIGN KEY (bookUrl) REFERENCES books(bookUrl) ON DELETE CASCADE
    )
    """

    private static let cookiesDDL = """
    CREATE TABLE IF NOT EXISTS cookies (
        url TEXT PRIMARY KEY NOT NULL,
        cookie TEXT NOT NULL DEFAULT ''
    )
    """

    private static let bookGroupsDDL = """
    CREATE TABLE IF NOT EXISTS book_groups (
        groupId INTEGER PRIMARY KEY NOT NULL,
        groupName TEXT NOT NULL DEFAULT '',
        "order" INTEGER NOT NULL DEFAULT 0,
        enableRefresh INTEGER NOT NULL DEFAULT 1,
        show INTEGER NOT NULL DEFAULT 1
    )
    """

    private static let readRecordsDDL = """
    CREATE TABLE IF NOT EXISTS readRecords (
        bookName TEXT PRIMARY KEY NOT NULL,
        readTime INTEGER NOT NULL DEFAULT 0,
        lastRead INTEGER NOT NULL DEFAULT 0
    )
    """

    private static let searchBooksDDL = """
    CREATE TABLE IF NOT EXISTS searchBooks (
        bookUrl TEXT PRIMARY KEY NOT NULL,
        origin TEXT NOT NULL DEFAULT '',
        originName TEXT NOT NULL DEFAULT '',
        type INTEGER NOT NULL DEFAULT 0,
        name TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        kind TEXT,
        coverUrl TEXT,
        intro TEXT,
        wordCount TEXT,
        latestChapterTitle TEXT,
        tocUrl TEXT NOT NULL DEFAULT '',
        time INTEGER NOT NULL DEFAULT 0,
        variable TEXT,
        originOrder INTEGER NOT NULL DEFAULT 0,
        chapterWordCountText TEXT,
        chapterWordCount INTEGER NOT NULL DEFAULT -1,
        respondTime INTEGER NOT NULL DEFAULT -1
    )
    """
}

// MARK: - GRDB 记录

extension BookSource: FetchableRecord, PersistableRecord {}
extension Book: FetchableRecord, PersistableRecord {}
extension BookChapter: FetchableRecord, PersistableRecord {}
extension SearchBook: FetchableRecord, PersistableRecord {}
extension Cookie: FetchableRecord, PersistableRecord {}
extension BookGroup: FetchableRecord, PersistableRecord {}
extension ReadRecord: FetchableRecord, PersistableRecord {}
