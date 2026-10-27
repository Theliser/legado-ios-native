import XCTest
@testable import Legado

/// 书源解析链路：搜索/发现 → 详情 → 目录 → 正文。
/// 全部用固定 HTML 样本，不联网，验证规则语义与上游一致。
final class SourceParseTests: XCTestCase {

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
        suiteName = "test.parse.\(UUID().uuidString)"
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

    // MARK: - 样本

    private let searchHTML = """
    <html><body>
    <div class="result">
      <a class="title" href="/book/1.html">剑来</a>
      <span class="author">烽火戏诸侯</span>
      <span class="kind">玄幻</span>
      <span class="last">第一章 惊蛰</span>
    </div>
    <div class="result">
      <a class="title" href="/book/2.html">雪中悍刀行</a>
      <span class="author">烽火戏诸侯</span>
      <span class="kind">武侠</span>
      <span class="last">第一章 小年</span>
    </div>
    </body></html>
    """

    private let infoHTML = """
    <html><body>
    <h1 class="name">剑来</h1>
    <p class="author">作者：烽火戏诸侯</p>
    <div class="intro">大千世界，无奇不有。</div>
    <a class="toc" href="/book/1/toc.html">目录</a>
    </body></html>
    """

    private let tocHTML = """
    <html><body><dl>
      <dd><a href="/c/1.html">第1章 惊蛰</a></dd>
      <dd><a href="/c/2.html">第2章 开门</a></dd>
      <dd><a href="/c/3.html">第3章 日出</a></dd>
    </dl></body></html>
    """

    private let contentHTML = """
    <html><body><div id="content"><p>第一段正文</p><p>第二段正文</p></div></body></html>
    """

    /// 一份完整的书源，规则全部指向上面的样本结构
    private func makeSource() -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://demo.test"
        source.bookSourceName = "演示源"

        var search = SearchRule()
        search.bookList = "class.result"
        search.name = "class.title@text"
        search.bookUrl = "class.title@href"
        search.author = "class.author@text"
        search.kind = "class.kind@text"
        search.lastChapter = "class.last@text"
        source.ruleSearch = search

        var info = BookInfoRule()
        info.name = "class.name@text"
        info.author = "class.author@text"
        info.intro = "class.intro@text"
        info.tocUrl = "class.toc@href"
        source.ruleBookInfo = info

        var toc = TocRule()
        toc.chapterList = "dd"
        toc.chapterName = "a@text"
        toc.chapterUrl = "a@href"
        source.ruleToc = toc

        var content = ContentRule()
        content.content = "#content@text"
        source.ruleContent = content

