import XCTest
@testable import Legado

/// `mainJs` 纯 JS 单文件书源：搜索 / 详情 / 目录 / 正文全链路。
final class JsSourceTests: XCTestCase {

    private var db: AppDatabase!
    private var settings: AppSettings!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var cookieStore: CookieStore!
    private var httpClient: HTTPClient!
    private var webBook: WebBook!
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(inMemory: true)
        suiteName = "test.jssource.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
        cookieStore = CookieStore(dao: CookieDao(db: db))
        httpClient = HTTPClient(settings: settings, cookieStore: cookieStore)
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado-js-source-\(UUID().uuidString)", isDirectory: true)
        webBook = WebBook(settings: settings, httpClient: httpClient,
                          cookieStore: cookieStore,
                          bookRepository: BookRepository(db: db, settings: settings),
                          chapterCache: ChapterCache(root: cacheRoot))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let cacheRoot { try? FileManager.default.removeItem(at: cacheRoot) }
        webBook = nil
        try super.tearDownWithError()
    }

    private let mainJs = """
    function search(key, page) {
      return [{
        name: key + '书',
        author: '甲',
        bookUrl: 'https://js.test/book/' + page,
        tocUrl: 'https://js.test/toc/' + page,
        intro: '简介',
        kind: '玄幻'
      }];
    }
    function explore(url, page) {
      return [{ name: '发现书', url: 'https://js.test/book/9' }];
    }
    function getBookInfo(book) {
      return { name: '详情名', author: '乙', kind: '武侠', tocUrl: 'https://js.test/toc/1' };
    }
    function getChapters(book) {
      return [
        { name: '第1章', url: '/c/1.html' },
        { title: '第2章', url: 'https://js.test/c/2.html', isVip: true },
        { name: '第一卷', voltype: true }
      ];
    }
    function getContent(chapter, book, nextChapterUrl) {
      return chapter.title + '正文';
    }
    """

    private func makeSource(_ js: String? = nil) -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://js.test"
        source.bookSourceName = "JS源"
        source.bookSourceType = 0
        source.mainJs = js ?? mainJs
        return source
    }

    func testFullPipeline() async throws {
        let source = makeSource()
        let books = try await webBook.searchBook(source, key: "剑来", page: 1)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].name, "剑来书")
        XCTAssertEqual(books[0].author, "甲")
        XCTAssertEqual(books[0].bookUrl, "https://js.test/book/1")
        XCTAssertEqual(books[0].origin, source.bookSourceUrl)
        XCTAssertEqual(books[0].type, BookType.text)

        var book = books[0].toBook()
        book.type = BookType.text
        book = try await webBook.getBookInfo(source, book: book)
        XCTAssertEqual(book.name, "详情名")
        XCTAssertEqual(book.author, "乙")
        XCTAssertEqual(book.kind, "武侠")
        XCTAssertEqual(book.tocUrl, "https://js.test/toc/1")

        let chapters = try await webBook.getChapterList(source, book: book)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "第1章")
        XCTAssertEqual(chapters[0].getAbsoluteURL(), "https://js.test/c/1.html")
        XCTAssertEqual(chapters[1].url, "https://js.test/c/2.html")
        XCTAssertTrue(chapters[1].isVip)
        XCTAssertTrue(chapters[2].isVolume)

        let content = try await webBook.getContent(source, book: book,
                                                   chapter: chapters[0])
        XCTAssertEqual(content, "第1章正文")
        webBook.chapterCache.flush()
        XCTAssertEqual(webBook.chapterCache.load(book: book, chapter: chapters[0]),
                       "第1章正文")
    }

    func testExplore() async throws {
        let source = makeSource()
        let books = try await webBook.exploreBook(source, url: "https://js.test/list", page: 2)
        XCTAssertEqual(books.map(\.name), ["发现书"])
        XCTAssertEqual(books[0].bookUrl, "https://js.test/book/9")
    }

    func testJavaAjaxInsideMainJs() async throws {
        httpClient.hook = HTTPHook(replay: { spec in
            XCTAssertTrue(spec.url.contains("k=%E5%89%91%E6%9D%A5"))
            return StrResponse(url: spec.url,
                               body: "{\"name\":\"远程书\"}",
                               code: 200)
        })
        let js = """
        function search(key, page) {
          var data = JSON.parse(java.ajax('https://js.test/api?k=' + encodeURIComponent(key)));
          return [{ name: data.name, url: 'https://js.test/b/1' }];
        }
        """
        let books = try await webBook.searchBook(makeSource(js), key: "剑来")
        XCTAssertEqual(books.first?.name, "远程书")
    }

    func testMissingFunctionThrows() async {
        let source = makeSource("function explore() { return []; }")
        do {
            _ = try await webBook.searchBook(source, key: "x")
            XCTFail("缺少 search 函数应抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("search"))
        }
    }

    func testMarshallerIgnoresInvalidEntries() {
        let source = makeSource()
        let json = """
        [{"name":"","bookUrl":"https://a.com/1"},
         {"name":"正常","bookUrl":"/b/1"},
         {"name":"无地址"}]
        """
        let books = JsSourceMarshaller.parseBooks(json, source: source)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].bookUrl, "https://js.test/b/1")
    }
}
