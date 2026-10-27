import Foundation

// MARK: - 书籍列表

enum BookList {

    static func analyzeBookList(webBook: WebBook,
                                source: BookSource,
                                ruleData: RuleData,
                                analyzeUrl: AnalyzeUrl,
                                baseUrl: String,
                                body: String?,
                                isSearch: Bool,
                                isRedirect: Bool = false,
                                filter: ((String, String, String?) -> Bool)? = nil,
                                shouldBreak: ((Int) -> Bool)? = nil) async throws -> [SearchBook] {
        guard let body else {
            throw WebBookError.message("获取网页内容失败:\(analyzeUrl.ruleUrl)")
        }
        var bookList: [SearchBook] = []
        DebugLog.shared.log(source.bookSourceUrl, "≡获取成功:\(analyzeUrl.ruleUrl)")
        DebugLog.shared.log(source.bookSourceUrl, body, state: DebugLogState.searchResult.rawValue)

        let analyzeRule = webBook.makeRule(source: source)
        analyzeRule.setRuleData(ruleData)
        analyzeRule.setContent(body)
        analyzeRule.setBaseUrl(baseUrl)
        analyzeRule.setRedirectUrl(baseUrl)

        // 搜索链接本身就是详情页
        if isSearch, let pattern = source.bookUrlPattern, !pattern.isEmpty, baseUrl.matchesFully(pattern) {
            DebugLog.shared.log(source.bookSourceUrl, "≡链接为详情页")
            if var item = try await getInfoItem(webBook: webBook, source: source, analyzeRule: analyzeRule,
                                                analyzeUrl: analyzeUrl, body: body, baseUrl: baseUrl,
                                                variable: ruleData.variableMap, isRedirect: isRedirect,
                                                filter: filter) {
                item.infoHtml = body
                bookList.append(item)
            }
            return bookList
        }

        let bookListRule: (bookList: String?, name: String?, author: String?, intro: String?,
                           kind: String?, lastChapter: String?, updateTime: String?, bookUrl: String?,
                           coverUrl: String?, wordCount: String?)
        if isSearch {
            let rule = source.searchRule
            bookListRule = (rule.bookList, rule.name, rule.author, rule.intro, rule.kind,
                            rule.lastChapter, rule.updateTime, rule.bookUrl, rule.coverUrl, rule.wordCount)
        } else if (source.exploreRuleObj.bookList ?? "").isEmpty {
            let rule = source.searchRule
            bookListRule = (rule.bookList, rule.name, rule.author, rule.intro, rule.kind,
                            rule.lastChapter, rule.updateTime, rule.bookUrl, rule.coverUrl, rule.wordCount)
        } else {
            let rule = source.exploreRuleObj
            bookListRule = (rule.bookList, rule.name, rule.author, rule.intro, rule.kind,
                            rule.lastChapter, rule.updateTime, rule.bookUrl, rule.coverUrl, rule.wordCount)
        }

        var ruleList = bookListRule.bookList ?? ""
        var reverse = false
        if ruleList.hasPrefix("-") { reverse = true; ruleList = String(ruleList.dropFirst()) }
        if ruleList.hasPrefix("+") { ruleList = String(ruleList.dropFirst()) }

        DebugLog.shared.log(source.bookSourceUrl, "┌获取书籍列表")
        let collections = analyzeRule.getElements(ruleList)

        if collections.isEmpty && (source.bookUrlPattern ?? "").isEmpty {
            DebugLog.shared.log(source.bookSourceUrl, "└列表为空,按详情页解析")
            if var item = try await getInfoItem(webBook: webBook, source: source, analyzeRule: analyzeRule,
                                                analyzeUrl: analyzeUrl, body: body, baseUrl: baseUrl,
                                                variable: ruleData.variableMap, isRedirect: isRedirect,
                                                filter: filter) {
                item.infoHtml = body
                bookList.append(item)
            }
        } else {
            DebugLog.shared.log(source.bookSourceUrl, "└列表大小:\(collections.count)")
            for (index, item) in collections.enumerated() {
                if let book = getSearchItem(webBook: webBook, source: source, analyzeRule: analyzeRule,
                                            item: item, baseUrl: baseUrl,
                                            variable: ruleData.variableMap, log: index == 0,
                                            filter: filter, rule: bookListRule) {
                    if baseUrl == book.bookUrl { book_list_setInfoHtml(book, body) }
                    bookList.append(book)
                }
                if shouldBreak?(bookList.count) == true { break }
            }

            // 去重（顺序保留）
            var seen = Set<String>()
            bookList = bookList.filter { seen.insert($0.bookUrl).inserted }
            if reverse { bookList.reverse() }
        }

        DebugLog.shared.log(source.bookSourceUrl, "◇书籍总数:\(bookList.count)")
        return bookList
    }

