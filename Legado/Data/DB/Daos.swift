import Foundation
import GRDB

// MARK: - 书源

struct BookSourceDao {
    let db: AppDatabase

    func all() -> [BookSource] {
        (try? db.dbQueue.read { try BookSource
            .order(Column("customOrder"), Column("bookSourceName"))
            .fetchAll($0) }) ?? []
    }

    func enabledSources() -> [BookSource] {
        (try? db.dbQueue.read { try BookSource
            .filter(Column("enabled") == true)
            .order(Column("customOrder"), Column("bookSourceName"))
            .fetchAll($0) }) ?? []
    }

    func get(_ key: String) -> BookSource? {
        try? db.dbQueue.read { try BookSource.fetchOne($0, key: key) }
    }

    @discardableResult
    func save(_ source: BookSource) -> Bool {
        do {
            try db.dbQueue.write { try source.save($0) }
            return true
        } catch {
            DebugLog.shared.log("DB", "保存书源失败 \(source.bookSourceName): \(error)")
            return false
        }
    }

    @discardableResult
    func saveAll(_ sources: [BookSource]) -> Int {
        var count = 0
        try? db.dbQueue.write { database in
            for source in sources {
                if (try? source.save(database)) != nil { count += 1 }
            }
        }
        return count
    }

    func delete(_ key: String) {
        _ = try? db.dbQueue.write { try BookSource.deleteOne($0, key: key) }
    }

    func deleteAll() {
        _ = try? db.dbQueue.write { try BookSource.deleteAll($0) }
    }

    func groups() -> [String] {
        var set = Set<String>()
        for source in all() {
            guard let group = source.bookSourceGroup else { continue }
            for g in group.splitNotBlank("[,;，；]") { set.insert(g) }
        }
        return set.sorted()
    }

    func count() -> Int {
        (try? db.dbQueue.read { try BookSource.fetchCount($0) }) ?? 0
    }
}

// MARK: - 书籍

struct BookDao {
    let db: AppDatabase

    func all() -> [Book] {
        (try? db.dbQueue.read { try Book
            .order(Column("durChapterTime").desc)
            .fetchAll($0) }) ?? []
    }

    func inGroup(_ groupId: Int64) -> [Book] {
        (try? db.dbQueue.read { try Book
            .filter(Column("group") == groupId)
            .order(Column("durChapterTime").desc)
            .fetchAll($0) }) ?? []
    }

    func get(_ bookUrl: String) -> Book? {
        try? db.dbQueue.read { try Book.fetchOne($0, key: bookUrl) }
    }

    func exists(_ bookUrl: String) -> Bool {
        (try? db.dbQueue.read { try Book.filter(key: bookUrl).fetchCount($0) }) ?? 0 > 0
    }

    func save(_ book: Book) {
        _ = try? db.dbQueue.write { try book.save($0) }
    }

    func delete(_ bookUrl: String) {
        _ = try? db.dbQueue.write { try Book.deleteOne($0, key: bookUrl) }
    }

    func updateReadingProgress(bookUrl: String, chapterIndex: Int, chapterTitle: String,
                               chapterPos: Int = 0) {
        _ = try? db.dbQueue.write { database in
            try database.execute(
                sql: """
                UPDATE books SET durChapterIndex = ?, durChapterTitle = ?, durChapterPos = ?,
                durChapterTime = ? WHERE bookUrl = ?
                """,
                arguments: [chapterIndex, chapterTitle, chapterPos,
                            Int64(Date().timeIntervalSince1970 * 1000), bookUrl]
            )
        }
    }
}

// MARK: - 章节

struct BookChapterDao {
    let db: AppDatabase

    func chapters(of bookUrl: String) -> [BookChapter] {
        (try? db.dbQueue.read { try BookChapter
            .filter(Column("bookUrl") == bookUrl)
            .order(Column("index"))
            .fetchAll($0) }) ?? []
    }

    func chapter(bookUrl: String, index: Int) -> BookChapter? {
        try? db.dbQueue.read {
            try BookChapter
                .filter(Column("bookUrl") == bookUrl && Column("index") == index)
                .fetchOne($0)
        }
    }

    func chapter(bookUrl: String, url: String) -> BookChapter? {
        try? db.dbQueue.read {
            try BookChapter
                .filter(Column("bookUrl") == bookUrl && Column("url") == url)
                .fetchOne($0)
        }
    }

    /// 对齐上游 `insertOrReplaceChapterList`：整表替换该书的目录
    func replaceChapters(_ chapters: [BookChapter], of bookUrl: String) {
        _ = try? db.dbQueue.write { database in
            try BookChapter.filter(Column("bookUrl") == bookUrl).deleteAll(database)
            for chapter in chapters {
                try chapter.insert(database)
            }
        }
    }

    func save(_ chapter: BookChapter) {
        _ = try? db.dbQueue.write { try chapter.save($0) }
    }

    func count(of bookUrl: String) -> Int {
        (try? db.dbQueue.read {
            try BookChapter.filter(Column("bookUrl") == bookUrl).fetchCount($0)
        }) ?? 0
    }
}

// MARK: - Cookie

struct CookieDao {
    let db: AppDatabase

    func get(_ domain: String) -> Cookie? {
        try? db.dbQueue.read { try Cookie.fetchOne($0, key: domain) }
    }

    func all() -> [Cookie] {
        (try? db.dbQueue.read { try Cookie.fetchAll($0) }) ?? []
    }

    func insert(_ cookie: Cookie) {
        _ = try? db.dbQueue.write { try cookie.save($0) }
    }

    func delete(_ domain: String) {
        _ = try? db.dbQueue.write { try Cookie.deleteOne($0, key: domain) }
    }

    func deleteAll() {
        _ = try? db.dbQueue.write { try Cookie.deleteAll($0) }
    }
}

// MARK: - 阅读记录

struct ReadRecordDao {
    let db: AppDatabase

    func recent(limit: Int = 20) -> [ReadRecord] {
        (try? db.dbQueue.read { try ReadRecord
            .order(Column("lastRead").desc)
            .limit(limit)
            .fetchAll($0) }) ?? []
    }

    func save(_ record: ReadRecord) {
        _ = try? db.dbQueue.write { try record.save($0) }
    }

    func delete(_ bookName: String) {
        _ = try? db.dbQueue.write { try ReadRecord.deleteOne($0, key: bookName) }
    }
}

// MARK: - 分组

struct BookGroupDao {
    let db: AppDatabase

    func all() -> [BookGroup] {
        (try? db.dbQueue.read { try BookGroup.order(Column("order")).fetchAll($0) }) ?? []
    }

    func save(_ group: BookGroup) {
        _ = try? db.dbQueue.write { try group.save($0) }
    }

    func delete(_ groupId: Int64) {
        _ = try? db.dbQueue.write { try BookGroup.deleteOne($0, key: groupId) }
    }
}
