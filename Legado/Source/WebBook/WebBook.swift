import Foundation

enum WebBookError: LocalizedError {
    case message(String)
    case emptyToc
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .emptyToc: return "目录列表为空"
        case .emptyContent: return "内容为空"
        }
    }
}

/// 书源业务编排，对齐上游 `WebBook`。
final class WebBook {

    let settings: AppSettings
    let httpClient: HTTPClient
    let cookieStore: CookieStore
    let bookRepository: BookRepository?
    let chapterCache = ChapterCache()

    init(settings: AppSettings, httpClient: HTTPClient, cookieStore: CookieStore,
         bookRepository: BookRepository? = nil) {
        self.settings = settings
        self.httpClient = httpClient
        self.cookieStore = cookieStore
        self.bookRepository = bookRepository
    }

    // MARK: - 规则工厂

    func makeRule(book: Book? = nil, source: BookSource) -> AnalyzeRule {
        let rule = AnalyzeRule(book: book, source: source)
        rule.runtime = .shared
        rule.cookieStore = cookieStore
        rule.httpClient = httpClient
        rule.webJsHandler = { [weak self] js, result in
            guard let self else { return nil }
            var options = WebViewFetcherOptions()
            options.js = js
            options.html = AnalyzeRule.stringValue(result)
            options.headers = source.headerMap(userAgent: self.settings.userAgent)
            options.cookieKeyURL = source.bookSourceUrl
            do {
                let response = try SyncBridge.run { [cookieStore = self.cookieStore] in
                    try await WebViewService.shared.fetch(options, cookieStore: cookieStore, cookieJar: true)
                }
                return response.body
            } catch {
                return nil
            }
        }
        return rule
    }

    private func analyzeUrl(_ url: String, source: BookSource, book: Book? = nil,
                            chapter: BookChapter? = nil, ruleData: RuleData? = nil,
                            page: Int? = nil, key: String? = nil) -> AnalyzeUrl {
        AnalyzeUrl(url: url, key: key, page: page, baseUrl: source.bookSourceUrl,
                   source: source, book: book, chapter: chapter, ruleData: ruleData,
                   httpClient: httpClient, cookieStore: cookieStore, settings: settings)
    }

    /// 登录检测钩子：命中后 JS 需要返回新的响应
    private func applyLoginCheck(_ source: BookSource, _ analyzeUrl: AnalyzeUrl,
                                 _ response: StrResponse) -> StrResponse {
        guard let checkJs = source.loginCheckJs, !checkJs.isBlank else { return response }
        guard let value = analyzeUrl.evalJS(checkJs, result: response) else { return response }
        if let str = value as? StrResponse { return str }
        if let jsr = value as? JSResponse {
            return StrResponse(url: jsr.responseURL, body: jsr.responseBody)
        }
        return response
    }

    // MARK: - 搜索

    func searchBook(_ source: BookSource, key: String, page: Int = 1,
                    filter: ((String, String, String?) -> Bool)? = nil,
                    shouldBreak: ((Int) -> Bool)? = nil) async throws -> [SearchBook] {
        guard let searchUrl = source.searchUrl, !searchUrl.isBlank else {
            throw WebBookError.message("搜索url不能为空")
        }
        let ruleData = RuleData()
        let analyzeUrl = analyzeUrl(searchUrl, source: source, ruleData: ruleData,
                                    page: page, key: key)
        var response = try await analyzeUrl.strResponse()
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)

