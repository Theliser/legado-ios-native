import XCTest
import GRDB
@testable import Legado

/// 数据层：实体往返、DAO 查询语义、复合主键、导入导出。
/// 语义基准是上游 Room 实体与 DAO 里的 SQL。
final class DataLayerTests: XCTestCase {

    private var db: AppDatabase!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(inMemory: true)
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        db = nil
        try super.tearDownWithError()
    }

    /// chapters 对 books 有外键约束（与上游 Room 一致），插章节前要先把书建出来
    private func insertBook(_ bookUrl: String, name: String = "书") {
        var book = Book()
        book.bookUrl = bookUrl
        book.name = name
        book.type = BookType.text
        BookDao(db: db).save(book)
    }

    private func makeSource(_ url: String, name: String = "源",
                            group: String? = nil, enabled: Bool = true) -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = url
        source.bookSourceName = name
        source.bookSourceGroup = group
        source.enabled = enabled
        return source
    }

    // MARK: - 书源

    func testBookSourceRoundTripKeepsNestedRules() {
        var source = makeSource("https://a.com", name: "A站", group: "玄幻,都市")
        source.bookSourceType = 3
        source.enabledCookieJar = true
        source.concurrentRate = "1000/1000"
        source.header = #"{"User-Agent":"x"}"#
        var search = SearchRule()
        search.bookList = ".result"
        search.name = ".title@text"
        source.ruleSearch = search
        var info = BookInfoRule()
        info.initRule = ".intro"
        info.tocUrl = "a@href"
        source.ruleBookInfo = info
        var toc = TocRule()
        toc.chapterList = "-dd"
        toc.formatJs = "title.replace(/第/g,'')"
        source.ruleToc = toc

        let dao = BookSourceDao(db: db)
        XCTAssertTrue(dao.save(source))

        let loaded = dao.get("https://a.com")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.bookSourceName, "A站")
        XCTAssertEqual(loaded?.bookSourceGroup, "玄幻,都市")
        XCTAssertEqual(loaded?.bookSourceType, 3)
        XCTAssertEqual(loaded?.enabledCookieJar, true)
        XCTAssertEqual(loaded?.ruleSearch?.bookList, ".result")
        XCTAssertEqual(loaded?.ruleSearch?.name, ".title@text")
        // 上游字段名是 init，Swift 侧叫 initRule，存取要能对上
        XCTAssertEqual(loaded?.ruleBookInfo?.initRule, ".intro")
        XCTAssertEqual(loaded?.ruleToc?.chapterList, "-dd")
        XCTAssertEqual(loaded?.ruleToc?.formatJs, "title.replace(/第/g,'')")
        // 文件型书源 → text | webFile 位
        XCTAssertEqual(loaded?.bookType, BookType.text | BookType.webFile)
    }

    func testSourceGroupFilterIsExactToken() {
        let dao = BookSourceDao(db: db)
        dao.save(makeSource("https://1", name: "一", group: "玄幻言情"))
        dao.save(makeSource("https://2", name: "二", group: "玄幻,都市"))
        dao.save(makeSource("https://3", name: "三", group: "玄幻"))

        // 整词匹配：不该把「玄幻言情」算进「玄幻」
        let exact = dao.enabledByGroup("玄幻").map(\.bookSourceName).sorted()
        XCTAssertEqual(exact, ["三", "二"])

        // 宽松匹配（上游 getByGroup）会把包含该词的都算进来
        let loose = dao.byGroup("玄幻").map(\.bookSourceName).sorted()
        XCTAssertEqual(loose, ["一", "三", "二"])
    }

    func testSourceNoGroupCoversNullEmptyAndPlaceholder() {
        let dao = BookSourceDao(db: db)
        dao.save(makeSource("https://1", name: "空", group: nil))
        dao.save(makeSource("https://2", name: "空串", group: ""))
        dao.save(makeSource("https://3", name: "占位", group: "未分组"))
        dao.save(makeSource("https://4", name: "有分组", group: "都市"))

        let names = Set(dao.noGroup().map(\.bookSourceName))
        XCTAssertEqual(names, Set(["空", "空串", "占位"]))
    }

    func testSourceSearchMatchesNameUrlGroupComment() {
        let dao = BookSourceDao(db: db)
        var byName = makeSource("https://a.com", name: "笔趣阁")
        dao.save(byName)
        var byComment = makeSource("https://b.com", name: "B站")
        byComment.bookSourceComment = "备用"
        dao.save(byComment)
        var byGroup = makeSource("https://c.com", name: "C站", group: "玄幻")
        dao.save(byGroup)

        XCTAssertEqual(dao.search("笔趣阁").count, 1)
        XCTAssertEqual(dao.search("b.com").count, 1)
        XCTAssertEqual(dao.search("玄幻").count, 1)
        XCTAssertEqual(dao.search("备用").count, 1)
        XCTAssertEqual(dao.search("不存在的词").count, 0)
        _ = byName
    }

    func testSourceEnableToggleAndOrdering() {
        let dao = BookSourceDao(db: db)
        dao.save(makeSource("https://1", name: "二"))
        dao.save(makeSource("https://2", name: "一"))
        XCTAssertEqual(dao.count(), 2)
        XCTAssertEqual(dao.enabledCount(), 2)

        dao.setEnabled(["https://1"], false)
        XCTAssertEqual(dao.enabledCount(), 1)
        XCTAssertEqual(dao.enabledSources().map(\.bookSourceUrl), ["https://2"])

        dao.moveToTop("https://2")
        XCTAssertEqual(dao.all().first?.bookSourceUrl, "https://2")
    }

    func testSourceGroupsSplitCommaAndChineseComma() {
        let dao = BookSourceDao(db: db)
        dao.save(makeSource("https://1", group: "玄幻,都市；科幻"))
        XCTAssertEqual(dao.groups(), ["玄幻", "科幻", "都市"].sorted())
    }

    // MARK: - 书籍类型位掩码

    func testBookTypeIsBitmask() {
        XCTAssertEqual(BookType.text, 8)
        XCTAssertEqual(BookType.audio, 32)
        XCTAssertEqual(BookType.image, 64)
        XCTAssertEqual(BookType.webFile, 128)
        XCTAssertEqual(BookType.local, 256)
        XCTAssertEqual(BookType.allBookType, 8 | 64 | 32 | 128)

        var book = Book()
        book.type = BookType.text
        XCTAssertTrue(book.isText)
        XCTAssertTrue(book.isOnLineTxt)
        XCTAssertFalse(book.isLocal)

        book.addType(BookType.updateError)
        XCTAssertTrue(book.isUpdateError)
        XCTAssertTrue(book.isText, "加位不该清掉原有类型")

        book.addType(BookType.local)
        XCTAssertFalse(book.isOnLineTxt, "本地书不算在线文本")

        book.removeType(BookType.local)
        XCTAssertTrue(book.isOnLineTxt)
    }

    func testShelfFiltersNotShelfAndLocal() {
        let dao = BookDao(db: db)
        var normal = Book(); normal.bookUrl = "u1"; normal.name = "正常"
        normal.type = BookType.text
        var temp = Book(); temp.bookUrl = "u2"; temp.name = "临时"
        temp.type = BookType.text | BookType.notShelf
        var local = Book(); local.bookUrl = "u3"; local.name = "本地"
        local.type = BookType.text | BookType.local
        dao.saveAll([normal, temp, local])

        XCTAssertEqual(dao.shelf().map(\.bookUrl).sorted(), ["u1", "u3"])
        XCTAssertEqual(dao.localBooks().map(\.bookUrl), ["u3"])
        XCTAssertEqual(dao.withType(BookType.local).map(\.bookUrl), [])
    }

    // MARK: - 章节（复合主键）

    func testChapterCompositePrimaryKey() {
        insertBook("bookA"); insertBook("bookB")
        let dao = BookChapterDao(db: db)
        var a = BookChapter(); a.bookUrl = "bookA"; a.url = "/1"; a.title = "A-1"; a.index = 0
        var b = BookChapter(); b.bookUrl = "bookB"; b.url = "/1"; b.title = "B-1"; b.index = 0
        dao.save(a)
        dao.save(b)

        // 同一个 url 在不同书下是两条独立记录
        XCTAssertEqual(dao.chapters(of: "bookA").count, 1)
        XCTAssertEqual(dao.chapters(of: "bookB").count, 1)
        XCTAssertEqual(dao.chapter(bookUrl: "bookA", url: "/1")?.title, "A-1")
        XCTAssertEqual(dao.chapter(bookUrl: "bookB", url: "/1")?.title, "B-1")
    }

    func testChapterReplaceAndOrdering() {
        insertBook("b")
        let dao = BookChapterDao(db: db)
        let chapters = (0..<3).map { i -> BookChapter in
            var c = BookChapter()
            c.bookUrl = "b"; c.url = "/\(i)"; c.title = "第\(i)章"; c.index = i
            return c
        }
        dao.replaceChapters(chapters.reversed(), of: "b")
        XCTAssertEqual(dao.chapters(of: "b").map(\.index), [0, 1, 2], "查询必须按 index 排序")
        XCTAssertEqual(dao.maxIndex(of: "b"), 2)

        // 再次替换应整表覆盖，不会残留
        dao.replaceChapters([chapters[0]], of: "b")
        XCTAssertEqual(dao.count(of: "b"), 1)
    }

    func testChapterBatchByIndexes() {
        insertBook("b")
        let dao = BookChapterDao(db: db)
        dao.replaceChapters((0..<5).map { i -> BookChapter in
            var c = BookChapter(); c.bookUrl = "b"; c.url = "/\(i)"; c.title = "t\(i)"; c.index = i
            return c
        }, of: "b")
        let picked = dao.chapters(bookUrl: "b", indexes: [3, 1])
        XCTAssertEqual(picked.map(\.index), [1, 3])
    }

    // MARK: - 分组

    func testDeleteGroupClearsBookGroupBit() {
        let groupDao = BookGroupDao(db: db)
        let bookDao = BookDao(db: db)
        var group = BookGroup(); group.groupId = 4; group.groupName = "玄幻"
        groupDao.save(group)

        var book = Book(); book.bookUrl = "u"; book.name = "n"; book.type = BookType.text
        book.group = 4 | 8
        bookDao.save(book)

        groupDao.delete(4)
        XCTAssertTrue(groupDao.all().isEmpty)
        XCTAssertEqual(bookDao.get("u")?.group, 8, "只清掉被删分组那一位，其它分组要保留")
    }

    func testGroupCreateAllocatesIdAndOrder() {
        let repo = BookGroupRepository(db: db)
        repo.ensureDefaultGroups()
        let created = repo.create(name: "都市")
        XCTAssertGreaterThan(created.groupId, 1)
        XCTAssertEqual(repo.groups.count, 2)
    }

    // MARK: - 搜索结果

    func testSearchBookDaoAndCandidateList() {
        let dao = SearchBookDao(db: db)
        var a = SearchBook(); a.bookUrl = "a"; a.name = "剑来"; a.author = "烽火"; a.origin = "s1"
        var b = SearchBook(); b.bookUrl = "b"; b.name = "剑来"; b.author = "烽火"; b.origin = "s2"
        var c = SearchBook(); c.bookUrl = "c"; c.name = "雪中"; c.author = "烽火"; c.origin = "s1"
        dao.saveAll([a, b, c])

        XCTAssertEqual(dao.count(), 3)
        XCTAssertEqual(dao.byNameAuthor(name: "剑来", author: "烽火").map(\.bookUrl).sorted(), ["a", "b"])
        XCTAssertEqual(dao.byNameAuthor(name: "剑来", author: "烽火", excluding: "a").map(\.bookUrl), ["b"])

        dao.clear(name: "剑来", author: "烽火")
        XCTAssertEqual(dao.count(), 1)

        _ = a; _ = b; _ = c
    }

    func testSearchBookClearExpired() {
        let dao = SearchBookDao(db: db)
        var old = SearchBook(); old.bookUrl = "old"; old.name = "旧"; old.time = 1000
        var new = SearchBook(); new.bookUrl = "new"; new.name = "新"; new.time = 9_000_000
        dao.saveAll([old, new])
        dao.clearExpired(before: 5000)
        XCTAssertEqual(dao.all().map(\.bookUrl), ["new"])
    }

    // MARK: - 阅读记录（复合主键 + 累计）

    func testReadRecordCompositeKeyAndAccumulate() {
        let dao = ReadRecordDao(db: db)
        dao.addReadTime(deviceId: "d1", bookName: "书", bookAuthor: "作者", seconds: 30)
        dao.addReadTime(deviceId: "d1", bookName: "书", bookAuthor: "作者", seconds: 12)
        dao.addReadTime(deviceId: "d2", bookName: "书", bookAuthor: "作者", seconds: 5)

        XCTAssertEqual(dao.readTime(deviceId: "d1", bookName: "书", bookAuthor: "作者"), 42)
        XCTAssertEqual(dao.readTime(deviceId: "d2", bookName: "书", bookAuthor: "作者"), 5)
        XCTAssertEqual(dao.all().count, 2, "同书不同设备是两条记录")

        // 空作者与真实作者必须是不同记录
        dao.addReadTime(deviceId: "d1", bookName: "书", bookAuthor: "", seconds: 3)
        XCTAssertEqual(dao.all().count, 3)
        XCTAssertEqual(dao.readTime(deviceId: "d1", bookName: "书", bookAuthor: ""), 3)

        XCTAssertEqual(dao.totalReadTime(), 50)
    }

    func testReadRecordDeleteByNameRemovesAllDevices() {
        let dao = ReadRecordDao(db: db)
        dao.addReadTime(deviceId: "d1", bookName: "书", bookAuthor: "作者", seconds: 1)
        dao.addReadTime(deviceId: "d2", bookName: "书", bookAuthor: "作者", seconds: 1)
        dao.addReadTime(deviceId: "d1", bookName: "别的书", bookAuthor: "作者", seconds: 1)

        dao.deleteByName("书", "作者")
        XCTAssertEqual(dao.all().count, 1)
        XCTAssertEqual(dao.all().first?.bookName, "别的书")
    }

    // MARK: - Cookie

    func testCookieUniqueByUrl() {
        let dao = CookieDao(db: db)
        dao.save(Cookie(url: "a.com", cookie: "k=1"))
        dao.save(Cookie(url: "a.com", cookie: "k=2"))
        XCTAssertEqual(dao.all().count, 1)
        XCTAssertEqual(dao.get("a.com")?.cookie, "k=2")
    }

    // MARK: - 导入导出

    func testImportBookSourceJSONArray() {
        let repo = BookSourceRepository(db: db)
        let json = """
        [{"bookSourceUrl":"https://a.com","bookSourceName":"A","bookSourceGroup":"玄幻",
          "ruleSearch":{"bookList":".r","name":".n@text"},
          "ruleToc":{"chapterList":"dd"}}]
        """
        let result = repo.importJSON(json)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(repo.count, 1)
        XCTAssertEqual(repo.source(for: "https://a.com")?.ruleSearch?.name, ".n@text")
        XCTAssertEqual(repo.source(for: "https://a.com")?.ruleToc?.chapterList, "dd")
    }

    func testImportAcceptsStringEncodedRules() {
        // 上游 JsonDeserializer 允许规则字段是「被写成字符串的 JSON」
        let repo = BookSourceRepository(db: db)
        let json = """
        [{"bookSourceUrl":"https://b.com","bookSourceName":"B",
          "ruleSearch":"{\\"bookList\\":\\".r\\",\\"name\\":\\".n@text\\"}"}]
        """
        let result = repo.importJSON(json)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(repo.source(for: "https://b.com")?.ruleSearch?.name, ".n@text")
    }

    func testImportHandlesSingleObjectAndConflict() {
        let repo = BookSourceRepository(db: db)
        let single = #"{"bookSourceUrl":"https://c.com","bookSourceName":"C"}"#
        XCTAssertEqual(repo.importJSON(single).added, 1)

        // 同 URL 再导入应算更新而不是新增
        let dup = #"{"bookSourceUrl":"https://c.com","bookSourceName":"C2"}"#
        let second = repo.importJSON(dup)
        XCTAssertEqual(second.updated, 1)
        XCTAssertEqual(repo.count, 1)
        XCTAssertEqual(repo.source(for: "https://c.com")?.bookSourceName, "C2")
    }

    func testImportRejectsBadPayloadAndMissingUrl() {
        let repo = BookSourceRepository(db: db)
        XCTAssertEqual(repo.importJSON("not json").failed, 1)

        let noUrl = #"[{"bookSourceName":"没有地址"}]"#
        let result = repo.importJSON(noUrl)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(repo.count, 0)
    }

    func testExportRoundTrip() {
        let repo = BookSourceRepository(db: db)
        var source = makeSource("https://d.com", name: "D", group: "都市")
        var toc = TocRule(); toc.chapterList = "-dd"; toc.nextTocUrl = ".next@href"
        source.ruleToc = toc
        repo.save(source)

        let exported = repo.exportJSON()
        let other = try! AppDatabase(inMemory: true)
        let otherRepo = BookSourceRepository(db: other)
        XCTAssertEqual(otherRepo.importJSON(exported).added, 1)

        let restored = otherRepo.source(for: "https://d.com")
        XCTAssertEqual(restored?.bookSourceName, "D")
        XCTAssertEqual(restored?.bookSourceGroup, "都市")
        XCTAssertEqual(restored?.ruleToc?.chapterList, "-dd")
        XCTAssertEqual(restored?.ruleToc?.nextTocUrl, ".next@href")
    }

    // MARK: - 仓库联动

    func testAddToShelfClearsNotShelfAndKeepsListIntro() {
        let repo = BookRepository(db: db, settings: AppSettings(defaults: defaults))
        var searchBook = SearchBook()
        searchBook.bookUrl = "u"; searchBook.name = "书"; searchBook.author = "作者"
        searchBook.origin = "o"; searchBook.intro = "列表简介"
        searchBook.type = BookType.text | BookType.notShelf

        let book = repo.addToShelf(searchBook)
        XCTAssertFalse(book.isNotShelf)
        XCTAssertEqual(book.listIntro, "列表简介")

        let loaded = repo.book("u")
        XCTAssertEqual(loaded?.listIntro, "列表简介")
        XCTAssertEqual(loaded?.intro, "列表简介")
    }

    func testUpdateProgressWritesReadRecordPerDevice() {
        let settings = AppSettings(defaults: defaults)
        let repo = BookRepository(db: db, settings: settings)
        var book = Book(); book.bookUrl = "u"; book.name = "书"; book.author = "作者"
        book.type = BookType.text
        repo.save(book)

        repo.updateProgress(book: book, index: 3, title: "第3章", pos: 10, seconds: 60)
        repo.updateProgress(book: book, index: 4, title: "第4章", pos: 0, seconds: 30)

        XCTAssertEqual(repo.book("u")?.durChapterIndex, 4)
        XCTAssertEqual(repo.book("u")?.durChapterTitle, "第4章")
        XCTAssertEqual(repo.readTime(of: book), 90, "同一本书的时长要累加")
    }

    // MARK: - 宽松解码

    func testBookSourceAcceptsStringNumbers() throws {
        // 真实书源里 `lastUpdateTime` 常常是字符串，严格解码会让整份书源导入失败
        let json = """
        {
          "bookSourceName": "字符串数字源",
          "bookSourceUrl": "https://a.com",
          "bookSourceType": "0",
          "lastUpdateTime": "1730000000000",
          "respondTime": "1500",
          "weight": "7",
          "enabled": 1,
          "enabledExplore": "false",
          "customOrder": true
        }
        """
        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.bookSourceName, "字符串数字源")
        XCTAssertEqual(source.bookSourceType, 0)
        XCTAssertEqual(source.lastUpdateTime, 1_730_000_000_000)
        XCTAssertEqual(source.respondTime, 1500)
        XCTAssertEqual(source.weight, 7)
        XCTAssertTrue(source.enabled)
        XCTAssertFalse(source.enabledExplore)
        XCTAssertEqual(source.customOrder, 1)
    }

    func testBookSourceDefaultWhenNumberMissing() throws {
        let json = #"{"bookSourceName":"缺字段","bookSourceUrl":"https://b.com"}"#
        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.lastUpdateTime, 0)
        XCTAssertEqual(source.respondTime, 180000)
        XCTAssertTrue(source.enabled)
    }
}
