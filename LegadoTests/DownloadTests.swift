import XCTest
@testable import Legado

/// P4：整本下载（章节缓存 + 失败隔离 + 跳过已有缓存）。
final class DownloadTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [String] = []
        private(set) var progress: [DownloadProgress] = []
        func add(_ url: String) { lock.lock(); urls.append(url); lock.unlock() }
        func add(_ value: DownloadProgress) { lock.lock(); progress.append(value); lock.unlock() }
        func resetURLs() { lock.lock(); urls.removeAll(); lock.unlock() }
    }

    private var db: AppDatabase!
    private var settings: AppSettings!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var cookieStore: CookieStore!
    private var httpClient: HTTPClient!
    private var webBook: WebBook!
    private var cacheRoot: URL!
    private var counter: Counter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(inMemory: true)
        suiteName = "test.download.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
        cookieStore = CookieStore(dao: CookieDao(db: db))
        httpClient = HTTPClient(settings: settings, cookieStore: cookieStore)
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado-download-\(UUID().uuidString)", isDirectory: true)
        webBook = WebBook(settings: settings, httpClient: httpClient,
                          cookieStore: cookieStore,
                          bookRepository: BookRepository(db: db, settings: settings),
                          chapterCache: ChapterCache(root: cacheRoot))
        counter = Counter()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let cacheRoot { try? FileManager.default.removeItem(at: cacheRoot) }
        webBook = nil
        try super.tearDownWithError()
    }

    private func makeSource() -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://demo.test"
        source.bookSourceName = "下载源"
        var content = ContentRule()
        content.content = "#content@text"
        source.ruleContent = content
        return source
    }

    private func makeBook() -> Book {
        var book = Book()
        book.bookUrl = "https://demo.test/book/1"
        book.tocUrl = "https://demo.test/book/1"
        book.origin = "https://demo.test"
        book.name = "下载书"
        book.type = BookType.text
        return book
    }

    private func makeChapters() -> [BookChapter] {
        (0..<3).map { index in
            var chapter = BookChapter(bookUrl: "https://demo.test/book/1",
                                      baseUrl: "https://demo.test/book/1")
            chapter.title = "第\(index + 1)章"
            chapter.url = "/c/\(index + 1).html"
            chapter.index = index
            return chapter
        }
    }

    /// 前两章有正文，第三章返回空内容（模拟站点改版 / 付费章）
    private func installHook() {
        let counter = self.counter!
        httpClient.hook = HTTPHook(replay: { spec in
            counter.add(spec.url)
            if spec.url.contains("/c/3.html") {
                return StrResponse(url: spec.url,
                                   body: "<html><body><div id=\"content\"></div></body></html>",
                                   code: 200)
            }
            let index = spec.url.contains("/c/1.html") ? 1 : 2
            return StrResponse(url: spec.url,
                               body: "<html><body><div id=\"content\">正文\(index)</div></body></html>",
                               code: 200)
        })
    }

    func testDownloadCachesChaptersAndIsolatesFailures() async {
        installHook()
        let source = makeSource()
        let book = makeBook()
        let chapters = makeChapters()
        let counter = self.counter!

        let summary = await BookDownloader(webBook: webBook, concurrency: 2)
            .download(book: book, source: source, chapters: chapters,
                      progress: { counter.add($0) })

        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.completed, 2)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.failures.first?.index, 2)
        XCTAssertTrue(webBook.chapterCache.has(book: book, chapter: chapters[0]))
        XCTAssertEqual(webBook.chapterCache.load(book: book, chapter: chapters[1]), "正文2")
        XCTAssertEqual(counter.urls.count, 3)
        XCTAssertEqual(counter.progress.last?.completed, 2)
        XCTAssertEqual(counter.progress.last?.failed, 1)
    }

    func testSecondRunSkipsCachedChapters() async {
        installHook()
        let source = makeSource()
        let book = makeBook()
        let chapters = makeChapters()
        let counter = self.counter!
        let downloader = BookDownloader(webBook: webBook, concurrency: 2)

        _ = await downloader.download(book: book, source: source, chapters: chapters)
        counter.resetURLs()

        let summary = await downloader.download(book: book, source: source, chapters: chapters)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(summary.completed, 2)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(counter.urls.count, 1, "只应重试失败的那一章")
        XCTAssertTrue(counter.urls[0].contains("/c/3.html"))
    }

    func testForceRedownloadsAll() async {
        installHook()
        let source = makeSource()
        let book = makeBook()
        let chapters = makeChapters()
        let counter = self.counter!
        let downloader = BookDownloader(webBook: webBook, concurrency: 3)

        _ = await downloader.download(book: book, source: source, chapters: chapters)
        counter.resetURLs()

        _ = await downloader.download(book: book, source: source, chapters: chapters, force: true)
        XCTAssertEqual(counter.urls.count, 3)
    }

    func testClearCacheRemovesBookDirectory() async {
        installHook()
        let source = makeSource()
        let book = makeBook()
        let chapters = makeChapters()
        let downloader = BookDownloader(webBook: webBook, concurrency: 2)
        _ = await downloader.download(book: book, source: source, chapters: chapters)
        XCTAssertTrue(webBook.chapterCache.has(book: book, chapter: chapters[0]))

        downloader.clearCache(book: book)
        XCTAssertFalse(webBook.chapterCache.has(book: book, chapter: chapters[0]))
    }
}