    private static func book_list_setInfoHtml(_ book: SearchBook, _ body: String) {
        // 列表项链接等于当前页时，当前页就是详情页，内容已在列表里取过，无需再存
        _ = book
        _ = body
    }

    private static func getInfoItem(webBook: WebBook, source: BookSource, analyzeRule: AnalyzeRule,
                                    analyzeUrl: AnalyzeUrl, body: String, baseUrl: String,
                                    variable: [String: String], isRedirect: Bool,
                                    filter: ((String, String, String?) -> Bool)?) async throws -> SearchBook? {
        var book = Book()
        book.variableMap = variable
        book.bookUrl = isRedirect
            ? baseUrl
            : NetworkUtils.getAbsoluteURL(analyzeUrl.url, analyzeUrl.ruleUrl)
        book.origin = source.bookSourceUrl
        book.originName = source.bookSourceName
        book.originOrder = source.customOrder
        book.type = source.bookSourceType
        analyzeRule.setRuleData(RuleData())
        BookInfo.analyze(webBook: webBook, source: source, book: &book,
                         baseUrl: baseUrl, redirectUrl: baseUrl, body: body, canReName: false)
        if filter?(book.name, book.author, book.kind) == false { return nil }
        guard !book.name.isBlank else { return nil }
        return bookToSearchBook(book)
    }

    private static func bookToSearchBook(_ book: Book) -> SearchBook {
        var item = SearchBook()
        item.bookUrl = book.bookUrl
        item.origin = book.origin
        item.originName = book.originName
        item.type = book.type
        item.name = book.name
        item.author = book.author
        item.kind = book.kind
        item.coverUrl = book.coverUrl
        item.intro = book.intro
        item.wordCount = book.wordCount
        item.latestChapterTitle = book.latestChapterTitle
        item.tocUrl = book.tocUrl
        item.variable = book.variable
        item.originOrder = book.originOrder
        return item
    }

    private static func getSearchItem(webBook: WebBook, source: BookSource, analyzeRule: AnalyzeRule,
                                      item: Any, baseUrl: String, variable: [String: String],
                                      log: Bool, filter: ((String, String, String?) -> Bool)?,
                                      rule: (bookList: String?, name: String?, author: String?,
                                             intro: String?, kind: String?, lastChapter: String?,
                                             updateTime: String?, bookUrl: String?, coverUrl: String?,
                                             wordCount: String?)) -> SearchBook? {
        var searchBook = SearchBook()
        searchBook.type = source.bookSourceType
        searchBook.origin = source.bookSourceUrl
        searchBook.originName = source.bookSourceName
        searchBook.originOrder = source.customOrder
        searchBook.variableMap = variable
        analyzeRule.setRuleData(RuleData())
        analyzeRule.setContent(item)

        let name = BookFormatter.formatName(analyzeRule.getString(rule.name))
        DebugLog.shared.log(source.bookSourceUrl, "┌获取书名\n└\(name)", state: log ? 0 : -1)
        guard !name.isEmpty else { return nil }
        searchBook.name = name
        searchBook.author = BookFormatter.formatAuthor(analyzeRule.getString(rule.author))

        if let kinds = analyzeRule.getStringList(rule.kind) {
            searchBook.kind = String(kinds.joined(separator: ",").prefix(1000))
        }
        if filter?(searchBook.name, searchBook.author, searchBook.kind) == false { return nil }

        searchBook.wordCount = BookFormatter.wordCount(analyzeRule.getString(rule.wordCount))
        searchBook.latestChapterTitle = analyzeRule.getString(rule.lastChapter)
        searchBook.intro = String(HtmlFormatter.format(analyzeRule.getString(rule.intro)).prefix(5000))

        let cover = analyzeRule.getString(rule.coverUrl)
        if !cover.isEmpty {
            searchBook.coverUrl = NetworkUtils.getAbsoluteURL(baseUrl, cover)
        }
        searchBook.bookUrl = analyzeRule.getString(rule.bookUrl, isUrl: true)
        if searchBook.bookUrl.isEmpty { searchBook.bookUrl = baseUrl }
        return searchBook
    }
}

