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

/// 解析阶段。rawValue 与上游 `Debug` 的 state 编码一致（10/20/30/40）。
enum SourceStage: Int, CaseIterable, Identifiable {
    case search = 10
    case info = 20
    case toc = 30
    case content = 40

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .search: return "搜索"
        case .info: return "详情"
        case .toc: return "目录"
        case .content: return "正文"
        }
    }
}

/// 一次阶段执行的回显，供调试页 / 巡检使用。
struct SourceTrace: Equatable {
    var stage: SourceStage
    var url: String
    var code: Int = 0
    /// 原始响应（正文可能很大，调用方自行截断展示）
    var body: String?
    var elapsedMs: Int = 0
    var error: String?
    /// 给调试页看的一句话结论
    var summary: String = ""

    var isSuccess: Bool { error == nil }
}

/// 书源业务编排，对齐上游 `WebBook`。
final class WebBook {

    /// 阶段追踪。设置后在每个阶段完成时回调（调试页与巡检共用）。
    var trace: ((SourceTrace) -> Void)?

    let settings: AppSettings
    let httpClient: HTTPClient
    let cookieStore: CookieStore
    let bookRepository: BookRepository?
    let chapterCache: ChapterCache

    init(settings: AppSettings, httpClient: HTTPClient, cookieStore: CookieStore,
         bookRepository: BookRepository? = nil, chapterCache: ChapterCache = ChapterCache()) {
        self.settings = settings
        self.httpClient = httpClient
        self.cookieStore = cookieStore
        self.bookRepository = bookRepository
        self.chapterCache = chapterCache
    }

    private func emit(_ event: SourceTrace) {
        trace?(event)
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    /// 统一包装阶段执行：成功与失败都发一条 trace。
    /// 失败时也带上响应体 —— 调试「解析抛错」必须先能看见原始页面，
    /// 否则只能靠猜是站点改版还是规则写错。
    private func traced<T>(_ stage: SourceStage, url: String, code: Int, body: String?,
                           started: Date, describe: (T) -> String,
                           _ work: () async throws -> T) async throws -> T {
        do {
            let value = try await work()
            emit(SourceTrace(stage: stage, url: url, code: code, body: body,
                             elapsedMs: elapsedMs(since: started), summary: describe(value)))
            return value
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            emit(SourceTrace(stage: stage, url: url, code: code, body: body,
                             elapsedMs: elapsedMs(since: started), error: text,
                             summary: "失败"))
            throw error
        }
    }

    // MARK: - 规则工厂

    func makeRule(book: Book? = nil, source: BookSource) -> AnalyzeRule {
        let rule = AnalyzeRule(book: book, source: source)
        rule.runtime = .shared
        rule.cookieStore = cookieStore
        rule.httpClient = httpClient
        rule.settings = settings
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
        if source.isJsSource {
            let started = Date()
            return try await traced(.search, url: source.bookSourceUrl, code: 0,
                                    body: nil, started: started,
                                    describe: { $0.isEmpty ? "无结果" : "命中 \($0.count) 本" }) {
                var books = try JsSourceEngine(webBook: self, source: source)
                    .search(key: key, page: page)
                if let filter {
                    books = books.filter { filter($0.name, $0.author, $0.kind) }
                }
                _ = shouldBreak
                return books
            }
        }
        guard let searchUrl = source.searchUrl, !searchUrl.isBlank else {
            throw WebBookError.message("搜索url不能为空")
        }
        let ruleData = RuleData()
        let analyzeUrl = analyzeUrl(searchUrl, source: source, ruleData: ruleData,
                                    page: page, key: key)
        let started = Date()
        var response = try await analyzeUrl.strResponse()
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)

        let books = try await traced(.search, url: response.url, code: response.code,
                                     body: response.body, started: started,
                                     describe: { $0.isEmpty ? "无结果" : "命中 \($0.count) 本" }) {
            try await BookList.analyzeBookList(
                webBook: self, source: source, ruleData: ruleData, analyzeUrl: analyzeUrl,
                baseUrl: response.url, body: response.body, isSearch: true,
                isRedirect: response.isRedirect, filter: filter, shouldBreak: shouldBreak
            )
        }
        return books
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
        try await exploreBookWithResolvedUrl(source, url: url, page: page).1
    }

