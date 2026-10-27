import Foundation

/// Cookie 存储，严格对齐上游两级模型：
/// - `<domain>_cookie`：持久 cookie，落库（`cookies` 表）
/// - `<domain>_session_cookie`：会话 cookie，仅内存，重启失效
/// - 读取时把会话 cookie 合并到持久 cookie 之上
/// - 合并后超过 4096 字节时随机剔除，直到合规
final class CookieStore: @unchecked Sendable {

    private let dao: CookieDao
    private let lock = NSLock()
    /// domain -> 持久 cookie 的内存缓存（减少 DB 读）
    private var cache: [String: String] = [:]
    /// domain -> 会话 cookie
    private var session: [String: String] = [:]

    private let maxCookieLength = 4096

    init(dao: CookieDao) {
        self.dao = dao
    }

    // MARK: - 读写

    func getCookie(_ url: String) -> String {
        let domain = NetworkUtils.getSubDomain(url)
        lock.lock()
        let persistent = cache[domain] ?? dao.get(domain)?.cookie ?? ""
        if cache[domain] == nil, !persistent.isEmpty {
            cache[domain] = persistent
        }
        let sessionCookie = session[domain] ?? ""
        lock.unlock()

        let merged = Self.mergeCookies(persistent, sessionCookie) ?? ""
        if merged.utf8.count <= maxCookieLength { return merged }

        // 超长裁剪：随机移除键（与上游一致）
        var map = Self.cookieToMap(merged)
        var cookie = merged
        while cookie.utf8.count > maxCookieLength, !map.isEmpty {
            if let key = map.keys.randomElement() {
                map.removeValue(forKey: key)
            } else {
                break
            }
            cookie = Self.mapToCookie(map) ?? ""
        }
        if cookie != merged { replaceCookie(domain, cookie) }
        return cookie
    }

    func getCookieNoSession(_ url: String) -> String {
        let domain = NetworkUtils.getSubDomain(url)
        lock.lock()
        if let hit = cache[domain] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let cookie = dao.get(domain)?.cookie ?? ""
        lock.lock()
        cache[domain] = cookie
        lock.unlock()
        return cookie
    }

    func setCookie(_ url: String, _ cookie: String?) {
        let domain = NetworkUtils.getSubDomain(url)
        setCookie(domain: domain, cookie ?? "")
    }

    private func setCookie(domain: String, _ cookie: String) {
        lock.lock()
        cache[domain] = cookie
        lock.unlock()
        dao.insert(Cookie(url: domain, cookie: cookie))
    }

    /// 合并写入：保留旧键，新值覆盖
    func replaceCookie(_ url: String, _ cookie: String) {
        replaceCookie(url: url, cookie: cookie, forcedDomain: nil)
    }

    func replaceCookie(domain: String, _ cookie: String) {
        replaceCookie(url: domain, cookie: cookie, forcedDomain: domain)
    }

    private func replaceCookie(url: String, cookie: String, forcedDomain: String?) {
        guard !cookie.isEmpty else { return }
        let domain = forcedDomain ?? NetworkUtils.getSubDomain(url)
        let old = getCookieNoSession(url)
        if old.isEmpty {
            setCookie(domain: domain, cookie)
        } else {
            var map = Self.cookieToMap(old)
            for (k, v) in Self.cookieToMap(cookie) { map[k] = v }
            setCookie(domain: domain, Self.mapToCookie(map) ?? cookie)
        }
    }

    func getKey(_ url: String, _ key: String) -> String {
        Self.cookieToMap(getCookie(url))[key] ?? ""
    }

    func removeCookie(_ url: String) {
        let domain = NetworkUtils.getSubDomain(url)
        lock.lock()
        cache.removeValue(forKey: domain)
        session.removeValue(forKey: domain)
        lock.unlock()
        dao.delete(domain)
    }

