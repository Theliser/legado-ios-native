import Foundation

// MARK: - 纯 JS 单文件书源（mainJs）

/// 官方新增的 `mainJs` 书源：一个 JS 文件里以函数形式实现搜索/详情/目录/正文。
/// 约定与上游 `JsSourceBook` 一致：
/// - `search(key, page)` → 书籍数组
/// - `explore(url, page)` → 书籍数组
/// - `getBookInfo(book)` → 书籍字段对象（可选）
/// - `getChapters(book)` → 章节数组
/// - `getContent(chapter, book, nextChapterUrl)` → 正文字符串
///
/// 字段名兼容官方 `SearchBook`/`BookChapter` 的 JSON 字段，同时接受 `url`/`name` 等常见别名。
final class JsSourceEngine: @unchecked Sendable {

    let source: BookSource
    let webBook: WebBook

    init(webBook: WebBook, source: BookSource) {
        self.webBook = webBook
        self.source = source
    }

    // MARK: 调用

    func call(_ function: String, positional: [Any] = [], bindings: [String: Any] = [:]) -> Any? {
        guard let mainJs = source.mainJs, !mainJs.isBlank else { return nil }
        var env = JSEnvironment()
        env.source = source
        env.baseUrl = source.bookSourceUrl
        env.settings = webBook.settings
        let rule = webBook.makeRule(source: source)
        env.analyzer = rule
        let sourceKey = source.bookSourceUrl
        env.toast = { message in
            DebugLog.shared.log(sourceKey, "⇒\(message)")
        }
        // mainJs 里同样可以调用 java.ajax / java.get / java.post
        env.ajax = { [webBook = webBook, source = source] url, timeout in
            let request = JSHttpRequest(url: url, timeout: timeout)
            return JSRequestExecutor.perform(request, source: source, book: nil, chapter: nil,
                                             ruleData: nil, httpClient: webBook.httpClient,
                                             cookieStore: webBook.cookieStore,
                                             settings: webBook.settings)?.body ?? ""
        }
        env.request = { [webBook = webBook, source = source] request in
            JSRequestExecutor.perform(request, source: source, book: nil, chapter: nil,
                                      ruleData: nil, httpClient: webBook.httpClient,
                                      cookieStore: webBook.cookieStore,
                                      settings: webBook.settings)
        }
        env.requestAll = { [webBook = webBook, source = source] requests in
            JSRequestExecutor.performAll(requests, source: source, book: nil, chapter: nil,
                                         ruleData: nil, httpClient: webBook.httpClient,
                                         cookieStore: webBook.cookieStore,
                                         settings: webBook.settings)
        }
        env.dataRequest = { [webBook = webBook, source = source] request in
            JSRequestExecutor.performData(request, source: source, book: nil, chapter: nil,
                                          ruleData: nil, httpClient: webBook.httpClient,
                                          cookieStore: webBook.cookieStore,
                                          settings: webBook.settings)
        }
        return JSRuntime.shared.callFunction(mainJs, function: function,
                                            arguments: positional,
                                            env: env, bindings: bindings)
    }

    func callJSON(_ function: String, positional: [Any] = [],
                  bindings: [String: Any] = [:]) -> String? {
        let value = call(function, positional: positional, bindings: bindings)
        return Self.stringify(value)
    }

    // MARK: 搜索 / 发现

    func search(key: String, page: Int) throws -> [SearchBook] {
        guard let json = callJSON("search", positional: [key, page],
                                  bindings: ["key": key, "page": page]) else {
            throw WebBookError.message("JS源 search 无返回")
        }
        DebugLog.shared.log(source.bookSourceUrl, json, state: DebugLogState.searchResult.rawValue)
        let books = JsSourceMarshaller.parseBooks(json, source: source)
        DebugLog.shared.log(source.bookSourceUrl, "◇JS源搜索完成,共\(books.count)条")
        return books
    }

    func explore(url: String, page: Int) throws -> [SearchBook] {
        guard let json = callJSON("explore", positional: [url, page],
                                  bindings: ["url": url, "page": page]) else {
            throw WebBookError.message("JS源 explore 无返回")
        }
        DebugLog.shared.log(source.bookSourceUrl, json, state: DebugLogState.searchResult.rawValue)
        let books = JsSourceMarshaller.parseBooks(json, source: source)
        DebugLog.shared.log(source.bookSourceUrl, "◇JS源发现完成,共\(books.count)条")
        return books
    }

    // MARK: 详情

