import Foundation
import GRDB

/// 写库统一入口：失败时记日志。
/// 之前到处用 `try?` 把错误吞掉了，schema/约束问题会变成「静默丢数据」。
private func dbWrite(_ db: AppDatabase, _ label: String, _ body: (Database) throws -> Void) {
    do {
        try db.dbQueue.write(body)
    } catch {
        DebugLog.shared.log("DB", "\(label) 失败: \(error)")
    }
}

// MARK: - 书源

struct BookSourceDao {
    let db: AppDatabase

    private static let orderClause = "order by customOrder asc, bookSourceName asc"

    func all() -> [BookSource] {
        (try? db.dbQueue.read {
            try BookSource.fetchAll($0, sql: "select * from book_sources \(Self.orderClause)")
        }) ?? []
    }

    /// 对齐上游 `search`：名称/分组/地址/注释四路模糊匹配
    func search(_ key: String) -> [BookSource] {
        guard !key.isBlank else { return all() }
        let like = "%\(key)%"
        return (try? db.dbQueue.read {
            try BookSource.fetchAll($0, sql: """
                select * from book_sources
                where bookSourceName like ?
                   or bookSourceGroup like ?
                   or bookSourceUrl like ?
                   or bookSourceComment like ?
                \(Self.orderClause)
                """, arguments: [like, like, like, like])
        }) ?? []
    }

    func enabledSources() -> [BookSource] {
        (try? db.dbQueue.read {
            try BookSource.fetchAll($0, sql: """
                select * from book_sources where enabled = 1 \(Self.orderClause)
                """)
        }) ?? []
    }

    /// 上游 `getByGroup`：宽松匹配（分组串里含该词即可）
    func byGroup(_ group: String) -> [BookSource] {
        (try? db.dbQueue.read {
            try BookSource.fetchAll($0, sql: """
                select * from book_sources
                where bookSourceGroup like ? \(Self.orderClause)
                """, arguments: ["%\(group)%"])
        }) ?? []
    }

    /// 上游 `getEnabledByGroup`：按逗号分组的**整词**匹配，避免 "玄幻" 命中 "玄幻言情"
    func enabledByGroup(_ group: String) -> [BookSource] {
        (try? db.dbQueue.read {
            try BookSource.fetchAll($0, sql: """
                select * from book_sources
                where enabled = 1
                  and (bookSourceGroup = ?
                    or bookSourceGroup like ? || ',%'
                    or bookSourceGroup like '%,' || ?
                    or bookSourceGroup like '%,' || ? || ',%')
                \(Self.orderClause)
                """, arguments: [group, group, group, group])
        }) ?? []
    }

    /// 上游 `flowNoGroup`：空分组或「未分组」
    func noGroup() -> [BookSource] {
        (try? db.dbQueue.read {
            try BookSource.fetchAll($0, sql: """
                select * from book_sources
                where bookSourceGroup is null
                   or bookSourceGroup = ''
                   or bookSourceGroup like '%未分组%'
                \(Self.orderClause)
                """)
        }) ?? []
    }

    /// 可用于「发现」的书源：启用、有 exploreUrl、且规则里确实写了发现列表
    func exploreSources() -> [BookSource] {
        (try? db.dbQueue.read {
            try BookSource.fetchAll($0, sql: """
                select * from book_sources
                where enabled = 1 and enabledExplore = 1
                  and trim(ifnull(exploreUrl, '')) <> ''
                \(Self.orderClause)
                """)
        }) ?? []
    }

    func sources(ofType type: Int) -> [BookSource] {
        (try? db.dbQueue.read {
            try BookSource.fetchAll($0, sql: """
                select * from book_sources where bookSourceType = ? \(Self.orderClause)
                """, arguments: [type])
        }) ?? []
    }

    func get(_ key: String) -> BookSource? {
        try? db.dbQueue.read { try BookSource.fetchOne($0, key: key) }
    }

    func has(_ key: String) -> Bool {
        (try? db.dbQueue.read { try BookSource.filter(key: key).fetchCount($0) }) ?? 0 > 0
    }

    func count() -> Int {
        (try? db.dbQueue.read { try BookSource.fetchCount($0) }) ?? 0
    }

    func enabledCount() -> Int {
        (try? db.dbQueue.read {
            try BookSource.filter(Column("enabled") == true).fetchCount($0)
        }) ?? 0
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
        _ = try? db.dbQueue.write { database in
            for source in sources where (try? source.save(database)) != nil {
                count += 1
            }
        }
        return count
    }