    func removeCookie(_ url: String, key: String) {
        let domain = NetworkUtils.getSubDomain(url)
        lock.lock()
        var sessionMap = Self.cookieToMap(session[domain] ?? "")
        sessionMap.removeValue(forKey: key)
        session[domain] = Self.mapToCookie(sessionMap) ?? ""
        lock.unlock()

        let persistent = getCookieNoSession(url)
        if !persistent.isEmpty {
            var map = Self.cookieToMap(persistent)
            map.removeValue(forKey: key)
            setCookie(domain: domain, Self.mapToCookie(map) ?? "")
        }
    }

    func clear() {
        lock.lock()
        cache.removeAll()
        session.removeAll()
        lock.unlock()
        dao.deleteAll()
    }

    // MARK: - 会话 cookie

    func sessionCookie(domain: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return session[domain]
    }

    func updateSessionCookie(domain: String, cookies: String) {
        guard !cookies.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if let old = session[domain], !old.isEmpty {
            session[domain] = Self.mergeCookies(old, cookies) ?? old
        } else {
            session[domain] = cookies
        }
    }

    // MARK: - HTTP 响应回写

    /// 处理响应里的 Set-Cookie：持久 cookie 落库，会话 cookie 留在内存
    func saveResponseCookies(url: String, setCookieHeaders: [String]) {
        guard !setCookieHeaders.isEmpty, let nsUrl = URL(string: url) else { return }
        var persistentPairs: [String] = []
        var sessionPairs: [String] = []

        for header in setCookieHeaders {
            let fields = ["Set-Cookie": header]
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: nsUrl)
            for cookie in cookies {
                let pair = "\(cookie.name)=\(cookie.value)"
                if cookie.expiresDate == nil && cookie.isSessionOnly {
                    sessionPairs.append(pair)
                } else if cookie.expiresDate == nil {
                    sessionPairs.append(pair)
                } else {
                    persistentPairs.append(pair)
                }
            }
        }

        let domain = NetworkUtils.getSubDomain(url)
        if !sessionPairs.isEmpty {
            updateSessionCookie(domain: domain, cookies: sessionPairs.joined(separator: "; "))
        }
        if !persistentPairs.isEmpty {
            replaceCookie(domain: domain, persistentPairs.joined(separator: "; "))
        }
    }

    /// WebView 拿到的 cookie 全部视为需要持久化（Cloudflare 的 cf_clearance 也在其中）
    func saveWebViewCookies(_ cookies: [HTTPCookie], keyURL: String) {
        guard !cookies.isEmpty else { return }
        var byDomain: [String: [String]] = [:]
        for cookie in cookies {
            let pair = "\(cookie.name)=\(cookie.value)"
            let domain = NetworkUtils.getSubDomain(keyURL)
            byDomain[domain, default: []].append(pair)
            // 同时按 cookie 自身域名存一份，便于跨域复用
            let cookieDomain = cookie.domain.hasPrefix(".")
                ? String(cookie.domain.dropFirst())
                : cookie.domain
            if !cookieDomain.isEmpty, cookieDomain != domain {
                byDomain[cookieDomain, default: []].append(pair)
            }
        }
        for (domain, pairs) in byDomain {
            replaceCookie(domain: domain, pairs.joined(separator: "; "))
        }
    }

    // MARK: - 工具

    static func cookieToMap(_ cookie: String) -> [String: String] {
        var map: [String: String] = [:]
        guard !cookie.isBlank else { return map }
        for pair in cookie.components(separatedBy: ";") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count > 1 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty || value == "null" {
                map[key] = value
            }
        }
        return map
    }

    static func mapToCookie(_ map: [String: String]?) -> String? {
        guard let map, !map.isEmpty else { return nil }
        return map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    static func mergeCookies(_ cookies: String?...) -> String? {
        var map: [String: String] = [:]
        var hasAny = false
        for cookie in cookies {
            guard let cookie, !cookie.isBlank else { continue }
            hasAny = true
            for (k, v) in cookieToMap(cookie) { map[k] = v }
        }
        return hasAny ? mapToCookie(map) : nil
    }
}
