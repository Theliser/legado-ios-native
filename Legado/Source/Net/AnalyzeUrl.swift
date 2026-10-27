import Foundation

/// URL 规则解析，对齐上游 `AnalyzeUrl`。
/// 支持：`url,{json选项}`、`<1,2,3>` 分页、`{{js}}`、`@js:`、query/form 编码、charset、retry、webView、webJs、bodyJs。
final class AnalyzeUrl {

    // MARK: - 输入

    private let mUrl: String
    private let key: String?
    private let page: Int?
    private let baseUrlInput: String
    private let source: BookSource?
    private var book: Book?
    private var chapter: BookChapter?
    private var ruleData: RuleData?
    private let httpClient: HTTPClient
    private let cookieStore: CookieStore?
    private let settings: AppSettings?

    // MARK: - 输出

    private(set) var ruleUrl = ""
    private(set) var url = ""
    private(set) var urlNoQuery = ""
    private(set) var type: String?
    private(set) var method = "GET"
    var headerMap: [String: String] = [:]
    private(set) var serverID: Int64?

    // MARK: - 内部

    private var body: String?
    private var encodedForm: String?
    private(set) var encodedQuery: String?
    private(set) var charset: String?
    private(set) var retry = 0
    private var useWebView = false
    private var webJs: String?
    private var bodyJs: String?
    private var dnsIp: String?
    private var webViewDelayTime = 0
    private var baseUrl: String
    private var enabledCookieJar: Bool = false
    private var domain: String = ""
    private var readTimeout: TimeInterval = 60

    private static let paramPattern = "\\s*,\\s*(?=\\{)"
    private static let pagePattern = "<(.*?)>"

    init(url: String,
         key: String? = nil,
         page: Int? = nil,
         baseUrl: String = "",
         source: BookSource? = nil,
         book: Book? = nil,
         chapter: BookChapter? = nil,
         ruleData: RuleData? = nil,
         httpClient: HTTPClient,
         cookieStore: CookieStore? = nil,
         settings: AppSettings? = nil) {
        self.mUrl = url
        self.key = key
        self.page = page
        self.ruleUrl = url
        self.baseUrlInput = baseUrl
        self.baseUrl = baseUrl
        self.source = source
        self.book = book
        self.chapter = chapter
        self.ruleData = ruleData
        self.httpClient = httpClient
        self.cookieStore = cookieStore
        self.settings = settings
        self.enabledCookieJar = source?.enabledCookieJar ?? false

        var headers = source?.headerMap(userAgent: settings?.userAgent) ?? [:]
        if headers["User-Agent"] == nil, let ua = settings?.userAgent {
            headers["User-Agent"] = ua
        }
        self.headerMap = headers

        if let match = baseUrl.firstMatch(Self.paramPattern) {
            let prefix = (baseUrl as NSString).substring(to: match.range.location)
            self.baseUrl = prefix
        }
        initUrl()
        self.domain = NetworkUtils.getSubDomain(source?.bookSourceUrl ?? url)
    }

    // MARK: - URL 构造

    private func initUrl() {
        ruleUrl = mUrl
        analyzeJS()
        replaceKeyPageJS()
        analyzeUrl()
    }

    /// 执行 URL 内的 @js / <js></js>
    private func analyzeJS() {
        var start = 0
        var result = ruleUrl
        let ns = ruleUrl as NSString
        let matches = (try? NSRegularExpression(pattern: "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)",
                                                options: [.caseInsensitive]))?
            .matches(in: ruleUrl, options: [], range: NSRange(location: 0, length: ns.length)) ?? []

        for match in matches {
            if match.range.location > start {
                let piece = ns.substring(with: NSRange(location: start, length: match.range.location - start))
                    .trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty {
                    result = piece.replacingOccurrences(of: "@result", with: result)
                }
            }
            let group2 = ns.substring(with: match.range(at: 2), fallback: "")
            let group1 = ns.substring(with: match.range(at: 1), fallback: "")
            let js = group2.isEmpty ? group1 : group2
            let value = evalJS(js, result: result)
            result = AnalyzeRule.stringValue(value)
            start = match.range.location + match.range.length
        }
        if ns.length > start {
            let piece = ns.substring(from: start).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty {
                result = piece.replacingOccurrences(of: "@result", with: result)
            }
        }
        ruleUrl = result
    }