// MARK: - 书籍详情

enum BookInfo {

    static func analyze(webBook: WebBook, source: BookSource, book: inout Book,
                        baseUrl: String, redirectUrl: String, body: String?,
                        canReName: Bool) {
        guard let body else {
            DebugLog.shared.log(source.bookSourceUrl, "获取网页内容失败:\(baseUrl)")
            return
        }
        DebugLog.shared.log(source.bookSourceUrl, "≡获取成功:\(baseUrl)")
        DebugLog.shared.log(source.bookSourceUrl, body, state: DebugLogState.bookInfo.rawValue)

        let analyzeRule = webBook.makeRule(book: book, source: source)
        analyzeRule.setContent(body)
        analyzeRule.setBaseUrl(baseUrl)
        analyzeRule.setRedirectUrl(redirectUrl)

        let infoRule = source.bookInfoRule
        if let initRule = infoRule.initRule, !initRule.isBlank {
            analyzeRule.setContent(analyzeRule.getElement(initRule))
        }
        let canReNameReal = canReName && !(infoRule.canReName ?? "").isBlank

        let name = BookFormatter.formatName(analyzeRule.getString(infoRule.name))
        if !name.isEmpty && (canReNameReal || book.name.isEmpty) { book.name = name }

        let author = BookFormatter.formatAuthor(analyzeRule.getString(infoRule.author))
        if !author.isEmpty && (canReNameReal || book.author.isEmpty) { book.author = author }

        if let kinds = analyzeRule.getStringList(infoRule.kind) {
            let kind = String(kinds.joined(separator: ",").prefix(1000))
            if !kind.isEmpty { book.kind = kind }
        }

        let wordCount = BookFormatter.wordCount(analyzeRule.getString(infoRule.wordCount))
        if !wordCount.isEmpty { book.wordCount = wordCount }

        let latest = analyzeRule.getString(infoRule.lastChapter)
        if !latest.isEmpty { book.latestChapterTitle = String(latest.prefix(200)) }

        let intro = analyzeRule.getString(infoRule.intro).trimmingCharacters(in: .whitespacesAndNewlines)
        if intro.hasPrefix("<usehtml>") || intro.hasPrefix("<md>") || intro.hasPrefix("<useweb>") {
            book.intro = intro
        } else {
            let formatted = String(HtmlFormatter.format(intro).prefix(5000))
            if !formatted.isEmpty { book.intro = formatted }
        }

        let cover = analyzeRule.getString(infoRule.coverUrl)
        if !cover.isEmpty {
            book.coverUrl = NetworkUtils.getAbsoluteURL(redirectUrl, cover)
        }

        if !BookType.has(book.type, BookType.webFile) {
            book.tocUrl = analyzeRule.getString(infoRule.tocUrl, isUrl: true)
            if book.tocUrl.isEmpty { book.tocUrl = baseUrl }
            if book.tocUrl == baseUrl { book.tocHtml = body }
            DebugLog.shared.log(source.bookSourceUrl, "└\(book.tocUrl)")
        } else {
            book.downloadUrls = analyzeRule.getStringList(infoRule.downloadUrls, isUrl: true)
        }
    }
}

// MARK: - 目录

enum BookChapterList {