        return source
    }

    private func makeAnalyzeUrl(_ url: String, source: BookSource) -> AnalyzeUrl {
        AnalyzeUrl(url: url, source: source, httpClient: httpClient,
                   cookieStore: cookieStore, settings: settings)
    }

    // MARK: - 搜索

    func testSearchParsesBookList() async throws {
        let source = makeSource()
        let ruleData = RuleData()
        let analyzeUrl = makeAnalyzeUrl("https://demo.test/search?q=剑来", source: source)

        let books = try await BookList.analyzeBookList(
            webBook: webBook, source: source, ruleData: ruleData,
            analyzeUrl: analyzeUrl, baseUrl: "https://demo.test/search?q=剑来",
            body: searchHTML, isSearch: true)

        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books[0].name, "剑来")
        XCTAssertEqual(books[0].author, "烽火戏诸侯")
        XCTAssertEqual(books[0].kind, "玄幻")
        XCTAssertEqual(books[0].latestChapterTitle, "第一章 惊蛰")
        // 相对地址要按 baseUrl 补全
        XCTAssertEqual(books[0].bookUrl, "https://demo.test/book/1.html")
        XCTAssertEqual(books[0].origin, "https://demo.test")
        XCTAssertEqual(books[1].name, "雪中悍刀行")
    }

    func testSearchUsesExploreRuleWhenBookListMissing() async throws {
        var source = makeSource()
        source.searchRule.bookList = nil
        var explore = ExploreRule()
        explore.bookList = "class.result"
        explore.name = "class.title@text"
        explore.bookUrl = "class.title@href"
        source.ruleExplore = explore

        let books = try await BookList.analyzeBookList(
            webBook: webBook, source: source, ruleData: RuleData(),
            analyzeUrl: makeAnalyzeUrl("https://demo.test/list", source: source),
            baseUrl: "https://demo.test/list", body: searchHTML, isSearch: false)

        XCTAssertEqual(books.count, 2, "发现规则缺 bookList 时应回退到搜索规则；反过来亦然")
    }

    // MARK: - 详情

    func testBookInfoParsesFields() {
        let source = makeSource()
        var book = Book()
        book.bookUrl = "https://demo.test/book/1.html"
        book.origin = source.bookSourceUrl
        book.type = BookType.text

        BookInfo.analyze(webBook: webBook, source: source, book: &book,
                         baseUrl: "https://demo.test/book/1.html",
                         redirectUrl: "https://demo.test/book/1.html",
                         body: infoHTML, canReName: true)

        XCTAssertEqual(book.name, "剑来")
        // 作者字段的「作者：」前缀要被清掉
        XCTAssertEqual(book.author, "烽火戏诸侯")
        XCTAssertEqual(book.intro, "大千世界，无奇不有。")
        XCTAssertEqual(book.tocUrl, "https://demo.test/book/1/toc.html")
    }

    func testBookInfoSkipsTocForWebFileSource() {
        var source = makeSource()
        source.bookSourceType = 3          // 文件型
        var info = BookInfoRule()
        info.name = "class.name@text"
        info.tocUrl = "class.toc@href"
        info.downloadUrls = "a.download@href"
        source.ruleBookInfo = info

        var book = Book()
        book.bookUrl = "https://demo.test/book/1.html"
        book.type = source.bookType        // text | webFile

        let html = """
        <html><body><h1 class="name">剑来</h1>
        <a class="download" href="/dl/1.txt">下载</a></body></html>
        """
        BookInfo.analyze(webBook: webBook, source: source, book: &book,
                         baseUrl: book.bookUrl, redirectUrl: book.bookUrl,
                         body: html, canReName: false)

        XCTAssertEqual(book.tocUrl, "", "文件型书源不该去解析目录地址")
        XCTAssertEqual(book.downloadUrls, ["https://demo.test/dl/1.txt"])
    }

    // MARK: - 目录

    func testTocOrderDedupAndIndex() async throws {
        let source = makeSource()
        var book = Book()
        book.bookUrl = "https://demo.test/book/1.html"
        book.tocUrl = "https://demo.test/book/1/toc.html"
        book.type = BookType.text

        let chapters = try await BookChapterList.analyze(
            webBook: webBook, source: source, book: book,
            baseUrl: book.tocUrl, redirectUrl: book.tocUrl, body: tocHTML)

        XCTAssertEqual(chapters.count, 3)
        // 站点是正序给出，上游会先 reverse 再按 reverseToc 反转回来 → 最终仍是正序
        XCTAssertEqual(chapters.map(\.title), ["第1章 惊蛰", "第2章 开门", "第3章 日出"])
        XCTAssertEqual(chapters.map(\.index), [0, 1, 2])
        // 上游 chapterUrl 规则不补全地址，章节里存相对路径，
        // 真正读取时用 getAbsoluteURL() 按 baseUrl 拼
        XCTAssertEqual(chapters[0].url, "/c/1.html")
        XCTAssertEqual(chapters[0].getAbsoluteURL(), "https://demo.test/c/1.html")
        XCTAssertEqual(chapters[0].bookUrl, book.bookUrl)
        XCTAssertTrue(chapters.allSatisfy { $0.baseUrl == book.tocUrl })
    }

    func testTocReversePrefixFlipsSiteOrder() async throws {
        // `-` 前缀表示站点给的是倒序（最新在前），解析后要把顺序翻过来。
        // 不加前缀时「先 reverse 再按 reverseToc reverse」互相抵消，等于保持站点原序。
        var source = makeSource()
        source.tocRule.chapterList = "-dd"
        var book = Book()
        book.bookUrl = "https://demo.test/book/1.html"
        book.tocUrl = "https://demo.test/book/1/toc.html"
        book.type = BookType.text

        let chapters = try await BookChapterList.analyze(
            webBook: webBook, source: source, book: book,
            baseUrl: book.tocUrl, redirectUrl: book.tocUrl, body: tocHTML)
        XCTAssertEqual(chapters.map(\.title), ["第3章 日出", "第2章 开门", "第1章 惊蛰"])
        XCTAssertEqual(chapters.map(\.index), [0, 1, 2])
    }

    func testTocDedupByUrlAndTitle() async throws {
        let source = makeSource()
        var book = Book()
        book.bookUrl = "b"; book.tocUrl = "t"; book.type = BookType.text
        let dupHTML = """
        <dl>
          <dd><a href="/c/1.html">第1章</a></dd>
          <dd><a href="/c/1.html">第1章</a></dd>
          <dd><a href="/c/2.html">第2章</a></dd>
        </dl>
        """
        let chapters = try await BookChapterList.analyze(
            webBook: webBook, source: source, book: book,
            baseUrl: "t", redirectUrl: "t", body: dupHTML)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters.map(\.index), [0, 1])
    }

    func testTocEmptyThrows() async {
        let source = makeSource()
        var book = Book()
        book.bookUrl = "b"; book.tocUrl = "t"; book.type = BookType.text
        do {
            _ = try await BookChapterList.analyze(
                webBook: webBook, source: source, book: book,
                baseUrl: "t", redirectUrl: "t", body: "<html><body></body></html>")
            XCTFail("空目录应当抛错")
        } catch {
            XCTAssertTrue(error is WebBookError)
        }
    }

    // MARK: - 正文

    func testContentParseAndIndent() async throws {
        let source = makeSource()
        var book = Book()
        book.bookUrl = "https://demo.test/book/1.html"
        book.type = BookType.text
        var chapter = BookChapter()
        chapter.bookUrl = book.bookUrl
        chapter.url = "https://demo.test/c/1.html"
        chapter.baseUrl = book.bookUrl
        chapter.title = "第1章 惊蛰"

        let text = try await BookContent.analyze(
            webBook: webBook, source: source, book: book, chapter: chapter,
            baseUrl: chapter.url, redirectUrl: chapter.url,
            body: contentHTML, nextChapterUrl: nil, needSave: false)

        XCTAssertTrue(text.contains("第一段正文"))
        XCTAssertTrue(text.contains("第二段正文"))
    }

    func testContentReplaceRegexAddsFullWidthIndent() async throws {
        var source = makeSource()
        var content = ContentRule()
        content.content = "#content@text"
        // ##正则##：把「广告」整段去掉，非空替换规则会给每行补全角缩进
        content.replaceRegex = "##广告##"
        source.ruleContent = content

        var book = Book()
        book.bookUrl = "b"; book.type = BookType.text
        var chapter = BookChapter()
        chapter.bookUrl = "b"; chapter.url = "u"; chapter.baseUrl = "b"

        let html = """
        <html><body><div id="content">第一行广告<br/>第二行</div></body></html>
        """
        let text = try await BookContent.analyze(
            webBook: webBook, source: source, book: book, chapter: chapter,
            baseUrl: "https://demo.test/c/1", redirectUrl: "https://demo.test/c/1",
            body: html, nextChapterUrl: nil, needSave: false)

        XCTAssertFalse(text.contains("广告"))
        XCTAssertTrue(text.hasPrefix("　　"), "替换规则生效后每行要补全角缩进")
    }

    func testContentEmptyThrowsUnlessVolume() async {
        let source = makeSource()
        var book = Book()
        book.bookUrl = "b"; book.type = BookType.text
        var chapter = BookChapter()
        chapter.bookUrl = "b"; chapter.url = "u"; chapter.baseUrl = "b"

        do {
            _ = try await BookContent.analyze(
                webBook: webBook, source: source, book: book, chapter: chapter,
                baseUrl: "u", redirectUrl: "u",
                body: "<html><body><div id='content'></div></body></html>",
                nextChapterUrl: nil, needSave: false)
            XCTFail("正文为空应当抛错")
        } catch {
            XCTAssertTrue(error is WebBookError)
        }

        // 卷标题章节允许为空
        chapter.isVolume = true
        let text = try? await BookContent.analyze(
            webBook: webBook, source: source, book: book, chapter: chapter,
            baseUrl: "u", redirectUrl: "u",
            body: "<html><body><div id='content'></div></body></html>",
            nextChapterUrl: nil, needSave: false)
        XCTAssertEqual(text, "")
    }

    // MARK: - 端到端：搜索 → 详情 → 目录 → 正文

    func testFullChainProducesConsistentData() async throws {
        let source = makeSource()
        let repo = BookSourceRepository(db: db)
        XCTAssertTrue(repo.save(source))

        // 1. 搜索
        let results = try await BookList.analyzeBookList(
            webBook: webBook, source: source, ruleData: RuleData(),
            analyzeUrl: makeAnalyzeUrl("https://demo.test/search", source: source),
            baseUrl: "https://demo.test/search", body: searchHTML, isSearch: true)
        XCTAssertEqual(results.count, 2)

        // 2. 加入书架
        let bookRepo = BookRepository(db: db, settings: settings)
        let book = bookRepo.addToShelf(results[0])
        XCTAssertEqual(book.name, "剑来")
        XCTAssertEqual(bookRepo.books.count, 1)

        // 3. 详情
        var detailed = book
        BookInfo.analyze(webBook: webBook, source: source, book: &detailed,
                         baseUrl: book.bookUrl, redirectUrl: book.bookUrl,
                         body: infoHTML, canReName: true)
        bookRepo.save(detailed)
        XCTAssertEqual(bookRepo.book(book.bookUrl)?.tocUrl,
                       "https://demo.test/book/1/toc.html")

        // 4. 目录
        let chapters = try await BookChapterList.analyze(
            webBook: webBook, source: source, book: detailed,
            baseUrl: detailed.tocUrl, redirectUrl: detailed.tocUrl, body: tocHTML)
        bookRepo.replaceChapters(chapters, of: detailed.bookUrl)
        XCTAssertEqual(bookRepo.chapters(of: detailed).count, 3)

        // 5. 正文
        let text = try await BookContent.analyze(
            webBook: webBook, source: source, book: detailed, chapter: chapters[0],
            baseUrl: chapters[0].url, redirectUrl: chapters[0].url,
            body: contentHTML, nextChapterUrl: chapters[1].url, needSave: false)
        XCTAssertTrue(text.contains("第一段正文"))
    }
}