    func getBookInfo(book: Book, canReName: Bool) throws -> Book {
        var book = book
        let bridge = JSBookBridge(book)
        let json = callJSON("getBookInfo", positional: [bridge],
                            bindings: ["book": bridge])
        book = bridge.book
        if let json, !json.isBlank {
            DebugLog.shared.log(source.bookSourceUrl, json, state: DebugLogState.bookInfo.rawValue)
            JsSourceMarshaller.mergeBookInfo(&book, json: json, source: source,
                                             canReName: canReName)
        } else {
            DebugLog.shared.log(source.bookSourceUrl, "≡getBookInfo 未定义或无返回,沿用搜索阶段字段")
        }
        if book.tocUrl.isBlank && !BookType.has(book.type, BookType.webFile) {
            book.tocUrl = book.bookUrl
        }
        if BookType.has(source.bookType, BookType.webFile),
           (book.downloadUrls ?? []).isEmpty {
            throw WebBookError.message("下载链接为空")
        }
        return book
    }

    // MARK: 目录

    func getChapters(book: Book) throws -> [BookChapter] {
        let bridge = JSBookBridge(book)
        guard let json = callJSON("getChapters", positional: [bridge],
                                  bindings: ["book": bridge]) else {
            throw WebBookError.message("JS源 getChapters 无返回")
        }
        DebugLog.shared.log(source.bookSourceUrl, json, state: DebugLogState.toc.rawValue)
        let chapters = JsSourceMarshaller.parseChapters(json, book: book, source: source)
        guard !chapters.isEmpty else { throw WebBookError.emptyToc }
        DebugLog.shared.log(source.bookSourceUrl, "◇JS源目录完成,共\(chapters.count)章")
        return chapters
    }

    // MARK: 正文

    func getContent(book: Book, chapter: BookChapter, nextChapterUrl: String?) throws -> String {
        if chapter.isVolume && chapter.url.hasPrefix(chapter.title) {
            DebugLog.shared.log(source.bookSourceUrl, "⇒一级目录正文不解析")
            return ""
        }
        let bookBridge = JSBookBridge(book)
        let chapterBridge = JSChapterBridge(chapter)
        let json = callJSON("getContent",
                            positional: [chapterBridge, bookBridge, nextChapterUrl ?? ""],
                            bindings: ["chapter": chapterBridge, "book": bookBridge,
                                       "nextChapterUrl": nextChapterUrl ?? ""])
        let content = json ?? ""
        DebugLog.shared.log(source.bookSourceUrl, content, state: DebugLogState.content.rawValue)
        if !chapter.isVolume && content.isBlank {
            throw WebBookError.emptyContent
        }
        return content
    }

    // MARK: 返回值序列化

    static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if JSONSerialization.isValidJSONObject(value) {
            return JSONTool.stringify(value)
        }
        return "\(value)"
    }
}

// MARK: - 字段映射

enum JsSourceMarshaller {

    static func parseBooks(_ json: String, source: BookSource) -> [SearchBook] {
        guard let array = JSONTool.parseArray(json) else {
            DebugLog.shared.log(source.bookSourceUrl, "⇒search/explore 返回值不是数组")
            return []
        }
        var result: [SearchBook] = []
        for item in array {
            guard let dict = item as? [String: Any] else { continue }
            let name = str(dict, "name", "bookName")
            let bookUrl = str(dict, "bookUrl", "url")
            guard !name.isEmpty, !bookUrl.isEmpty else {
                DebugLog.shared.log(source.bookSourceUrl, "⇒丢弃缺少 name/bookUrl 的搜索条目")
                continue
            }
            var book = SearchBook()
            book.name = name
            book.author = str(dict, "author")
            book.bookUrl = NetworkUtils.getAbsoluteURL(source.bookSourceUrl, bookUrl)
            book.origin = source.bookSourceUrl
            book.originName = source.bookSourceName
            book.originOrder = source.customOrder
            book.type = type(dict, default: source.bookType)
            book.tocUrl = str(dict, "tocUrl")
            book.coverUrl = nilIfEmpty(str(dict, "coverUrl", "cover"))
            book.intro = nilIfEmpty(str(dict, "intro", "description"))
            book.kind = nilIfEmpty(str(dict, "kind", "category"))
            book.wordCount = nilIfEmpty(str(dict, "wordCount"))
            book.latestChapterTitle = nilIfEmpty(str(dict, "latestChapterTitle", "lastChapter"))
            book.variable = variable(dict)
            result.append(book)
        }
        return result
    }