    static func analyze(webBook: WebBook, source: BookSource, book: Book,
                        baseUrl: String, redirectUrl: String, body: String?) async throws -> [BookChapter] {
        guard let body else {
            throw WebBookError.message("获取网页内容失败:\(baseUrl)")
        }
        DebugLog.shared.log(source.bookSourceUrl, "≡获取成功:\(baseUrl)")
        DebugLog.shared.log(source.bookSourceUrl, body, state: DebugLogState.toc.rawValue)

        let tocRule = source.tocRule
        var visited: [String] = [redirectUrl]
        var reverse = false
        var listRule = tocRule.chapterList ?? ""
        if listRule.hasPrefix("-") { reverse = true; listRule = String(listRule.dropFirst()) }
        if listRule.hasPrefix("+") { listRule = String(listRule.dropFirst()) }

        var chapters: [BookChapter] = []
        var page = analyzeChapters(webBook: webBook, source: source, book: book,
                                   baseUrl: baseUrl, redirectUrl: redirectUrl, body: body,
                                   tocRule: tocRule, listRule: listRule, getNextUrl: true, log: true)
        chapters.append(contentsOf: page.chapters)

        if page.nextUrls.count == 1 {
            var nextUrl = page.nextUrls[0]
            while !nextUrl.isEmpty && !visited.contains(nextUrl) {
                visited.append(nextUrl)
                let analyzeUrl = AnalyzeUrl(url: nextUrl, baseUrl: book.bookUrl, source: source,
                                            book: book, httpClient: webBook.httpClient,
                                            cookieStore: webBook.cookieStore, settings: webBook.settings)
                let response = try await analyzeUrl.strResponse()
                guard let nextBody = response.body else { break }
                page = analyzeChapters(webBook: webBook, source: source, book: book,
                                       baseUrl: nextUrl, redirectUrl: nextUrl, body: nextBody,
                                       tocRule: tocRule, listRule: listRule, getNextUrl: false)
                nextUrl = page.nextUrls.first ?? ""
                chapters.append(contentsOf: page.chapters)
            }
            DebugLog.shared.log(source.bookSourceUrl, "◇目录总页数:\(visited.count)")
        } else if page.nextUrls.count > 1 {
            DebugLog.shared.log(source.bookSourceUrl, "◇并发解析目录,总页数:\(page.nextUrls.count)")
            let urls = page.nextUrls
            let limit = max(1, min(4, webBook.settings.threadCount))
            var collected: [[BookChapter]] = Array(repeating: [], count: urls.count)
            try await withThrowingTaskGroup(of: (Int, [BookChapter]).self) { group in
                var index = 0
                var running = 0
                while index < urls.count {
                    if running >= limit {
                        if let (i, list) = try await group.next() {
                            collected[i] = list
                            running -= 1
                        }
                    }
                    let current = index
                    let url = urls[current]
                    group.addTask {
                        let analyzeUrl = AnalyzeUrl(url: url, baseUrl: book.bookUrl, source: source,
                                                    book: book, httpClient: webBook.httpClient,
                                                    cookieStore: webBook.cookieStore,
                                                    settings: webBook.settings)
                        let response = try await analyzeUrl.strResponse()
                        let result = analyzeChapters(webBook: webBook, source: source, book: book,
                                                     baseUrl: url, redirectUrl: response.url,
                                                     body: response.body ?? "", tocRule: tocRule,
                                                     listRule: listRule, getNextUrl: false)
                        return (current, result.chapters)
                    }
                    index += 1
                    running += 1
                }
                while running > 0 {
                    if let (i, list) = try await group.next() {
                        collected[i] = list
                        running -= 1
                    }
                }
            }
            for list in collected { chapters.append(contentsOf: list) }
        }

        guard !chapters.isEmpty else { throw WebBookError.emptyToc }

        // 与上游一致：目录默认逆序（站点多为最新章节在前），再按书籍设置反转一次
        if !reverse { chapters.reverse() }
        var seen = Set<String>()
        chapters = chapters.filter { seen.insert($0.url + "|" + $0.title).inserted }
        if !(book.readConfigObject["reverseToc"] as? Bool ?? false) {
            chapters.reverse()
        }
        DebugLog.shared.log(book.origin, "◇目录总数:\(chapters.count)")

        for (index, chapter) in chapters.enumerated() {
            chapters[index].index = index
        }

        // formatJs：逐章重命名
        if let formatJs = tocRule.formatJs, !formatJs.isBlank {
            // 上游绑定的是 index(1 基) / chapter / title，返回值直接覆盖标题
            for index in chapters.indices {
                var env = JSEnvironment()
                env.source = source
                env.book = book
                env.chapter = chapters[index]
                env.title = chapters[index].title
                env.index = index + 1
                let value = JSRuntime.shared.evaluate(formatJs, key: source.bookSourceUrl, env: env)
                if let text = value as? String {
                    chapters[index].title = text
                }
            }
        }

        // 更新书籍统计（由调用方保存）
        var updated = book
        updated.totalChapterNum = chapters.count
        updated.lastCheckTime = Int64(Date().timeIntervalSince1970 * 1000)
        updated.latestChapterTitle = String(chapters.last?.title.prefix(200) ?? "")
        updated.durChapterTitle = chapters.indices.contains(updated.durChapterIndex)
            ? chapters[updated.durChapterIndex].title : chapters.last?.title
        return chapters
    }