    func delete(_ key: String) {
        _ = try? db.dbQueue.write { try BookSource.deleteOne($0, key: key) }
    }

    func delete(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        _ = try? db.dbQueue.write { database in
            for key in keys { try BookSource.deleteOne(database, key: key) }
        }
    }

    func deleteAll() {
        _ = try? db.dbQueue.write { try BookSource.deleteAll($0) }
    }

    func setEnabled(_ keys: [String], _ enabled: Bool) {
        guard !keys.isEmpty else { return }
        _ = try? db.dbQueue.write { database in
            for key in keys {
                try database.execute(sql: "update book_sources set enabled = ? where bookSourceUrl = ?",
                                     arguments: [enabled, key])
            }
        }
    }

    func setExploreEnabled(_ keys: [String], _ enabled: Bool) {
        guard !keys.isEmpty else { return }
        _ = try? db.dbQueue.write { database in
            for key in keys {
                try database.execute(sql: "update book_sources set enabledExplore = ? where bookSourceUrl = ?",
                                     arguments: [enabled, key])
            }
        }
    }

    /// 全部分组（去重 + 排序）。书源分组是逗号分隔的多值字段。
    func groups() -> [String] {
        var set = Set<String>()
        for source in all() {
            guard let group = source.bookSourceGroup else { continue }
            for g in group.splitNotBlank("[,;，；]") { set.insert(g) }
        }
        return set.sorted()
    }

    // MARK: 排序

    func moveToTop(_ key: String) {
        _ = try? db.dbQueue.write { database in
            guard let min = try Int.fetchOne(database,
                                             sql: "select min(customOrder) from book_sources") else { return }
            try database.execute(sql: "update book_sources set customOrder = ? where bookSourceUrl = ?",
                                 arguments: [min - 1, key])
        }
    }

    func moveToBottom(_ key: String) {
        _ = try? db.dbQueue.write { database in
            guard let max = try Int.fetchOne(database,
                                             sql: "select max(customOrder) from book_sources") else { return }
            try database.execute(sql: "update book_sources set customOrder = ? where bookSourceUrl = ?",
                                 arguments: [max + 1, key])
        }
    }

    /// 上游 `upOrder`：把 customOrder 归一成 0,1,2…
    func normalizeOrder() {
        _ = try? db.dbQueue.write { database in
            let keys = try String.fetchAll(database,
                                           sql: "select bookSourceUrl from book_sources \(Self.orderClause)")
            for (index, key) in keys.enumerated() {
                try database.execute(sql: "update book_sources set customOrder = ? where bookSourceUrl = ?",
                                     arguments: [index, key])
            }
        }
    }
}

// MARK: - 书籍

struct BookDao {
    let db: AppDatabase

    private static let orderClause = "order by durChapterTime desc"

