import Foundation

// MARK: - JS 发起的请求

/// JS 侧 `java.get` / `java.post` / `java.connect` / `java.ajaxAll` 的入参。
/// 上游这些方法最终都落到 OkHttp，这里统一转成 `AnalyzeUrl` 的 `{...}` 选项，
/// 复用同一套编码、Cookie、限速、字符集探测逻辑。
struct JSHttpRequest {
    var url: String
    var method: String = "GET"
    var body: String?
    var timeout: Double?
    var headers: [String: String] = [:]

    /// 传给 AnalyzeUrl 的选项 JSON。GET 无附加参数时返回 nil（走最简路径）。
    var optionJSON: String? {
        var option: [String: Any] = [:]
        let upper = method.uppercased()
        if upper != "GET" { option["method"] = upper }
        if let body, !body.isEmpty { option["body"] = body }
        if !headers.isEmpty { option["headers"] = headers }
        if let timeout, timeout > 0 { option["timeout"] = Int(timeout) }
        guard !option.isEmpty else { return nil }
        return JSONTool.stringify(option)
    }
}

/// JS 侧的响应（对应上游 `StrResponse` / `Connection.Response`）
struct JSHttpResult {
    var url: String
    var code: Int
    var body: String
    var headers: [String: String]
    var message: String = "OK"

    func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        // HTTP 头大小写不敏感
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

// MARK: - 执行器

/// JS 里的网络调用是同步的（`java.ajax` 直接拿返回值），
/// 所以这里用 `SyncBridge` 把 async 请求挡在后台线程上。
enum JSRequestExecutor {

    static func perform(_ request: JSHttpRequest,
                        source: BookSource?,
                        book: Book?,
                        chapter: BookChapter?,
                        ruleData: RuleData?,
                        httpClient: HTTPClient?,
                        cookieStore: CookieStore?,
                        settings: AppSettings?) -> JSHttpResult? {
        guard let httpClient else {
            DebugLog.shared.log(source?.bookSourceName, "≡JS 环境未提供 HTTP 客户端")
            return nil
        }
        guard !request.url.isBlank else { return nil }

        let analyzeUrl = AnalyzeUrl(url: request.url,
                                    source: source,
                                    book: book,
                                    chapter: chapter,
                                    ruleData: ruleData,
                                    httpClient: httpClient,
                                    cookieStore: cookieStore,
                                    settings: settings,
                                    option: request.optionJSON)
        do {
            let response = try SyncBridge.run { try await analyzeUrl.strResponse() }
            return JSHttpResult(url: response.url,
                                code: response.code,
                                body: response.body ?? "",
                                headers: response.headers,
                                message: response.message)
        } catch {
            DebugLog.shared.log(source?.bookSourceName,
                                "≡JS \(request.method) 请求失败 \(request.url)\n\(error.localizedDescription)")
            return JSHttpResult(url: request.url, code: 500,
                                body: error.localizedDescription, headers: [:],
                                message: error.localizedDescription)
        }
    }

    /// 原始字节（图片、文件下载）
    static func performData(_ request: JSHttpRequest,
                            source: BookSource?,
                            book: Book?,
                            chapter: BookChapter?,
                            ruleData: RuleData?,
                            httpClient: HTTPClient?,
                            cookieStore: CookieStore?,
                            settings: AppSettings?) -> Data? {
        guard let httpClient else { return nil }
        let analyzeUrl = AnalyzeUrl(url: request.url,
                                    source: source,
                                    book: book,
                                    chapter: chapter,
                                    ruleData: ruleData,
                                    httpClient: httpClient,
                                    cookieStore: cookieStore,
                                    settings: settings,
                                    option: request.optionJSON)
        return try? SyncBridge.run { try await analyzeUrl.byteArray() }
    }

    /// 批量请求（`java.ajaxAll`）。上游并发，这里串行 —— 书源里的批量请求多为
    /// 目录分页，串行更不容易踩到站点限频，也不会把线程池占满。
    static func performAll(_ requests: [JSHttpRequest],
                           source: BookSource?,
                           book: Book?,
                           chapter: BookChapter?,
                           ruleData: RuleData?,
                           httpClient: HTTPClient?,
                           cookieStore: CookieStore?,
                           settings: AppSettings?) -> [JSHttpResult] {
        requests.compactMap {
            perform($0, source: source, book: book, chapter: chapter,
                    ruleData: ruleData, httpClient: httpClient,
                    cookieStore: cookieStore, settings: settings)
        }
    }
}