    private static func analyzeChapters(webBook: WebBook, source: BookSource, book: Book,
                                        baseUrl: String, redirectUrl: String, body: String,
                                        tocRule: TocRule, listRule: String,
                                        getNextUrl: Bool = true, log: Bool = false) -> (chapters: [BookChapter], nextUrls: [String]) {
        let analyzeRule = webBook.makeRule(book: book, source: source)
        analyzeRule.setContent(body)
        analyzeRule.setBaseUrl(baseUrl)
        analyzeRule.setRedirectUrl(redirectUrl)

        let elements = analyzeRule.getElements(listRule)
        DebugLog.shared.log(source.bookSourceUrl, "└列表大小:\(elements.count)", state: log ? 0 : -1)

        var nextUrls: [String] = []
        if getNextUrl, let nextRule = tocRule.nextTocUrl, !nextRule.isEmpty {
            if let urls = analyzeRule.getStringList(nextRule, isUrl: true) {
                for item in urls where item != redirectUrl {
                    nextUrls.append(item)
                }
            }
        }

        var chapters: [BookChapter] = []
        guard !elements.isEmpty else { return (chapters, nextUrls) }

        let nameRules = analyzeRule.splitSourceRule(tocRule.chapterName)
        let urlRules = analyzeRule.splitSourceRule(tocRule.chapterUrl)
        let vipRules = analyzeRule.splitSourceRule(tocRule.isVip)
        let payRules = analyzeRule.splitSourceRule(tocRule.isPay)
        let timeRules = analyzeRule.splitSourceRule(tocRule.updateTime)
        let volumeRules = analyzeRule.splitSourceRule(tocRule.isVolume)

        for (index, item) in elements.enumerated() {
            analyzeRule.setContent(item)
            var chapter = BookChapter(bookUrl: book.bookUrl, baseUrl: redirectUrl)
            analyzeRule.setChapter(chapter)
            chapter.title = analyzeRule.getString(nameRules)
            chapter.url = analyzeRule.getString(urlRules)
            chapter.tag = analyzeRule.getString(timeRules)

            let isVolume = analyzeRule.getString(volumeRules)
            chapter.isVolume = false
            if BookFormatter.isTrue(isVolume) { chapter.isVolume = true }

            if chapter.url.isEmpty {
                if chapter.isVolume {
                    chapter.url = chapter.title + "\(index)"
                    DebugLog.shared.log(source.bookSourceUrl, "⇒一级目录\(index)未获取到url,使用标题替代")
                } else {
                    chapter.url = baseUrl
                }
            }

            if !chapter.title.isEmpty {
                if BookFormatter.isTrue(analyzeRule.getString(vipRules)) { chapter.isVip = true }
                if BookFormatter.isTrue(analyzeRule.getString(payRules)) { chapter.isPay = true }
                chapters.append(chapter)
            }
        }
        return (chapters, nextUrls)
    }
}

// MARK: - 正文

enum BookContent {