    /// 替换 {{js}} 与 <page> 分页
    private func replaceKeyPageJS() {
        if ruleUrl.contains("{{") && ruleUrl.contains("}}") {
            let analyzer = RuleAnalyzer(ruleUrl)
            let replaced = analyzer.innerRule("{{", "}}") { [weak self] js in
                guard let self else { return "" }
                let value = self.evalJS(js)
                if let d = value as? Double, d.truncatingRemainder(dividingBy: 1) == 0 {
                    return String(format: "%.0f", d)
                }
                return AnalyzeRule.stringValue(value)
            }
            if !replaced.isEmpty { ruleUrl = replaced }
        }

        if let page, let regex = RegexCache.shared.regex(Self.pagePattern) {
            let ns = ruleUrl as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: ruleUrl, options: [], range: fullRange) {
                let pages = ns.substring(with: match.range(at: 1)).components(separatedBy: ",")
                let replacement: String
                if page < pages.count {
                    replacement = pages[max(0, page - 1)].trimmingCharacters(in: .whitespaces)
                } else {
                    replacement = (pages.last ?? "").trimmingCharacters(in: .whitespaces)
                }
                ruleUrl = ruleUrl.replacingOccurrences(of: ns.substring(with: match.range), with: replacement)
            }
        }
    }

    private func analyzeUrl() {
        let urlMatch = ruleUrl.firstMatch(Self.paramPattern)
        let urlNoOption: String
        if let urlMatch {
            urlNoOption = (ruleUrl as NSString).substring(to: urlMatch.range.location)
        } else {
            urlNoOption = ruleUrl
        }
        url = NetworkUtils.getAbsoluteURL(baseUrl, urlNoOption)
        if let base = NetworkUtils.getBaseUrl(url) { baseUrl = base }

        if let urlMatch {
            let optionText = (ruleUrl as NSString)
                .substring(from: urlMatch.range.location + urlMatch.range.length)
            applyOption(optionText)
        }

        urlNoQuery = url
        switch method {
        case "POST":
            if let body, !body.isJSONText, !body.isXMLText, (headerMap["Content-Type"] ?? "").isEmpty {
                encodedForm = encodeParams(body, charset: charset, isQuery: false)
            }
        case "GET":
            if let qIndex = url.firstIndex(of: "?") {
                let query = String(url[url.index(after: qIndex)...])
                encodedQuery = encodeParams(query, charset: charset, isQuery: true)
                urlNoQuery = String(url[..<qIndex])
            }
        default:
            break
        }
    }

    private func applyOption(_ text: String) {
        guard let option = JSONTool.parseObject(text) else {
            DebugLog.shared.log(source?.bookSourceName, "≡链接参数不是合法 JSON: \(text)")
            return
        }

        func string(_ key: String) -> String? {
            guard let v = option[key] else { return nil }
            if let s = v as? String, !s.isBlank { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }

        if let m = string("method") { method = m.uppercased() }

        if let headers = option["headers"] {
            var map: [String: Any]?
            if let dict = headers as? [String: Any] {
                map = dict
            } else if let s = headers as? String {
                map = JSONTool.parseObject(s)
            }
            map?.forEach { key, value in
                headerMap[key] = AnalyzeRule.stringValue(value)
            }
        }

        if let b = option["body"] {
            if let s = b as? String {
                body = s
            } else if JSONSerialization.isValidJSONObject(b) {
                body = JSONTool.stringify(b)
            }
        }

        type = string("type")
        charset = string("charset")
        if let r = option["retry"] {
            retry = (r as? NSNumber)?.intValue ?? Int(AnalyzeRule.stringValue(r)) ?? 0
        }
        if let w = option["webView"] {
            if let b = w as? Bool { useWebView = b }
            else if let s = w as? String { useWebView = !(s.isEmpty || s == "false") }
            else if let n = w as? NSNumber { useWebView = n.boolValue }
        }
        webJs = string("webJs")
        bodyJs = string("bodyJs")
        dnsIp = string("dnsIp")
        if let sid = string("serverID") { serverID = Int64(sid) }
        if let delay = string("webViewDelayTime") { webViewDelayTime = max(0, Int(delay) ?? 0) }

        if let js = string("js") {
            if let value = evalJS(js, result: url) {
                let s = AnalyzeRule.stringValue(value)
                if !s.isEmpty { url = s }
            }
        }
    }

    // MARK: - 编码

    private func encodeParams(_ params: String, charset: String?, isQuery: Bool) -> String {
        let checkEncoded = (charset ?? "").isEmpty
        let effectiveCharset: String?
        if let charset, !charset.isEmpty {
            effectiveCharset = charset.lowercased() == "escape" ? nil : charset
        } else {
            effectiveCharset = "UTF-8"
        }

        if isQuery, effectiveCharset != nil {
            if NetworkUtils.encodedQuery(params) { return params }
            return encodeQuery(params, charset: effectiveCharset ?? "UTF-8")
        }

        let ns = params as NSString
        var builder = ""
        var pos = 0
        let len = ns.length
        while pos <= len {
            if !builder.isEmpty { builder += "&" }
            var ampOffset = ns.range(of: "&", options: [], range: NSRange(location: pos, length: len - pos)).location
            if ampOffset == NSNotFound { ampOffset = len }
            let eqOffset = ns.range(of: "=", options: [], range: NSRange(location: pos, length: len - pos)).location

            let keyPart: String
            let valuePart: String?
            if eqOffset == NSNotFound || eqOffset > ampOffset {
                keyPart = ns.substring(with: NSRange(location: pos, length: ampOffset - pos))
                valuePart = nil
            } else {
                keyPart = ns.substring(with: NSRange(location: pos, length: eqOffset - pos))
                valuePart = ns.substring(with: NSRange(location: eqOffset + 1, length: ampOffset - eqOffset - 1))
            }
            builder += encodeValue(keyPart, checkEncoded: checkEncoded, charset: effectiveCharset)
            if let valuePart {
                builder += "="
                builder += encodeValue(valuePart, checkEncoded: checkEncoded, charset: effectiveCharset)
            }
            pos = ampOffset + 1
        }
        return builder
    }

    private func encodeValue(_ value: String, checkEncoded: Bool, charset: String?) -> String {
        if checkEncoded && NetworkUtils.encodedForm(value) { return value }
        if charset == nil { return CryptoUtils.escape(value) }
        return CryptoUtils.urlEncode(value, charset: charset ?? "UTF-8")
    }

    private func encodeQuery(_ query: String, charset: String) -> String {
        var builder = ""
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~!$%&()*+,/:;=?@[]^`{|}")
        for ch in query {
            if ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first, scalar.value < 128, safe.contains(ch) {
                builder.append(ch)
            } else {
                let encoded = CryptoUtils.urlEncode(String(ch), charset: charset)
                builder += encoded
            }
        }
        return builder
    }

    // MARK: - JS

    func evalJS(_ jsStr: String, result: Any? = nil) -> Any? {
        var env = JSEnvironment()
        env.source = source
        env.book = book
        env.chapter = chapter
        env.baseUrl = baseUrl
        env.result = result
        env.page = page
        env.key = key
        env.variables = VariableAdapter(analyze: self)
        env.ajax = { [weak self] url, timeout in
            self?.ajax(url, timeout: timeout) ?? ""
        }
        let jsKey = source?.bookSourceUrl ?? "url"
        return JSRuntime.shared.evaluate(jsStr, key: jsKey, env: env)
    }

    private func ajax(_ url: String, timeout: Double?) -> String? {
        let analyzeUrl = AnalyzeUrl(url: url, source: source, book: book, chapter: chapter,
                                    ruleData: ruleData, httpClient: httpClient,
                                    cookieStore: cookieStore, settings: settings)
        return try? SyncBridge.run { try await analyzeUrl.strResponse().body ?? "" }
    }

    private final class VariableAdapter: JSVariableStore {
        weak var analyze: AnalyzeUrl?
        init(analyze: AnalyzeUrl) { self.analyze = analyze }

        func jsGet(_ key: String) -> String {
            guard let analyze else { return "" }
            if key == "bookName" { return analyze.book?.name ?? "" }
            if key == "title" { return analyze.chapter?.title ?? "" }
            return analyze.chapter?.variableMap[key]
                ?? analyze.book?.variableMap[key]
                ?? analyze.ruleData?.variableMap[key]
                ?? ""
        }

        func jsPut(_ key: String, _ value: String) {
            guard let analyze else { return }
            if var chapter = analyze.chapter {
                var map = chapter.variableMap
                map[key] = value
                chapter.variableMap = map
                analyze.chapter = chapter
            } else if var book = analyze.book {
                var map = book.variableMap
                map[key] = value
                book.variableMap = map
                analyze.book = book
            } else if let ruleData = analyze.ruleData {
                ruleData.putVariable(key, value)
            }
        }
    }

    // MARK: - 请求

    func strResponse(useWebView: Bool = true, sourceRegex: String? = nil,
                     isTest: Bool = false, skipRateLimit: Bool = false) async throws -> StrResponse {
        if type != nil {
            let data = try await byteArray()
            return StrResponse(url: url, body: data.map { String(format: "%02x", $0) }.joined())
        }
        return try await execute(useWebView: useWebView, sourceRegex: sourceRegex,
                                 isTest: isTest, skipRateLimit: skipRateLimit)
    }

    private func execute(useWebView: Bool, sourceRegex: String?, isTest: Bool,
                         skipRateLimit: Bool = false) async throws -> StrResponse {
        // 书源并发率：同一书源的所有请求共享计数
        if !skipRateLimit {
            await ConcurrentRateLimiter.shared.acquire(key: source?.bookSourceUrl,
                                                       concurrentRate: source?.concurrentRate)
        }
        setCookie()
        let start = Date()

        do {
            var response: StrResponse
            if self.useWebView && useWebView {
                var options = WebViewFetcherOptions(
                    js: webJs ?? "document.documentElement.outerHTML",
                    html: nil,
                    url: url,
                    headers: headerMap,
                    cookieKeyURL: source?.bookSourceUrl ?? url
                )
                options.sourceRegex = sourceRegex
                options.delayMs = webViewDelayTime
                response = try await WebViewService.shared.fetch(options,
                                                                 cookieStore: cookieStore,
                                                                 cookieJar: enabledCookieJar)
            } else {
                let spec = HTTPRequestSpec(
                    url: requestURL,
                    method: method,
                    headers: requestHeaders(),
                    body: requestBody(),
                    charset: charset,
                    retry: retry,
                    timeout: readTimeout,
                    cookieJar: enabledCookieJar
                )
                response = try await httpClient.request(spec)
                if let bodyJs, let bodyText = response.body {
                    let value = evalJS(bodyJs, result: bodyText)
                    response.body = AnalyzeRule.stringValue(value)
                }
            }
            response.putCallTime(Int(Date().timeIntervalSince(start) * 1000))
            return response
        } catch {
            guard isTest else { throw error }
            // 对齐上游：用负数 callTime 表示错误类别，调试页据此显示
            let code: Int
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:           code = -2   // 超时
                case .cannotFindHost:     code = -3   // 域名解析失败
                case .cannotConnectToHost: code = -4  // 连接被拒绝
                case .networkConnectionLost: code = -5 // 连接中断
                case .secureConnectionFailed, .serverCertificateUntrusted: code = -6
                default:                  code = -7
                }
            } else {
                code = -7
            }
            var response = StrResponse(url: url, error: error.localizedDescription)
            response.putCallTime(code)
            return response
        }
    }

    private func requestHeaders() -> [String: String] {
        var headers = headerMap
        headers.removeValue(forKey: "CookieJar")
        return headers
    }

    private func requestBody() -> Data? {
        switch method {
        case "POST":
            if let encodedForm, !encodedForm.isEmpty {
                if headerMap["Content-Type"] == nil {
                    headerMap["Content-Type"] = "application/x-www-form-urlencoded"
                }
                return encodedForm.data(using: .utf8)
            }
            if let body, !body.isBlank {
                return body.data(using: .utf8)
            }
            return nil
        default:
            return nil
        }
    }

    /// 组装最终 URL（query 编码后拼回）
    private var requestURL: String {
        if method == "GET", let encodedQuery, !encodedQuery.isEmpty {
            return urlNoQuery + "?" + encodedQuery
        }
        return urlNoQuery.isEmpty ? url : urlNoQuery
    }

    func setCookie() {
        guard let cookieStore else { return }
        let cookie = cookieStore.getCookie(domain)
        if !cookie.isEmpty {
            if let merged = CookieStore.mergeCookies(cookie, headerMap["Cookie"]) {
                headerMap["Cookie"] = merged
            }
        }
        if enabledCookieJar {
            headerMap["CookieJar"] = "1"
        } else {
            headerMap.removeValue(forKey: "CookieJar")
        }
    }

    func byteArray() async throws -> Data {
        if urlNoQuery.hasPrefix("data:"),
           let groups = urlNoQuery.firstMatchGroups("^data:.*?;base64,(.*)"),
           groups.count > 1, let data = CryptoUtils.base64DecodeData(groups[1]) {
            return data
        }
        let spec = HTTPRequestSpec(url: url, method: method, headers: requestHeaders(),
                                   body: requestBody(), charset: charset, retry: retry,
                                   timeout: readTimeout, cookieJar: enabledCookieJar)
        return try await httpClient.request(spec).data ?? Data()
    }
}

// MARK: - 同步桥

enum SyncBridge {
    /// 在同步上下文里等待一个 async 操作（JS 的 `java.ajax` 需要同步返回）
    static func run<T>(_ operation: @escaping () async throws -> T) throws -> T {
        if Thread.isMainThread {
            var result: Result<T, Error>?
            let task = Task {
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
            }
            while result == nil {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            _ = task
            return try result!.get()
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task.detached {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result else { throw URLError(.unknown) }
        return try result.get()
    }
}