    func all() -> [Book] {
        (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: "select * from books \(Self.orderClause)")
        }) ?? []
    }

    /// 书架（排除未正式加入书架的临时书籍）
    func shelf() -> [Book] {
        (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: """
                select * from books where (type & \(BookType.notShelf)) = 0 \(Self.orderClause)
                """)
        }) ?? []
    }

    func shelf(inGroup groupId: Int64) -> [Book] {
        (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: """
                select * from books
                where (type & \(BookType.notShelf)) = 0 and `group` = ? \(Self.orderClause)
                """, arguments: [groupId])
        }) ?? []
    }

    /// 上游 `flowNoGroup`：group 位掩码里没有任何用户分组位
    func shelfNoGroup() -> [Book] {
        (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: """
                select * from books
                where (type & \(BookType.notShelf)) = 0
                  and ((select sum(groupId) from book_groups where groupId > 0) & `group`) = 0
                \(Self.orderClause)
                """)
        }) ?? []
    }

    func inGroup(_ groupId: Int64) -> [Book] {
        (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: "select * from books where `group` = ? \(Self.orderClause)",
                              arguments: [groupId])
        }) ?? []
    }

    /// 按类型位掩码筛选（不含本地书）
    func withType(_ type: Int) -> [Book] {
        (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: """
                select * from books
                where (type & ?) > 0 and (type & \(BookType.local)) = 0 \(Self.orderClause)
                """, arguments: [type])
        }) ?? []
    }

    func localBooks() -> [Book] {
        (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: """
                select * from books where (type & \(BookType.local)) > 0 \(Self.orderClause)
                """)
        }) ?? []
    }

    func privateBooks() -> [Book] {
        (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: """
                select * from books where isPrivate = 1 \(Self.orderClause)
                """)
        }) ?? []
    }

    func search(_ key: String) -> [Book] {
        guard !key.isBlank else { return all() }
        let like = "%\(key)%"
        return (try? db.dbQueue.read {
            try Book.fetchAll($0, sql: """
                select * from books
                where name like ? or author like ? \(Self.orderClause)
                """, arguments: [like, like])
        }) ?? []
    }

    func get(_ bookUrl: String) -> Book? {
        try? db.dbQueue.read { try Book.fetchOne($0, key: bookUrl) }
    }

    func exists(_ bookUrl: String) -> Bool {
        (try? db.dbQueue.read { try Book.filter(key: bookUrl).fetchCount($0) }) ?? 0 > 0
    }

    func count() -> Int {
        (try? db.dbQueue.read { try Book.fetchCount($0) }) ?? 0
    }

    func save(_ book: Book) {
        dbWrite(db, "保存书籍") { try book.save($0) }
    }

    func saveAll(_ books: [Book]) {
        dbWrite(db, "批量保存书籍") { database in
            for book in books { try book.save(database) }
        }
    }

    func delete(_ bookUrl: String) {
        _ = try? db.dbQueue.write { try Book.deleteOne($0, key: bookUrl) }
    }

    func deleteAll() {
        _ = try? db.dbQueue.write { try Book.deleteAll($0) }
    }

    func updateReadingProgress(bookUrl: String, chapterIndex: Int, chapterTitle: String,
                               chapterPos: Int = 0) {
        _ = try? db.dbQueue.write { database in
            try database.execute(
                sql: """
                update books set durChapterIndex = ?, durChapterTitle = ?, durChapterPos = ?,
                durChapterTime = ? where bookUrl = ?
                """,
                arguments: [chapterIndex, chapterTitle, chapterPos,
                            Int64(Date().timeIntervalSince1970 * 1000), bookUrl]
            )
        }
    }

    /// 对齐上游 `upLatestChapter`：只在章节变化时更新标题与时间
    func updateLatestChapter(bookUrl: String, title: String, time: Int64) {
        _ = try? db.dbQueue.write { database in
            try database.execute(
                sql: "update books set latestChapterTitle = ?, latestChapterTime = ? where bookUrl = ?",
                arguments: [title, time, bookUrl]
            )
        }
    }

    func updateGroup(bookUrl: String, group: Int64) {
        _ = try? db.dbQueue.write { database in
            try database.execute(sql: "update books set `group` = ? where bookUrl = ?",
                                 arguments: [group, bookUrl])
        }
    }

    /// 统计各分组的书籍数，键为 groupId
    func groupCounts() -> [Int64: Int] {
        let rows = (try? db.dbQueue.read { database in
            try Row.fetchAll(database, sql: """
                select `group` as g, count(*) as c from books group by `group`
                """)
        }) ?? []
        var result: [Int64: Int] = [:]
        for row in rows {
            result[row["g"] as Int64? ?? 0] = row["c"] as Int? ?? 0
        }
        return result
    }
}

// MARK: - 章节

struct BookChapterDao {
    let db: AppDatabase

    func chapters(of bookUrl: String) -> [BookChapter] {
        (try? db.dbQueue.read {
            try BookChapter
                .filter(Column("bookUrl") == bookUrl)
                .order(Column("index"))
                .fetchAll($0)
        }) ?? []
    }

    /// 只取标题与地址，用于快速渲染目录
    func chapterTitles(of bookUrl: String) -> [(index: Int, title: String, url: String)] {
        let rows = (try? db.dbQueue.read { database in
            try Row.fetchAll(database, sql: """
                select `index`, title, url from chapters where bookUrl = ? order by `index`
                """, arguments: [bookUrl])
        }) ?? []
        return rows.map { ($0["index"] ?? 0, $0["title"] ?? "", $0["url"] ?? "") }
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

    /// 对齐上游 `getChapterByIndex`：按 index 批量取
    func chapters(bookUrl: String, indexes: [Int]) -> [BookChapter] {
        guard !indexes.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: indexes.count).joined(separator: ",")
        let args = StatementArguments([bookUrl] + indexes.map { $0 as Any }) ?? []
        return (try? db.dbQueue.read {
            try BookChapter.fetchAll($0, sql: """
                select * from chapters where bookUrl = ? and `index` in (\(placeholders))
                order by `index`
                """, arguments: args)
        }) ?? []
    }

    /// 对齐上游 `insertOrReplaceChapterList`：整表替换该书的目录
    func replaceChapters(_ chapters: [BookChapter], of bookUrl: String) {
        dbWrite(db, "替换目录") { database in
            try BookChapter.filter(Column("bookUrl") == bookUrl).deleteAll(database)
            for chapter in chapters { try chapter.insert(database) }
        }
    }

