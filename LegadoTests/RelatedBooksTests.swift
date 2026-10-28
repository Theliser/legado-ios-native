import XCTest
@testable import Legado

/// `ruleBookInfo.relatedBooks`：按模块请求发现页、过滤当前书籍、单个模块失败不影响其他模块。
final class RelatedBooksTests: XCTestCase {

    private var db: AppDatabase!
    private var settings: AppSettings!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var cookieStore: CookieStore!
    private var httpClient: HTTPClient!
    private var webBook: WebBook!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(inMemory: true)
        suiteName = "test.related.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
        cookieStore = CookieStore(dao: CookieDao(db: db))
        httpClient = HTTPClient(settings: settings, cookieStore: cookieStore)
        webBook = WebBook(settings: settings, httpClient: httpClient,
                          cookieStore: cookieStore,
                          bookRepository: BookRepository(db: db, settings: settings))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        webBook = nil
        try super.tearDownWithError()
    }

    private let listHTML = """
    <html><body>
      <div class="result"><a class="title" href="/book/1.html">剑来</a>
        <span class="author">烽火戏诸侯</span></div>
      <div class="result"><a class="title" href="/book/2.html">雪中悍刀行</a>
        <span class="author">烽火戏诸侯</span></div>
    </body></html>
    """

    private func makeSource(related: String?) -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://demo.test"
        source.bookSourceName = "关联源"

        var search = SearchRule()
        search.bookList = "class.result"
        search.name = "class.title@text"
        search.bookUrl = "class.title@href"
        search.author = "class.author@text"
        source.ruleSearch = search

        var info = BookInfoRule()
        info.relatedBooks = related
        source.ruleBookInfo = info
        return source
    }

    private func makeBook() -> Book {
        var book = Book()
        book.bookUrl = "https://demo.test/book/1.html"
        book.origin = "https://demo.test"
        book.name = "剑来"
        return book
    }

    func testLoadsModuleAndFiltersCurrentBook() async {
        httpClient.hook = HTTPHook(replay: { spec in
            guard spec.url.contains("/author/ok") else {
                return StrResponse(url: spec.url, body: nil, code: 500)
            }
            return StrResponse(url: spec.url, body: self.listHTML, code: 200)
        })

        let json = """
        [{"key":"sameAuthor","title":"同作者","url":"https://demo.test/author/ok"},
         {"title":"坏模块","url":"https://demo.test/boom"}]
        """
        let modules = await RelatedBooks.load(webBook: webBook,
                                              source: makeSource(related: json),
                                              book: makeBook())
        XCTAssertEqual(modules.count, 1)
        XCTAssertEqual(modules[0].key, "sameAuthor")
        XCTAssertEqual(modules[0].title, "同作者")
        // 当前书籍自身要被过滤
        XCTAssertEqual(modules[0].books.map(\.name), ["雪中悍刀行"])
        XCTAssertTrue(modules[0].resolvedUrl.contains("/author/ok"))
    }

    func testInvalidConfigReturnsEmpty() async {
        let modules = await RelatedBooks.load(webBook: webBook,
                                              source: makeSource(related: "not json"),
                                              book: makeBook())
        XCTAssertTrue(modules.isEmpty)
    }

    func testEmptyUrlIsSkipped() async {
        let json = """
        [{"key":"a","title":"空","url":"   "},
         {"key":"b","title":"正常","url":"https://demo.test/author/ok"}]
        """
        httpClient.hook = HTTPHook(replay: { spec in
            StrResponse(url: spec.url, body: self.listHTML, code: 200)
        })
        let modules = await RelatedBooks.load(webBook: webBook,
                                              source: makeSource(related: json),
                                              book: makeBook())
        XCTAssertEqual(modules.map(\.key), ["b"])
    }

    func testParseDefinitionsKeepsOrder() {
        let json = """
        [{"key":"k1","title":"一","url":"/a"},
         {"title":"二","url":"/b"}]
        """
        let definitions = RelatedBooks.parseDefinitions(json)
        XCTAssertEqual(definitions?.count, 2)
        XCTAssertEqual(definitions?[0].key, "k1")
        XCTAssertEqual(definitions?[1].title, "二")
        XCTAssertNil(RelatedBooks.parseDefinitions("{}"))
    }
}