    static func analyze(webBook: WebBook, source: BookSource, book: Book, chapter: BookChapter,
                        baseUrl: String, redirectUrl: String, body: String?,
                        nextChapterUrl: String?, needSave: Bool = true) async throws -> String {
        guard let body else {
            throw WebBookError.message("获取网页内容失败:\(baseUrl)")
        }
        DebugLog.shared.log(source.bookSourceUrl, "≡获取成功:\(baseUrl)")
        if !needSave {
            DebugLog.shared.log(source.bookSourceUrl, body, state: DebugLogState.content.rawValue)
        }

        let contentRule = source.contentRule
        let nextChapter = nextChapterUrl ?? webBook.nextChapterUrl(book: book, chapter: chapter)

        var pageCount = 0
        var contentBuilder = ""
        func append(_ text: String) {
            if pageCount > 0 { contentBuilder += "\n" }
            contentBuilder += text
            pageCount += 1
        }

        var visited = [redirectUrl]
        var page = analyzePage(webBook: webBook, source: source, book: book, chapter: chapter,
                               baseUrl: baseUrl, redirectUrl: redirectUrl, body: body,
                               contentRule: contentRule, nextChapterUrl: nextChapter)
        append(page.content)

        if page.nextUrls.count == 1 {
            var nextUrl = page.nextUrls[0]
            while !nextUrl.isEmpty && !visited.contains(nextUrl) {
                if let nextChapter, !nextChapter.isEmpty,
                   NetworkUtils.getAbsoluteURL(redirectUrl, nextUrl)
                    == NetworkUtils.getAbsoluteURL(redirectUrl, nextChapter) { break }
                visited.append(nextUrl)
                let analyzeUrl = AnalyzeUrl(url: nextUrl, baseUrl: book.tocUrl, source: source,
                                            book: book, chapter: chapter,
                                            httpClient: webBook.httpClient,
                                            cookieStore: webBook.cookieStore, settings: webBook.settings)
                let response = try await analyzeUrl.strResponse()
                guard let nextBody = response.body else { break }
                page = analyzePage(webBook: webBook, source: source, book: book, chapter: chapter,
                                   baseUrl: nextUrl, redirectUrl: response.url, body: nextBody,
                                   contentRule: contentRule, nextChapterUrl: nextChapter,
                                   getNextPageUrl: false)
                nextUrl = page.nextUrls.first ?? ""
                append(page.content)
            }
            DebugLog.shared.log(source.bookSourceUrl, "◇本章总页数:\(visited.count)")
        } else if page.nextUrls.count > 1 {
            let urls = page.nextUrls
            let limit = max(1, min(4, webBook.settings.threadCount))
            var collected: [String] = Array(repeating: "", count: urls.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var index = 0
                var running = 0
                while index < urls.count {
                    if running >= limit {
                        if let (i, text) = try await group.next() {
                            collected[i] = text
                            running -= 1
                        }
                    }
                    let current = index
                    let url = urls[current]
                    group.addTask {
                        let analyzeUrl = AnalyzeUrl(url: url, baseUrl: book.tocUrl, source: source,
                                                    book: book, chapter: chapter,
                                                    httpClient: webBook.httpClient,
                                                    cookieStore: webBook.cookieStore,
                                                    settings: webBook.settings)
                        let response = try await analyzeUrl.strResponse()
                        let result = analyzePage(webBook: webBook, source: source, book: book,
                                                 chapter: chapter, baseUrl: url,
                                                 redirectUrl: response.url,
                                                 body: response.body ?? "", contentRule: contentRule,
                                                 nextChapterUrl: nextChapter, getNextPageUrl: false)
                        return (current, result.content)
                    }
                    index += 1
                    running += 1
                }
                while running > 0 {
                    if let (i, text) = try await group.next() {
                        collected[i] = text
                        running -= 1
                    }
                }
            }
            for text in collected where !text.isEmpty { append(text) }
        }

        // 副文（歌词 / 作者的话）
        if let subRule = contentRule.subContent, !subRule.isBlank {
            let analyzeRule = webBook.makeRule(book: book, source: source)
            analyzeRule.setChapter(chapter)
            analyzeRule.setContent(body)
            analyzeRule.setBaseUrl(baseUrl)
            let raw = analyzeRule.getString(subRule, unescape: false).trimmed
            var sub = raw
            if raw.lowercased().hasPrefix("http") {
                let analyzeUrl = AnalyzeUrl(url: raw, source: source, book: book,
                                            httpClient: webBook.httpClient,
                                            cookieStore: webBook.cookieStore,
                                            settings: webBook.settings)
                sub = (try? await analyzeUrl.strResponse().body) ?? ""
            }
            if !sub.isBlank {
                if book.isOnLineTxt {
                    append(sub)
                } else if book.isAudio {
                    // 音频书的 subContent 是歌词
                    var updated = chapter
                    var map = updated.variableMap
                    map["lyric"] = sub
                    updated.variableMap = map
                    webBook.bookRepository?.save(chapter: updated)
                }
            }
        }

        var contentStr = contentBuilder

        // 标题规则
        if let titleRule = contentRule.title, !titleRule.isBlank {
            let analyzeRule = webBook.makeRule(book: book, source: source)
            analyzeRule.setChapter(chapter)
            analyzeRule.setContent(body)
            analyzeRule.setBaseUrl(baseUrl)
            var chapter = chapter
            if var title = try? analyzeRule.getString(titleRule), !title.isBlank {
                if let groups = title.firstMatchGroups("(.*)((?:data|https?):[\\s\\S]+)$"), groups.count > 2 {
                    let g1 = groups[1]
                    title = g1.isEmpty ? chapter.title : g1
                    chapter.reviewImg = groups[2]
                }
                chapter.title = title
                if let repository = webBook.bookRepository {
                    repository.save(chapter: chapter)
                }
            }
        }

        contentStr = applyReplaceRule(contentStr, rule: contentRule.replaceRegex,
                                      webBook: webBook, source: source, book: book, baseUrl: baseUrl)

        DebugLog.shared.log(source.bookSourceUrl, "┌获取章节名称\n└\(chapter.title)")
        DebugLog.shared.log(source.bookSourceUrl,
                            needSave ? "└正文长度:\(contentStr.count)" : "└\n\(contentStr)")

        if !chapter.isVolume && contentStr.isBlank {
            throw WebBookError.emptyContent
        }
        if needSave {
            webBook.saveContent(contentStr, book: book, chapter: chapter)
        }
        return contentStr
    }

