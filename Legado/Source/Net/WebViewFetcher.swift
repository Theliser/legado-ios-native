import Foundation
import WebKit

struct WebViewFetcherOptions {
    var js: String = "document.documentElement.outerHTML"
    var html: String?
    var url: String?
    var headers: [String: String] = [:]
    var sourceRegex: String?
    var overrideUrlRegex: String?
    var delayMs: Int = 0
    var timeout: TimeInterval = 60
    /// cookie 落库使用的地址（通常是书源 key）
    var cookieKeyURL: String?
    var cacheFirst: Bool = false
}

/// 隐藏的 WKWebView 请求器，替代上游 `BackstageWebView`。
///
/// 关键细节（与上游对齐）：
/// 1. UA 与普通请求完全一致，否则 Cloudflare 的 `cf_clearance` 会失效；
/// 2. 载入前把已持久化的 cookie（含 `cf_clearance`）注入 WebView；
/// 3. 页面加载完成后把 WebView 的 cookie 全量落库 —— 这是“过完 CF 之后纯 HTTP 也能继续用”的关键；
/// 4. 加载完成后再等 1s + delayTime 才执行 JS，结果为空/`null` 时每秒重试，最多 30 次；
/// 5. 页面重定向时标记 `isRedirect`，上层据此修正 bookUrl。
@MainActor
final class WebViewService {
    static let shared = WebViewService()
    private let fetcher = WebViewFetcher()

    func fetch(_ options: WebViewFetcherOptions,
               cookieStore: CookieStore?,
               cookieJar: Bool) async throws -> StrResponse {
        try await fetcher.fetch(options, cookieStore: cookieStore, cookieJar: cookieJar)
    }
}

@MainActor
final class WebViewFetcher: NSObject {

    private var active: [UUID: WKWebView] = [:]

    func fetch(_ options: WebViewFetcherOptions,
               cookieStore: CookieStore?,
               cookieJar: Bool) async throws -> StrResponse {
        let id = UUID()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 860), configuration: config)
        webView.customUserAgent = options.headers["User-Agent"]
        active[id] = webView

        let controller = NavigationController(options: options, cookieStore: cookieJar ? cookieStore : nil)
        controller.webView = webView
        webView.navigationDelegate = controller
        controller.onFinish = { [weak self] in
            self?.active.removeValue(forKey: id)
        }

        if options.sourceRegex != nil {
            let script = WKUserScript(source: Self.sniffScript,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false)
            webView.configuration.userContentController.addUserScript(script)
        }

        if let urlString = options.url, let url = URL(string: urlString), let cookieStore, cookieJar {
            let pairs = CookieStore.cookieToMap(cookieStore.getCookie(urlString))
            if !pairs.isEmpty {
                await inject(pairs, for: url, into: webView)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            controller.start(continuation: continuation)
        }
    }

    private func inject(_ pairs: [String: String], for url: URL, into webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (name, value) in pairs {
                var props: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: url.host ?? "",
                    .path: "/"
                ]
                if url.scheme == "https" { props[.secure] = "TRUE" }
                guard let cookie = HTTPCookie(properties: props) else { continue }
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { continuation.resume() }
        }
    }

    static let defaultJS = "document.documentElement.outerHTML"

    private static let sniffScript = """
    (function(){
      if (window.__legadoSniff) return;
      window.__legadoSniff = [];
      function push(u){ try { if (u) window.__legadoSniff.push(String(u)); } catch(e){} }
      try {
        var open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(m, u){ push(u); return open.apply(this, arguments); };
      } catch(e){}
      try {
        var f = window.fetch;
        window.fetch = function(i){ try { push(typeof i === 'string' ? i : (i && i.url)); } catch(e){} return f.apply(this, arguments); };
      } catch(e){}
    })();
    """

    // MARK: - 导航控制

    private final class NavigationController: NSObject, WKNavigationDelegate {
        private let options: WebViewFetcherOptions
        private let cookieStore: CookieStore?
        private var continuation: CheckedContinuation<StrResponse, Error>?
        private var finished = false
        private var timeoutTask: Task<Void, Never>?
        weak var webView: WKWebView?
        var onFinish: (() -> Void)?

        init(options: WebViewFetcherOptions, cookieStore: CookieStore?) {
            self.options = options
            self.cookieStore = cookieStore
        }

        func start(continuation: CheckedContinuation<StrResponse, Error>) {
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(5, options.timeout) * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.finished else { return }
                self.finish(.failure(URLError(.timedOut)))
            }
            load()
        }

        func cancel() { finish(.failure(CancellationError())) }

        private func load() {
            guard let webView else { return }
            if let html = options.html, !html.isEmpty {
                webView.loadHTMLString(html, baseURL: options.url.flatMap { URL(string: $0) })
                return
            }
            guard let urlString = options.url, let url = URL(string: urlString) else {
                finish(.failure(URLError(.badURL)))
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = options.timeout
            for (k, v) in options.headers where k.lowercased() != "cookie" {
                request.setValue(v, forHTTPHeaderField: k)
            }
            webView.load(request)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let delayMs = 1000 + max(0, options.delayMs)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                await self.collect()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            finish(.failure(error))
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        private func collect() async {
            guard !finished, let webView else { return }

            // 先落一次 cookie：挑战页通过时 cookie 已写入，后续重试才能拿到正文
            await persistCookies(from: webView)

            for attempt in 0...30 {
                if finished { return }
                var value: Any?
                do {
                    value = try await webView.evaluateJavaScript(options.js)
                } catch {
                    value = nil
                }
                if let text = value as? String, !text.isEmpty, text != "null" {
                    if let regex = options.sourceRegex,
                       let sniffed = await sniffedURL(matching: regex, in: webView) {
                        finish(.success(StrResponse(url: options.url ?? "", body: sniffed)))
                        return
                    }
                    await persistCookies(from: webView)
                    finish(.success(buildResponse(body: text, webView: webView)))
                    return
                }
                if attempt < 30 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await persistCookies(from: webView)
                }
            }
            finish(.failure(NSError(domain: "Legado.WebView", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "js执行超时"])))
        }

        private func sniffedURL(matching pattern: String, in webView: WKWebView) async -> String? {
            guard let raw = try? await webView.evaluateJavaScript("JSON.stringify(window.__legadoSniff||[])"),
                  let json = raw as? String,
                  let data = json.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
            if let hit = list.first(where: { $0.matchesFully(pattern) }) { return hit }
            return list.first(where: { $0.containsRegex(pattern) })
        }

        private func persistCookies(from webView: WKWebView) async {
            guard let cookieStore, let keyURL = options.cookieKeyURL ?? options.url else { return }
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                    continuation.resume(returning: $0)
                }
            }
            cookieStore.saveWebViewCookies(cookies, keyURL: keyURL)
        }

        private func buildResponse(body: String, webView: WKWebView) -> StrResponse {
            let finalURL = webView.url?.absoluteString ?? options.url ?? ""
            var response = StrResponse(url: finalURL, body: body)
            if let origin = options.url, !HTTPClient.sameURL(origin, finalURL) {
                response.isRedirect = true
                response.priorUrl = origin
            }
            return response
        }

        private func finish(_ result: Result<StrResponse, Error>) {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            if let continuation {
                self.continuation = nil
                switch result {
                case .success(let response): continuation.resume(returning: response)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            onFinish?()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let regex = options.overrideUrlRegex,
               let url = navigationAction.request.url?.absoluteString,
               url.matchesFully(regex) {
                finish(.success(StrResponse(url: options.url ?? url, body: url)))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
