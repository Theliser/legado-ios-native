import Foundation

struct HTTPRequestSpec {
    var url: String
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
    var charset: String?
    var retry: Int = 0
    var timeout: TimeInterval = 60
    /// 书源 enabledCookieJar：请求前注入已存 cookie，响应后回写
    var cookieJar: Bool = false
    var followRedirects: Bool = true
}

/// 请求拦截钩子：基准测试用来录制真实响应、之后离线回放。
///
/// 刻意做在 HTTPClient 而不是 URLProtocol 上 —— 这里拿到的是**已经解码好**的
/// `StrResponse`（字符集探测、XML 声明补全、Cookie 回写都做完了），
/// 回放时不必重做一遍，也就不会出现「回放和真实请求结果不一致」的假象。
struct HTTPHook {
    /// 返回非 nil 就直接当响应，不发网络
    var replay: (@Sendable (HTTPRequestSpec) -> StrResponse?)?
    /// 真实请求成功后回调
    var record: (@Sendable (HTTPRequestSpec, StrResponse) -> Void)?
}

/// 基于 URLSession 的请求层。
/// 对齐上游 OkHttp 的行为：默认 UA、Keep-Alive、CookieJar 头语义、重试、字符集探测、重定向标记。
final class HTTPClient: NSObject, URLSessionDelegate, @unchecked Sendable {

    private let settings: AppSettings
    private let cookieStore: CookieStore
    private var session: URLSession!
    /// 基准测试的录制/回放钩子；生产环境保持 nil
    var hook: HTTPHook?
    /// JS 里的 `java.ajax` 是同步调用，这里用信号量把它挡在后台线程上
    private let syncQueue = DispatchQueue(label: "legado.http.sync", attributes: .concurrent)

    /// - Parameter proxy: 形如 `http://127.0.0.1:10808`。仅基准测试/调试用，
    ///   生产环境传 nil，走系统默认网络栈。
    init(settings: AppSettings, cookieStore: CookieStore, proxy: String? = nil) {
        self.settings = settings
        self.cookieStore = cookieStore
        super.init()

        let config = URLSessionConfiguration.default
        if let proxy, let components = URLComponents(string: proxy),
           let host = components.host {
            let port = components.port ?? 1080
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port
            ]
        }
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = [:]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - 异步请求