    private static func applyReplaceRule(_ content: String, rule: String?,
                                         webBook: WebBook, source: BookSource,
                                         book: Book, baseUrl: String) -> String {
        guard let rule, !rule.isEmpty else { return content }
        let analyzeRule = webBook.makeRule(book: book, source: source)
        analyzeRule.setContent(content)
        analyzeRule.setBaseUrl(baseUrl)
        let lines = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let joined = lines.joined(separator: "\n")
        analyzeRule.setContent(joined)
        var result = analyzeRule.getString(rule)
        result = result.components(separatedBy: "\n")
            .map { "　　" + $0 }
            .joined(separator: "\n")
        return result
    }

    private static func analyzePage(webBook: WebBook, source: BookSource, book: Book,
                                    chapter: BookChapter, baseUrl: String, redirectUrl: String,
                                    body: String, contentRule: ContentRule,
                                    nextChapterUrl: String?, getNextPageUrl: Bool = true) -> (content: String, nextUrls: [String]) {
        let analyzeRule = webBook.makeRule(book: book, source: source)
        analyzeRule.setContent(body, baseUrl: baseUrl)
        analyzeRule.setRedirectUrl(redirectUrl)
        analyzeRule.setNextChapterUrl(nextChapterUrl)
        analyzeRule.setChapter(chapter)

        var content = analyzeRule.getString(contentRule.content, unescape: false)
        if !book.isAudio && !book.isVideo {
            content = HtmlFormatter.formatKeepImg(content, redirectUrl: URL(string: redirectUrl))
            if content.contains("&") {
                content = content.unescapeHTML
            }
        }

        var nextUrls: [String] = []
        if getNextPageUrl, let nextRule = contentRule.nextContentUrl, !nextRule.isEmpty {
            if let urls = analyzeRule.getStringList(nextRule, isUrl: true) {
                nextUrls = urls
            }
        }
        return (content, nextUrls)
    }
}

// MARK: - 文案格式化

enum BookFormatter {
    static func formatName(_ name: String) -> String {
        name.replacingRegex("\\s+作\\s*者.*|\\s+\\S+\\s+著", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatAuthor(_ author: String) -> String {
        author.replacingRegex("^\\s*作\\s*者[:：\\s]+|\\s+著", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordCount(_ text: String?) -> String {
        guard let text, !text.isBlank else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let words = Double(trimmed) else { return trimmed }
        if words <= 0 { return "" }
        if words > 10000 {
            let wan = words / 10000
            let formatted = wan.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", wan)
                : String(format: "%.2f", wan).replacingRegex("0+$", with: "").replacingRegex("\\.$", with: "")
            return formatted + "万字"
        }
        return String(format: "%.0f", words) + "字"
    }

    static func isTrue(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }
}
