import XCTest
@testable import Legado

/// P2 的 `imageStyle` / `imageDecode` / `callBackJs`。
final class ContentExtrasTests: XCTestCase {

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
        suiteName = "test.extras.\(UUID().uuidString)"
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

    private func makeSource() -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://demo.test"
        source.bookSourceName = "扩展源"
        return source
    }

    // MARK: - imageStyle

    func testApplyImageStyleToBookConfig() {
        var source = makeSource()
        var contentRule = ContentRule()
        contentRule.imageStyle = "FULL"
        source.ruleContent = contentRule

        var book = Book()
        book.bookUrl = "https://demo.test/book/1"
        book.applyContentRule(source.ruleContent)
        XCTAssertEqual(book.imageStyle, "FULL")
        XCTAssertEqual(book.readConfigObject["imageStyle"] as? String, "FULL")

        // 空规则不覆盖已有样式
        var empty = ContentRule()
        empty.imageStyle = ""
        book.applyContentRule(empty)
        XCTAssertEqual(book.imageStyle, "FULL")

        book.imageStyle = nil
        XCTAssertNil(book.imageStyle)
    }

    // MARK: - imageDecode

    func testImageDecodeRunsJSWithByteArray() {
        var source = makeSource()
        var rule = ContentRule()
        // 每个字节 +1，验证 result 是 JS 可读写的字节数组
        rule.imageDecode = """
        var out = [];
        for (var i = 0; i < result.length; i++) out.push((result[i] + 1) % 256);
        out;
        """
        source.ruleContent = rule

        let data = Data([1, 2, 3, 255])
        let decoded = ImageDecodeService.decode(src: "https://demo.test/1.jpg",
                                                data: data, isCover: false,
                                                source: source, book: nil,
                                                webBook: webBook)
        XCTAssertEqual(decoded, Data([2, 3, 4, 0]))
    }

    func testImageDecodeWithoutRuleIsNoop() {
        let source = makeSource()
        let data = Data([9, 9])
        XCTAssertNil(ImageDecodeService.rule(source: source, isCover: false))
        XCTAssertNil(ImageDecodeService.decode(src: "x", data: data, isCover: false,
                                               source: source, book: nil, webBook: webBook))
        XCTAssertEqual(ImageDecodeService.decodeIfNeeded(src: "x", data: data, isCover: false,
                                                         source: source, book: nil,
                                                         webBook: webBook), data)
    }

    func testCoverDecodeJsTakesPrecedence() {
        var source = makeSource()
        source.coverDecodeJs = "result"
        var rule = ContentRule()
        rule.imageDecode = "java.strToBytes('wrong')"
        source.ruleContent = rule

        let data = Data([7, 8])
        let decoded = ImageDecodeService.decode(src: "cover.jpg", data: data, isCover: true,
                                                source: source, book: nil, webBook: webBook)
        XCTAssertEqual(decoded, data)
    }

    func testFetchImageDataAppliesDecodeRule() async {
        var source = makeSource()
        var rule = ContentRule()
        rule.imageDecode = """
        var out = [];
        for (var i = 0; i < result.length; i++) out.push(result[i] ^ 0xFF);
        out;
        """
        source.ruleContent = rule
        httpClient.hook = HTTPHook(replay: { spec in
            var response = StrResponse(url: spec.url, body: "", code: 200)
            response.data = Data([0x00, 0xFF, 0x0F])
            return response
        })
        let data = await webBook.fetchImageData("https://demo.test/1.jpg", source: source)
        XCTAssertEqual(data, Data([0xFF, 0x00, 0xF0]))
    }

    // MARK: - callBackJs

    func testCallBackReceivesEventAndResult() {
        var source = makeSource()
        source.eventListener = true
        var rule = ContentRule()
        rule.callBackJs = """
        event === 'addBookShelf' && result === 'ok' && book.name === '剑来' && chapter.title === '第1章'
        """
        source.ruleContent = rule

        var book = Book()
        book.bookUrl = "https://demo.test/book/1"
        book.name = "剑来"
        var chapter = BookChapter(bookUrl: book.bookUrl, baseUrl: book.bookUrl)
        chapter.title = "第1章"

        XCTAssertTrue(SourceCallBack.run(SourceCallBackEvent.addBookShelf,
                                         source: source, book: book, chapter: chapter,
                                         result: "ok", webBook: webBook))
        XCTAssertFalse(SourceCallBack.run(SourceCallBackEvent.delBookShelf,
                                          source: source, book: book, chapter: chapter,
                                          result: "ok", webBook: webBook))
    }

    func testCallBackRequiresEventListener() {
        var source = makeSource()
        source.eventListener = false
        var rule = ContentRule()
        rule.callBackJs = "true"
        source.ruleContent = rule
        XCTAssertFalse(SourceCallBack.run(SourceCallBackEvent.addBookShelf,
                                          source: source, book: Book(), webBook: webBook))
    }
}