    func request(_ spec: HTTPRequestSpec) async throws -> StrResponse {
        var lastError: Error?
        let attempts = max(0, spec.retry)

        for attempt in 0...attempts {
            do {
                let response = try await perform(spec)
                // 上游 newCallResponse：非 2xx 时重试，最后一次原样返回
                if response.isSuccessful || attempt == attempts {
                    return response
                }
            } catch {
                lastError = error
                if attempt == attempts { throw error }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func perform(_ spec: HTTPRequestSpec) async throws -> StrResponse {
        if let canned = hook?.replay?(spec) { return canned }
        guard let url = Self.makeURL(spec.url) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = spec.method
        request.timeoutInterval = spec.timeout

        var headers = spec.headers
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = settings.userAgent
        }
        headers["Keep-Alive"] = headers["Keep-Alive"] ?? "300"
        headers["Connection"] = headers["Connection"] ?? "Keep-Alive"

        if spec.cookieJar {
            let stored = cookieStore.getCookie(spec.url)
            if !stored.isEmpty {
                let merged = CookieStore.mergeCookies(headers["Cookie"], stored) ?? stored
                headers["Cookie"] = merged
            }
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = spec.body

        let start = Date()
        let (data, response) = try await session.data(for: request)
        let cost = Int(Date().timeIntervalSince(start) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if spec.cookieJar {
            let setCookies = Self.setCookieHeaders(from: http)
            if !setCookies.isEmpty {
                cookieStore.saveResponseCookies(url: spec.url, setCookieHeaders: setCookies)
            }
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        var body = decode(data: data, contentType: contentType, charset: spec.charset)
        // XML 响应补上声明（对齐上游）
        if let ct = contentType, ct.range(of: "(application|text)/\\w*\\+?xml.*", options: .regularExpression) != nil,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<?xml") {
            body = "<?xml version=\"1.0\"?>" + body
        }

        let finalURL = http.url?.absoluteString ?? spec.url
        var headerMap: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            headerMap["\(k)"] = "\(v)"
        }

        var result = StrResponse(url: finalURL, body: body, code: http.statusCode,
                                 message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        result.headers = headerMap
        result.data = data
        result.callTime = cost
        let original = request.url?.absoluteString ?? spec.url
        if !Self.sameURL(original, finalURL) {
            result.isRedirect = true
            result.priorUrl = original
        }
        hook?.record?(spec, result)
        return result
    }

    private func decode(data: Data, contentType: String?, charset: String?) -> String {
        if let charset, !charset.isEmpty {
            return EncodingDetect.decode(data, charset: charset)
        }
        if let contentType, let range = contentType.range(of: "charset=([\\w\\-]+)", options: [.regularExpression, .caseInsensitive]) {
            let value = String(contentType[range]).replacingOccurrences(of: "charset=", with: "", options: .caseInsensitive)
            return EncodingDetect.decode(data, charset: value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ;")))
        }
        return EncodingDetect.decode(data, charset: EncodingDetect.htmlEncoding(data))
    }

    // MARK: - 同步请求（供 JS 使用）

    func requestSync(_ spec: HTTPRequestSpec) -> StrResponse {
        var result: StrResponse?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            do {
                result = try await self.request(spec)
            } catch {
                result = StrResponse.error(url: spec.url, error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result ?? StrResponse(url: spec.url, error: "请求失败")
    }

    // MARK: - URL 规整

    /// 把规则产出的原始地址转成 URL。
    ///
    /// 关键点：**不能整串跑 addingPercentEncoding**，否则已有的 `%XX` 会被再编码成
    /// `%25XX`（书源里带中文参数的地址基本都是已编码的，这样必然 404）。
    /// 这里先把 `%` 挡住再转义，最后还原。
    static func makeURL(_ raw: String) -> URL? {
        if let direct = URL(string: raw), direct.scheme != nil,
           direct.absoluteString.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return direct
        }
        let shielded = raw.replacingOccurrences(of: "%", with: "\u{1}")
        guard let encoded = shielded.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return nil
        }
        let restored = encoded.replacingOccurrences(of: "\u{1}", with: "%")
        guard let url = URL(string: restored),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: - Set-Cookie

    /// iOS 会把多个 Set-Cookie 合并成一个逗号分隔的字符串，需要按 `, name=` 边界拆开
    static func setCookieHeaders(from response: HTTPURLResponse) -> [String] {
        var raw: [String] = []
        for (key, value) in response.allHeaderFields {
            let name = "\(key)".lowercased()
            if name == "set-cookie" {
                if let list = value as? [String] {
                    raw.append(contentsOf: list)
                } else {
                    raw.append("\(value)")
                }
            }
        }
        var result: [String] = []
        for item in raw {
            result.append(contentsOf: splitCombinedSetCookie(item))
        }
        return result
    }

    static func splitCombinedSetCookie(_ header: String) -> [String] {
        // 逗号后紧跟 `token=` 才是新 cookie 的开始（Expires 里的逗号后面是空格+日期）
        let pattern = ",(?=\\s*[A-Za-z0-9_\\-\\.]+=)"
        let parts = header.replacingRegex(pattern, with: "\u{1}").components(separatedBy: "\u{1}")
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func sameURL(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let ua = URL(string: a), let ub = URL(string: b) else { return false }
        return ua.host == ub.host && ua.path == ub.path && ua.query == ub.query
    }

    // MARK: - TLS

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              settings.allowInsecureTLS else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 与上游 SSLHelper.unsafeTrustManager 行为一致：书源站点常见自签/过期证书
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
