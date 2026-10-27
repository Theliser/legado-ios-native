import Foundation

// MARK: - 书源仓库

struct SourceImportResult {
    var added: Int = 0
    var updated: Int = 0
    var failed: Int = 0
    var messages: [String] = []

    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("新增 \(added)") }
        if updated > 0 { parts.append("更新 \(updated)") }
        if failed > 0 { parts.append("失败 \(failed)") }
        return parts.isEmpty ? "没有可导入的书源" : parts.joined(separator: "，")
    }
}

final class BookSourceRepository {
    private let dao: BookSourceDao

    init(db: AppDatabase) {
        self.dao = BookSourceDao(db: db)
    }

    var all: [BookSource] { dao.all() }
    var enabledSources: [BookSource] { dao.enabledSources() }
    var groups: [String] { dao.groups() }
    var count: Int { dao.count() }

    func source(for key: String) -> BookSource? { dao.get(key) }

    @discardableResult
    func save(_ source: BookSource) -> Bool { dao.save(source) }

    func delete(_ source: BookSource) { dao.delete(source.bookSourceUrl) }
    func deleteAll() { dao.deleteAll() }

    /// 导入书源 JSON（单条 / 数组 / 带包裹字段的对象）
    @discardableResult
    func importJSON(_ text: String) -> SourceImportResult {
        var result = SourceImportResult()
        let parsed = JSONTool.parse(text)
        var rawItems: [Any] = []

        if let array = parsed as? [Any] {
            rawItems = array
        } else if let obj = parsed as? [String: Any] {
            if let inner = obj["bookSources"] as? [Any] {
                rawItems = inner
            } else if let inner = obj["sources"] as? [Any] {
                rawItems = inner
            } else if obj["bookSourceUrl"] != nil {
                rawItems = [obj]
            }
        }

        guard !rawItems.isEmpty else {
            result.failed = 1
            result.messages.append("不是有效的书源 JSON")
            return result
        }

        let decoder = JSONDecoder()
        for item in rawItems {
            guard JSONSerialization.isValidJSONObject(item),
                  let data = try? JSONSerialization.data(withJSONObject: item),
                  var source = try? decoder.decode(BookSource.self, from: data) else {
                result.failed += 1
                result.messages.append("有一条书源格式不正确，已跳过")
                continue
            }
            guard !source.bookSourceUrl.isBlank else {
                result.failed += 1
                result.messages.append("书源缺少 bookSourceUrl")
                continue
            }
            source.bookSourceUrl = source.bookSourceUrl.trimmed
            if source.bookSourceName.isBlank {
                source.bookSourceName = URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl
            }
            let existed = dao.get(source.bookSourceUrl) != nil
            source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1000)
            if dao.save(source) {
                if existed { result.updated += 1 } else { result.added += 1 }
            } else {
                result.failed += 1
                result.messages.append("保存失败：\(source.bookSourceName)")
            }
        }
        return result
    }

    /// 导出为上游兼容的 JSON 数组
    func exportJSON(onlyEnabled: Bool = false) -> String {
        let sources = onlyEnabled ? enabledSources : all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(sources),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    func toggleEnabled(_ source: BookSource) {
        var s = source
        s.enabled.toggle()
        dao.save(s)
    }

    func setGroup(_ sources: [BookSource], group: String, add: Bool) {
        for var source in sources {
            if add { source.addGroup(group) } else { source.removeGroup(group) }
            dao.save(source)
        }
    }
}

// MARK: - 书籍仓库

final class BookRepository {
    private let bookDao: BookDao
    private let chapterDao: BookChapterDao
    private let readRecordDao: ReadRecordDao
    private let settings: AppSettings

    init(db: AppDatabase, settings: AppSettings = AppSettings()) {
        self.bookDao = BookDao(db: db)
        self.chapterDao = BookChapterDao(db: db)
        self.readRecordDao = ReadRecordDao(db: db)
        self.settings = settings
    }

    var books: [Book] { bookDao.shelf() }

    func books(inGroup groupId: Int64) -> [Book] {
        groupId == BookGroup.BuiltinId.all ? bookDao.shelf() : bookDao.shelf(inGroup: groupId)
    }

    func book(_ bookUrl: String) -> Book? { bookDao.get(bookUrl) }

    func exists(_ bookUrl: String) -> Bool { bookDao.exists(bookUrl) }

    func save(_ book: Book) { bookDao.save(book) }