    func save(_ chapter: BookChapter) {
        dbWrite(db, "保存章节") { try chapter.save($0) }
    }

    func saveAll(_ chapters: [BookChapter]) {
        dbWrite(db, "批量保存章节") { database in
            for chapter in chapters { try chapter.save(database) }
        }
    }

    func updateReviewImg(bookUrl: String, url: String, reviewImg: String?) {
        _ = try? db.dbQueue.write { database in
            try database.execute(
                sql: "update chapters set reviewImg = ? where bookUrl = ? and url = ?",
                arguments: [reviewImg, bookUrl, url]
            )
        }
    }

    func deleteAll(of bookUrl: String) {
        _ = try? db.dbQueue.write { database in
            try BookChapter.filter(Column("bookUrl") == bookUrl).deleteAll(database)
        }
    }

    func count(of bookUrl: String) -> Int {
        (try? db.dbQueue.read {
            try BookChapter.filter(Column("bookUrl") == bookUrl).fetchCount($0)
        }) ?? 0
    }

    func maxIndex(of bookUrl: String) -> Int {
        (try? db.dbQueue.read { database in
            try Int.fetchOne(database,
                             sql: "select max(`index`) from chapters where bookUrl = ?",
                             arguments: [bookUrl])
        }) ?? -1
    }
}

// MARK: - 搜索结果

struct SearchBookDao {
    let db: AppDatabase

    func all() -> [SearchBook] {
        (try? db.dbQueue.read {
            try SearchBook.fetchAll($0, sql: "select * from searchBooks order by time desc")
        }) ?? []
    }

    func get(_ bookUrl: String) -> SearchBook? {
        try? db.dbQueue.read { try SearchBook.fetchOne($0, key: bookUrl) }
    }

    /// 同名同作者的其它书源结果，用于「换源」
    func byNameAuthor(name: String, author: String, excluding bookUrl: String? = nil) -> [SearchBook] {
        (try? db.dbQueue.read { database in
            var sql = "select * from searchBooks where name = ? and author = ?"
            var args: [any DatabaseValueConvertible] = [name, author]
            if let bookUrl {
                sql += " and bookUrl <> ?"
                args.append(bookUrl)
            }
            sql += " order by respondTime asc"
            return try SearchBook.fetchAll(database, sql: sql, arguments: StatementArguments(args) ?? [])
        }) ?? []
    }

    func count() -> Int {
        (try? db.dbQueue.read { try SearchBook.fetchCount($0) }) ?? 0
    }

    func save(_ book: SearchBook) {
        dbWrite(db, "保存搜索结果") { try book.save($0) }
    }

    func saveAll(_ books: [SearchBook]) {
        dbWrite(db, "批量保存搜索结果") { database in
            for book in books { try book.save(database) }
        }
    }

    func delete(_ bookUrl: String) {
        _ = try? db.dbQueue.write { try SearchBook.deleteOne($0, key: bookUrl) }
    }

    func clear(name: String, author: String) {
        _ = try? db.dbQueue.write { database in
            try database.execute(sql: "delete from searchBooks where name = ? and author = ?",
                                 arguments: [name, author])
        }
    }

    /// 对齐上游 `clearExpired`：清掉早于给定时间的缓存结果
    func clearExpired(before time: Int64) {
        _ = try? db.dbQueue.write { database in
            try database.execute(sql: "delete from searchBooks where time < ?", arguments: [time])
        }
    }

    func deleteAll() {
        _ = try? db.dbQueue.write { database in
            try SearchBook.deleteAll(database)
        }
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

    func save(_ cookie: Cookie) {
        _ = try? db.dbQueue.write { try cookie.save($0) }
    }

    func insert(_ cookie: Cookie) {
        save(cookie)
    }

    func delete(_ domain: String) {
        _ = try? db.dbQueue.write { try Cookie.deleteOne($0, key: domain) }
    }

    func deleteAll() {
        _ = try? db.dbQueue.write { try Cookie.deleteAll($0) }
    }
}

// MARK: - 阅读记录

/// 主键是 `(deviceId, bookName, bookAuthor)` 复合键，
/// 所以不能再用 `deleteOne(key:)`（那是单列主键的简写）。
struct ReadRecordDao {
    let db: AppDatabase

    func all() -> [ReadRecord] {
        (try? db.dbQueue.read {
            try ReadRecord.fetchAll($0, sql: "select * from readRecord order by lastRead desc")
        }) ?? []
    }