    /// 发现页，同时返回重定向后的地址（关联书籍需要展示「打开模块」的最终链接）。
    func exploreBookWithResolvedUrl(_ source: BookSource, url: String,
                                    page: Int = 1) async throws -> (String, [SearchBook]) {
        if source.isJsSource {
            let started = Date()
            let books = try await traced(.search, url: url, code: 0, body: nil,
                                         started: started,
                                         describe: { $0.isEmpty ? "无结果" : "命中 \($0.count) 本" }) {
                try JsSourceEngine(webBook: self, source: source).explore(url: url, page: page)
            }
            return (url, books)
        }
        let ruleData = RuleData()
        let analyzeUrl = analyzeUrl(url, source: source, ruleData: ruleData, page: page)
        var response = try await analyzeUrl.strResponse()
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)

        let books = try await BookList.analyzeBookList(
            webBook: self, source: source, ruleData: ruleData, analyzeUrl: analyzeUrl,
            baseUrl: response.url, body: response.body, isSearch: false,
            isRedirect: response.isRedirect
        )
        return (response.url, books)
    }

    // MARK: - 详情

    func getBookInfo(_ source: BookSource, book: Book, canReName: Bool = true) async throws -> Book {
        if source.isJsSource {
            let started = Date()
            return try await traced(.info, url: book.bookUrl, code: 0, body: nil,
                                    started: started,
                                    describe: { (target: Book) in
                                        target.name.isEmpty ? "书名为空" : "《\(target.name)》"
                                    }) {
                try JsSourceEngine(webBook: self, source: source)
                    .getBookInfo(book: book, canReName: canReName)
            }
        }
        if let html = book.infoHtml, !html.isEmpty {
            // 搜索阶段已经拿到详情页 HTML，直接复用（上游 @Ignore 字段的用途）
            let started = Date()
            let base = book
            return try await traced(.info, url: base.bookUrl, code: 0, body: html, started: started,
                                    describe: { (parsed: Book) in
                                        parsed.name.isEmpty ? "书名为空（复用响应）" : "《\(parsed.name)》（复用响应）"
                                    }) {
                var target = base
                BookInfo.analyze(webBook: self, source: source, book: &target,
                                 baseUrl: base.bookUrl, redirectUrl: base.bookUrl,
                                 body: html, canReName: canReName)
                return target
            }
        }
        let analyzeUrl = analyzeUrl(book.bookUrl, source: source, book: book)
        var response = try await analyzeUrl.strResponse()
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)
        let started = Date()
        let result = try await traced(.info, url: response.url, code: response.code,
                                      body: response.body, started: started,
                                      describe: { (target: Book) in
                                          target.name.isEmpty ? "书名为空" : "《\(target.name)》"
                                      }) {
            var target = book
            BookInfo.analyze(webBook: self, source: source, book: &target,
                             baseUrl: book.bookUrl, redirectUrl: response.url,
                             body: response.body, canReName: canReName)
            return target
        }
        return result
    }

    // MARK: - 目录

    func getChapterList(_ source: BookSource, book: Book, runPreUpdateJs shouldRunPreUpdateJs: Bool = false) async throws -> [BookChapter] {
        if source.isJsSource {
            let started = Date()
            return try await traced(.toc, url: book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl,
                                    code: 0, body: nil, started: started,
                                    describe: { "\($0.count) 章" }) {
                try JsSourceEngine(webBook: self, source: source).getChapters(book: book)
            }
        }
        if shouldRunPreUpdateJs {
            try await runPreUpdateJs(source: source, book: book)
        }
        // 详情页就是目录页时，上游会复用刚才那份响应，不再发请求
        if book.bookUrl == book.tocUrl, let html = book.tocHtml, !html.isEmpty {
            let started = Date()
            let chapters = try await traced(.toc, url: book.tocUrl, code: 0,
                                            body: html, started: started,
                                            describe: { "\($0.count) 章（复用详情页响应）" }) {
                try await BookChapterList.analyze(webBook: self, source: source, book: book,
                                                  baseUrl: book.tocUrl, redirectUrl: book.tocUrl,
                                                  body: html)
            }
            return chapters
        }
        let analyzeUrl = analyzeUrl(book.tocUrl, source: source, book: book)
        let started = Date()
        var response = try await analyzeUrl.strResponse()
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)
        let chapters = try await traced(.toc, url: response.url, code: response.code,
                                        body: response.body, started: started,
                                        describe: { "\($0.count) 章" }) {
            try await BookChapterList.analyze(webBook: self, source: source, book: book,
                                              baseUrl: book.tocUrl, redirectUrl: response.url,
                                              body: response.body)
        }
        return chapters
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
        if source.isJsSource {
            let started = Date()
            let content = try await traced(.content, url: chapter.getAbsoluteURL(), code: 0,
                                           body: nil, started: started,
                                           describe: { "《\(chapter.title)》 \($0.count) 字" }) {
                try JsSourceEngine(webBook: self, source: source)
                    .getContent(book: book, chapter: chapter,
                                nextChapterUrl: nextChapterUrl)
            }
            if needSave {
                saveContent(content, book: book, chapter: chapter)
            }
            return content
        }
        guard let contentRule = source.ruleContent?.content, !contentRule.isEmpty else {
            DebugLog.shared.log(source.bookSourceUrl, "⇒正文规则为空,使用章节链接:\(chapter.url)")
            return chapter.url
        }
        if chapter.isVolume && chapter.url.hasPrefix(chapter.title) {
            return chapter.tag ?? ""
        }

        if chapter.url == book.bookUrl, let html = book.tocHtml, !html.isEmpty {
            let started = Date()
            return try await traced(.content, url: chapter.getAbsoluteURL(), code: 0,
                                    body: html, started: started,
                                    describe: { "《\(chapter.title)》 \($0.count) 字（复用详情页响应）" }) {
                try await BookContent.analyze(webBook: self, source: source, book: book,
                                              chapter: chapter,
                                              baseUrl: chapter.getAbsoluteURL(),
                                              redirectUrl: chapter.getAbsoluteURL(),
                                              body: html, nextChapterUrl: nextChapterUrl,
                                              needSave: needSave)
            }
        }

        let analyzeUrl = analyzeUrl(chapter.getAbsoluteURL(), source: source, book: book,
                                    chapter: chapter)
        var response = try await analyzeUrl.strResponse(
            useWebView: true,
            sourceRegex: source.contentRule.sourceRegex
        )
        response = applyLoginCheck(source, analyzeUrl, response)
        logRedirect(source, response)

        let started = Date()
        let content = try await traced(.content, url: response.url, code: response.code,
                                       body: response.body, started: started,
                                       describe: { "《\(chapter.title)》 \($0.count) 字" }) {
            try await BookContent.analyze(webBook: self, source: source, book: book,
                                          chapter: chapter,
                                          baseUrl: chapter.getAbsoluteURL(),
                                          redirectUrl: response.url,
                                          body: response.body,
                                          nextChapterUrl: nextChapterUrl,
                                          needSave: needSave)
        }
        return content
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

    /// 下载图片并按书源规则二次解密（`coverDecodeJs` / `imageDecode`）。
    /// UI 层拿到的是可直接渲染的字节。
    func fetchImageData(_ url: String, source: BookSource, book: Book? = nil,
                        isCover: Bool = false) async -> Data? {
        let analyzeUrl = analyzeUrl(url, source: source, book: book)
        guard let data = try? await analyzeUrl.byteArray() else { return nil }
        return ImageDecodeService.decodeIfNeeded(src: url, data: data, isCover: isCover,
                                                 source: source, book: book, webBook: self)
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
    private let rootOverride: URL?

    init(root: URL? = nil) {
        self.rootOverride = root
    }

    private var root: URL {
        if let rootOverride { return rootOverride }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func url(book: Book, chapter: BookChapter) -> URL {
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

    /// 同步落盘（下载流程需要确认写入完成）
    func saveSync(_ content: String, book: Book, chapter: BookChapter) {
        let target = url(book: book, chapter: chapter)
        queue.sync {
            try? content.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    /// 等队列里排队的写入全部完成
    func flush() {
        queue.sync {}
    }

    func load(book: Book, chapter: BookChapter) -> String? {
        try? String(contentsOf: url(book: book, chapter: chapter), encoding: .utf8)
    }

    func has(book: Book, chapter: BookChapter) -> Bool {
        let path = url(book: book, chapter: chapter).path
        guard FileManager.default.fileExists(atPath: path),
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        else { return false }
        return size > 0
    }

    func remove(book: Book, chapter: BookChapter) {
        try? FileManager.default.removeItem(at: url(book: book, chapter: chapter))
    }

    func remove(book: Book) {
        let dir = root.appendingPathComponent(CryptoUtils.md5(book.bookUrl), isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}