    static func mergeBookInfo(_ book: inout Book, json: String, source: BookSource,
                              canReName: Bool) {
        guard let dict = JSONTool.parseObject(json) else {
            DebugLog.shared.log(source.bookSourceUrl, "⇒getBookInfo 返回值不是对象")
            return
        }
        for (key, value) in dict {
            if value is NSNull { continue }
            switch key {
            case "name":
                let text = AnalyzeRule.stringValue(value)
                if !text.isEmpty && (canReName || book.name.isEmpty) { book.name = text }
            case "author":
                let text = AnalyzeRule.stringValue(value)
                if !text.isEmpty && (canReName || book.author.isEmpty) { book.author = text }
            case "intro", "description":
                book.intro = AnalyzeRule.stringValue(value)
            case "coverUrl", "cover":
                book.coverUrl = NetworkUtils.getAbsoluteURL(book.bookUrl,
                                                            AnalyzeRule.stringValue(value))
            case "kind", "category":
                book.kind = AnalyzeRule.stringValue(value)
            case "wordCount":
                book.wordCount = AnalyzeRule.stringValue(value)
            case "latestChapterTitle", "lastChapter":
                book.latestChapterTitle = AnalyzeRule.stringValue(value)
            case "tocUrl":
                book.tocUrl = NetworkUtils.getAbsoluteURL(book.bookUrl,
                                                          AnalyzeRule.stringValue(value))
            case "downloadUrls":
                if let list = value as? [Any] {
                    book.downloadUrls = list.map { AnalyzeRule.stringValue($0) }
                        .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("javascript") }
                        .map { NetworkUtils.getAbsoluteURL(book.bookUrl, $0) }
                }
            case "variable", "variables":
                book.variable = variable(["variable": value])
            case "type":
                if let number = value as? NSNumber { book.type = number.intValue }
            default:
                break
            }
        }
    }

    static func parseChapters(_ json: String, book: Book, source: BookSource) -> [BookChapter] {
        guard let array = JSONTool.parseArray(json) else {
            DebugLog.shared.log(source.bookSourceUrl, "⇒getChapters 返回值不是数组")
            return []
        }
        var chapters: [BookChapter] = []
        for item in array {
            guard let dict = item as? [String: Any] else { continue }
            let title = str(dict, "title", "name")
            var url = str(dict, "url")
            let volume = bool(dict, "isVolume") || bool(dict, "voltype")
            if volume && url.isEmpty { url = title }
            guard !title.isEmpty, !url.isEmpty else {
                DebugLog.shared.log(source.bookSourceUrl, "⇒丢弃缺少 title/url 的章节")
                continue
            }
            var chapter = BookChapter(bookUrl: book.bookUrl, baseUrl: book.tocUrl)
            chapter.title = title
            chapter.url = (volume && url == title)
                ? url
                : NetworkUtils.getAbsoluteURL(book.tocUrl, url)
            chapter.isVolume = volume
            chapter.isVip = bool(dict, "isVip")
            chapter.isPay = bool(dict, "isPay")
            chapter.tag = nilIfEmpty(str(dict, "tag", "info"))
            chapter.variable = variable(dict)
            chapter.index = chapters.count
            chapters.append(chapter)
        }
        return chapters
    }

    // MARK: 值读取

    private static func str(_ dict: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = dict[key], !(value is NSNull) {
                let text = AnalyzeRule.stringValue(value)
                if !text.isEmpty { return text }
            }
        }
        return ""
    }

    private static func bool(_ dict: [String: Any], _ key: String) -> Bool {
        guard let value = dict[key] else { return false }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return BookFormatter.isTrue(AnalyzeRule.stringValue(value))
    }

    private static func type(_ dict: [String: Any], default fallback: Int) -> Int {
        guard let value = dict["type"] else { return fallback }
        let raw = (value as? NSNumber)?.intValue ?? Int(AnalyzeRule.stringValue(value)) ?? fallback
        // 上游会校验位掩码：0 或含未知位时回退书源类型
        if raw == 0 || (raw & ~BookType.allBookType) != 0 { return fallback }
        return raw
    }

    private static func variable(_ dict: [String: Any]) -> String? {
        guard let value = dict["variable"] ?? dict["variables"] else { return nil }
        if let text = value as? String { return text }
        if JSONSerialization.isValidJSONObject(value) {
            return JSONTool.stringify(value)
        }
        return nil
    }

    private static func nilIfEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }
}