    func recent(limit: Int = 20) -> [ReadRecord] {
        (try? db.dbQueue.read { database in
            try ReadRecord.fetchAll(database, sql: """
                select * from readRecord order by lastRead desc limit ?
                """, arguments: [limit])
        }) ?? []
    }

    func get(deviceId: String, bookName: String, bookAuthor: String) -> ReadRecord? {
        try? db.dbQueue.read { database in
            try ReadRecord.fetchOne(database, sql: """
                select * from readRecord
                where deviceId = ? and bookName = ? and bookAuthor = ?
                """, arguments: [deviceId, bookName, bookAuthor])
        }
    }

    /// 对齐上游 `getReadTime(deviceId,bookName,bookAuthor)`
    func readTime(deviceId: String, bookName: String, bookAuthor: String) -> Int64 {
        (try? db.dbQueue.read { database in
            try Int64.fetchOne(database, sql: """
                select readTime from readRecord
                where deviceId = ? and bookName = ? and bookAuthor = ?
                """, arguments: [deviceId, bookName, bookAuthor])
        }) ?? 0 ?? 0
    }

    func totalReadTime() -> Int64 {
        (try? db.dbQueue.read { database in
            try Int64.fetchOne(database, sql: "select sum(readTime) from readRecord")
        }) ?? 0 ?? 0
    }

    func save(_ record: ReadRecord) {
        _ = try? db.dbQueue.write { try record.save($0) }
    }

    /// 累加阅读时长；不存在的记录按传入值创建
    func addReadTime(deviceId: String, bookName: String, bookAuthor: String,
                     seconds: Int64, at time: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        guard seconds > 0 else { return }
        _ = try? db.dbQueue.write { database in
            if var existing = try ReadRecord.fetchOne(database, sql: """
                select * from readRecord
                where deviceId = ? and bookName = ? and bookAuthor = ?
                """, arguments: [deviceId, bookName, bookAuthor]) {
                existing.readTime += seconds
                existing.lastRead = time
                try existing.save(database)
            } else {
                var record = ReadRecord()
                record.deviceId = deviceId
                record.bookName = bookName
                record.bookAuthor = bookAuthor
                record.readTime = seconds
                record.lastRead = time
                try record.insert(database)
            }
        }
    }

    func delete(_ record: ReadRecord) {
        _ = try? db.dbQueue.write { database in
            try database.execute(sql: """
                delete from readRecord where deviceId = ? and bookName = ? and bookAuthor = ?
                """, arguments: [record.deviceId, record.bookName, record.bookAuthor])
        }
    }

    /// 对齐上游 `deleteByName`：删掉同名同作者的所有设备记录
    func deleteByName(_ bookName: String, _ bookAuthor: String) {
        _ = try? db.dbQueue.write { database in
            try database.execute(sql: "delete from readRecord where bookName = ? and bookAuthor = ?",
                                 arguments: [bookName, bookAuthor])
        }
    }

    func clear() {
        _ = try? db.dbQueue.write { database in
            try database.execute(sql: "delete from readRecord")
        }
    }
}

// MARK: - 分组

struct BookGroupDao {
    let db: AppDatabase

    func all() -> [BookGroup] {
        (try? db.dbQueue.read {
            try BookGroup.fetchAll($0, sql: "select * from book_groups order by `order` asc")
        }) ?? []
    }

    func get(_ groupId: Int64) -> BookGroup? {
        try? db.dbQueue.read { try BookGroup.fetchOne($0, key: groupId) }
    }

    func save(_ group: BookGroup) {
        _ = try? db.dbQueue.write { try group.save($0) }
    }

    /// 新分组拿当前最大 order + 1
    func nextGroupId() -> Int64 {
        let maxId = (try? db.dbQueue.read { database in
            try Int64.fetchOne(database, sql: "select max(groupId) from book_groups where groupId > 0")
        }) ?? 0 ?? 0
        return maxId + 1
    }

    func nextOrder() -> Int {
        let maxOrder = (try? db.dbQueue.read { database in
            try Int.fetchOne(database, sql: "select max(`order`) from book_groups")
        }) ?? 0
        return maxOrder + 1
    }

    /// 删除分组。书籍的 group 是位掩码，需要把该位清掉，否则书籍会「消失」
    func delete(_ groupId: Int64) {
        guard groupId > 0 else { return }
        _ = try? db.dbQueue.write { database in
            try database.execute(sql: "update books set `group` = `group` & ~? where (`group` & ?) > 0",
                                 arguments: [groupId, groupId])
            try BookGroup.deleteOne(database, key: groupId)
        }
    }
}