    @discardableResult
    func addToShelf(_ searchBook: SearchBook) -> Book {
        if var existing = bookDao.get(searchBook.bookUrl) {
            existing.name = searchBook.name
            existing.author = searchBook.author
            existing.coverUrl = searchBook.coverUrl ?? existing.coverUrl
            existing.intro = searchBook.intro ?? existing.intro
            existing.kind = searchBook.kind ?? existing.kind
            // 从搜索结果加入书架时要去掉 notShelf 位
            existing.type &= ~BookType.notShelf
            bookDao.save(existing)
            return existing
        }
        var book = searchBook.toBook()
        book.type = searchBook.type & ~BookType.notShelf
        bookDao.save(book)
        return book
    }

    func delete(_ book: Book) {
        bookDao.delete(book.bookUrl)
    }

    func chapters(of book: Book) -> [BookChapter] {
        chapterDao.chapters(of: book.bookUrl)
    }

    func chapter(book: Book, index: Int) -> BookChapter? {
        chapterDao.chapter(bookUrl: book.bookUrl, index: index)
    }

    func replaceChapters(_ chapters: [BookChapter], of bookUrl: String) {
        chapterDao.replaceChapters(chapters, of: bookUrl)
    }

    func save(chapter: BookChapter) {
        chapterDao.save(chapter)
    }

    /// 阅读进度 + 阅读时长。上游按 (deviceId, bookName, author) 记账，
    /// 同名同作者不同书源的记录会合并到同一条。
    func updateProgress(book: Book, index: Int, title: String, pos: Int = 0,
                        seconds: Int64 = 0) {
        bookDao.updateReadingProgress(bookUrl: book.bookUrl, chapterIndex: index,
                                      chapterTitle: title, chapterPos: pos)
        readRecordDao.addReadTime(deviceId: settings.deviceId,
                                  bookName: book.name,
                                  bookAuthor: book.author,
                                  seconds: max(seconds, 1))
    }

    var recentReads: [ReadRecord] { readRecordDao.recent() }

    func readTime(of book: Book) -> Int64 {
        readRecordDao.readTime(deviceId: settings.deviceId,
                               bookName: book.name,
                               bookAuthor: book.author)
    }
}

// MARK: - 分组仓库

final class BookGroupRepository {
    private let dao: BookGroupDao

    init(db: AppDatabase) {
        self.dao = BookGroupDao(db: db)
    }

    var groups: [BookGroup] { dao.all() }

    func save(_ group: BookGroup) { dao.save(group) }

    /// 新建分组：分配 groupId 与 order 后落库
    @discardableResult
    func create(name: String) -> BookGroup {
        var group = BookGroup()
        group.groupId = dao.nextGroupId()
        group.groupName = name
        group.order = dao.nextOrder()
        dao.save(group)
        return group
    }

    /// 删除分组，同时把该分组位从书籍的 group 掩码里清掉
    func delete(_ groupId: Int64) {
        dao.delete(groupId)
    }

    /// 首次启动时建一个默认分组。上游的内置分组（全部/本地/音频…）是
    /// 负数 id 的虚拟分组，不入库，所以这里只补一个用户分组起点。
    func ensureDefaultGroups() {
        guard dao.all().isEmpty else { return }
        var group = BookGroup()
        group.groupId = 1
        group.groupName = "默认"
        group.order = 0
        dao.save(group)
    }
}

// MARK: - 搜索结果仓库

final class SearchBookRepository {
    private let dao: SearchBookDao

    init(db: AppDatabase) {
        self.dao = SearchBookDao(db: db)
    }

    var all: [SearchBook] { dao.all() }
    var count: Int { dao.count() }

    func book(_ bookUrl: String) -> SearchBook? { dao.get(bookUrl) }

    /// 换源候选：同名同作者、不同书源
    func candidates(for book: SearchBook) -> [SearchBook] {
        dao.byNameAuthor(name: book.name, author: book.author, excluding: book.bookUrl)
    }

    func save(_ book: SearchBook) { dao.save(book) }

    func saveAll(_ books: [SearchBook]) { dao.saveAll(books) }

    func delete(_ book: SearchBook) { dao.delete(book.bookUrl) }

    func clear(name: String, author: String) { dao.clear(name: name, author: author) }

    /// 清理过期缓存，默认保留 2 小时
    func clearExpired(olderThan seconds: TimeInterval = 2 * 3600) {
        let cutoff = Int64((Date().timeIntervalSince1970 - seconds) * 1000)
        dao.clearExpired(before: cutoff)
    }

    func deleteAll() { dao.deleteAll() }
}