        return try await BookList.analyzeBookList(
            webBook: self, source: source, ruleData: ruleData, analyzeUrl: analyzeUrl,
            baseUrl: response.url, body: response.body, isSearch: true,
            isRedirect: response.isRedirect, filter: filter, shouldBreak: shouldBreak
        )
    }

    /// 精准搜索（换源 / 重新获取书籍信息）
    func preciseSearch(_ source: BookSource, name: String, author: String) async throws -> Book {
        let results = try await searchBook(source, key: name, filter: { fName, fAuthor, _ in
            fName == name && fAuthor == author
        }, shouldBreak: { $0 > 0 })
        guard let first = results.first else {
            throw WebBookError.message("未搜索到 \(name)(\(author)) 书籍")
        }
        return first.toBook()
    }

    // MARK: - 发现

    func exploreBook(_ source: BookSource, url: String, page: Int = 1) async throws -> [SearchBook] {
        let ruleData = RuleData()
        let analyzeUrl = analyzeUrl(url, source: source, ruleData: ruleData, page: page)
        var response = try await analyzeUrl.strResponse()
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)

        return try await BookList.analyzeBookList(
            webBook: self, source: source, ruleData: ruleData, analyzeUrl: analyzeUrl,
            baseUrl: response.url, body: response.body, isSearch: false,
            isRedirect: response.isRedirect
        )
    }

    // MARK: - 详情

    func getBookInfo(_ source: BookSource, book: Book, canReName: Bool = true) async throws -> Book {
        var book = book
        if let html = book.infoHtml, !html.isEmpty {
            BookInfo.analyze(webBook: self, source: source, book: &book,
                             baseUrl: book.bookUrl, redirectUrl: book.bookUrl,
                             body: html, canReName: canReName)
            return book
        }
        let analyzeUrl = analyzeUrl(book.bookUrl, source: source, book: book)
        var response = try await analyzeUrl.strResponse()
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)
        BookInfo.analyze(webBook: self, source: source, book: &book,
                         baseUrl: book.bookUrl, redirectUrl: response.url,
                         body: response.body, canReName: canReName)
        return book
    }

    // MARK: - 目录

    func getChapterList(_ source: BookSource, book: Book, runPreUpdateJs shouldRunPreUpdateJs: Bool = false) async throws -> [BookChapter] {
        if shouldRunPreUpdateJs {
            try await runPreUpdateJs(source: source, book: book)
        }
        if book.bookUrl == book.tocUrl, let html = book.tocHtml, !html.isEmpty {
            return try await BookChapterList.analyze(webBook: self, source: source, book: book,
                                                     baseUrl: book.tocUrl, redirectUrl: book.tocUrl,
                                                     body: html)
        }
        let analyzeUrl = analyzeUrl(book.tocUrl, source: source, book: book)
        var response = try await analyzeUrl.strResponse()
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)
        return try await BookChapterList.analyze(webBook: self, source: source, book: book,
                                                 baseUrl: book.tocUrl, redirectUrl: response.url,
                                                 body: response.body)
    }

    private func runPreUpdateJs(source: BookSource, book: Book) async throws {
        guard let js = source.tocRule.preUpdateJs, !js.isBlank else { return }
        let rule = AnalyzeRule(book: book, source: source, preUpdateJs: true)
        rule.runtime = .shared
        rule.cookieStore = cookieStore
        rule.httpClient = httpClient
        rule.refreshTocHandler = { [weak self] in
            guard let self else { return }
            _ = try? SyncBridge.run {
                _ = try await self.getBookInfo(source, book: book, canReName: false)
            }
        }
        _ = rule.evalJS(js)
    }

    // MARK: - 正文

    func getContent(_ source: BookSource, book: Book, chapter: BookChapter,
                    nextChapterUrl: String? = nil, needSave: Bool = true) async throws -> String {
        guard let contentRule = source.ruleContent?.content, !contentRule.isEmpty else {
            DebugLog.shared.log(source.bookSourceUrl, "⇒正文规则为空,使用章节链接:\(chapter.url)")
            return chapter.url
        }
        if chapter.isVolume && chapter.url.hasPrefix(chapter.title) {
            return chapter.tag ?? ""
        }

        if chapter.url == book.bookUrl, let html = book.tocHtml, !html.isEmpty {
            return try await BookContent.analyze(webBook: self, source: source, book: book,
                                                 chapter: chapter,
                                                 baseUrl: chapter.getAbsoluteURL(),
                                                 redirectUrl: chapter.getAbsoluteURL(),
                                                 body: html, nextChapterUrl: nextChapterUrl,
                                                 needSave: needSave)
        }

        let analyzeUrl = analyzeUrl(chapter.getAbsoluteURL(), source: source, book: book,
                                    chapter: chapter)
        var response = try await analyzeUrl.strResponse(
            useWebView: true,
            sourceRegex: source.contentRule.sourceRegex
        )
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)

        return try await BookContent.analyze(webBook: self, source: source, book: book,
                                             chapter: chapter,
                                             baseUrl: chapter.getAbsoluteURL(),
                                             redirectUrl: response.url,
                                             body: response.body,
                                             nextChapterUrl: nextChapterUrl,
                                             needSave: needSave)
    }

    // MARK: - 工具

    func nextChapterUrl(book: Book, chapter: BookChapter) -> String? {
        guard let repository = bookRepository else { return nil }
        if let next = repository.chapter(book: book, index: chapter.index + 1)?.url { return next }
        return repository.chapter(book: book, index: 0)?.url
    }

    func saveContent(_ content: String, book: Book, chapter: BookChapter) {
        chapterCache.save(content, book: book, chapter: chapter)
    }

    private func logRedirect(_ source: BookSource, _ response: StrResponse) {
        guard response.isRedirect else { return }
        DebugLog.shared.log(source.bookSourceUrl, "≡检测到重定向(\(response.priorUrl ?? ""))")
        DebugLog.shared.log(source.bookSourceUrl, "┌重定向后地址")
        DebugLog.shared.log(source.bookSourceUrl, "└\(response.url)")
    }
}

/// 章节正文缓存（对齐上游按书分目录缓存正文的做法）
final class ChapterCache {
    private let queue = DispatchQueue(label: "legado.chapter.cache", qos: .utility)

    private var root: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func url(book: Book, chapter: BookChapter) -> URL {
        let bookDir = root.appendingPathComponent(CryptoUtils.md5(book.bookUrl), isDirectory: true)
        try? FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        return bookDir.appendingPathComponent(chapter.fileName() + ".txt")
    }

    func save(_ content: String, book: Book, chapter: BookChapter) {
        let target = url(book: book, chapter: chapter)
        queue.async {
            try? content.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    func load(book: Book, chapter: BookChapter) -> String? {
        try? String(contentsOf: url(book: book, chapter: chapter), encoding: .utf8)
    }

    func remove(book: Book) {
        let dir = root.appendingPathComponent(CryptoUtils.md5(book.bookUrl), isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}
