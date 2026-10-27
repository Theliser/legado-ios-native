import Foundation

/// 对齐上游 `NetworkUtils`：
/// - `getBaseUrl` / `getAbsoluteURL`：URL 拼接语义与 Java `java.net.URL` 保持一致
/// - `getSubDomain`：cookie 的存储键（可注册域名 / 二级域名），IP 直用
/// - `encodedQuery` / `encodedForm`：判断是否已编码，避免重复编码
enum NetworkUtils {

    // MARK: - Base URL

    static func getBaseUrl(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        let start = url.index(url.startIndex, offsetBy: 9, limitedBy: url.endIndex) ?? url.endIndex
        guard let slash = url[start...].firstIndex(of: "/") else { return url }
        return String(url[..<slash])
    }

    static func getDomain(_ url: String) -> String {
        guard let base = getBaseUrl(url), let host = URL(string: base)?.host else { return url }
        return host
    }

    // MARK: - 绝对地址

    static func getAbsoluteURL(_ baseURL: String?, _ relativePath: String) -> String {
        let rel = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL, !baseURL.isEmpty else { return rel }
        if rel.isAbsURL { return rel }
        if rel.isDataURL { return rel }
        if rel.lowercased().hasPrefix("javascript") { return "" }

        let baseStr = baseURL.components(separatedBy: ",").first ?? baseURL
        let cleanedBase = baseStr.trimmingCharacters(in: .whitespacesAndNewlines)

        if let base = URL(string: cleanedBase), let resolved = URL(string: rel, relativeTo: base) {
            return resolved.absoluteString
        }

        // 兜底：手工拼接（等价 java.net.URL(base, relative) 的常见分支）
        if rel.hasPrefix("//"), let scheme = cleanedBase.split(separator: ":").first {
            return "\(scheme):\(rel)"
        }
        if rel.hasPrefix("/") {
            if let base = getBaseUrl(cleanedBase) { return base + rel }
        }
        if rel.isEmpty { return cleanedBase }
        if cleanedBase.hasSuffix("/") { return cleanedBase + rel }
        if let base = getBaseUrl(cleanedBase) {
            let path = cleanedBase.hasPrefix(base) ? String(cleanedBase.dropFirst(base.count)) : ""
            if path.isEmpty || path.hasSuffix("/") { return cleanedBase + rel }
            let dir = (path as NSString).deletingLastPathComponent
            return base + dir + "/" + rel
        }
        return rel
    }

    static func getAbsoluteURL(_ baseURL: URL?, _ relativePath: String) -> String {
        getAbsoluteURL(baseURL?.absoluteString, relativePath)
    }

    // MARK: - 二级域名

    private static let multiLabelSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn", "mil.cn",
        "com.hk", "net.hk", "org.hk", "edu.hk", "gov.hk", "idv.hk",
        "com.tw", "net.tw", "org.tw", "edu.tw", "gov.tw", "idv.tw",
        "com.mo", "net.mo", "org.mo", "edu.mo", "gov.mo",
        "co.uk", "org.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "me.uk", "net.uk",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ad.jp", "ed.jp", "gr.jp", "lg.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "geek.nz", "school.nz",
        "com.sg", "net.sg", "org.sg", "edu.sg", "gov.sg", "per.sg",
        "com.my", "net.my", "org.my", "edu.my", "gov.my",
        "co.kr", "ne.kr", "or.kr", "re.kr", "pe.kr", "go.kr", "mil.kr", "ac.kr",
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br", "blog.br",
        "com.ru", "net.ru", "org.ru", "pp.ru", "msk.ru", "spb.ru",
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "edu.in", "gov.in",
        "com.tr", "net.tr", "org.tr", "edu.tr", "gov.tr", "av.tr", "bel.tr", "biz.tr",
        "com.mx", "net.mx", "org.mx", "edu.mx", "gob.mx",
        "com.ar", "net.ar", "org.ar", "edu.ar", "gob.ar",
        "co.za", "net.za", "org.za", "gov.za", "ac.za", "web.za",
        "com.ua", "net.ua", "org.ua", "gov.ua", "edu.ua", "in.ua",
        "com.pl", "net.pl", "org.pl", "gov.pl", "edu.pl", "info.pl", "biz.pl",
        "com.es", "net.es", "org.es", "nom.es", "gob.es", "edu.es",
        "co.il", "net.il", "org.il", "ac.il", "gov.il", "muni.il",
        "com.vn", "net.vn", "org.vn", "edu.vn", "gov.vn", "int.vn",
        "com.ph", "net.ph", "org.ph", "edu.ph", "gov.ph",
        "com.pk", "net.pk", "org.pk", "edu.pk", "gov.pk",
        "com.sa", "net.sa", "org.sa", "edu.sa", "gov.sa", "med.sa", "sch.sa",
        "com.eg", "net.eg", "org.eg", "edu.eg", "gov.eg",
        "co.id", "net.id", "or.id", "ac.id", "go.id", "web.id", "sch.id",
        "co.th", "in.th", "or.th", "ac.th", "go.th", "net.th",
        "com.ng", "net.ng", "org.ng", "edu.ng", "gov.ng",
        "com.co", "net.co", "org.co", "edu.co", "gov.co",
        "com.pe", "net.pe", "org.pe", "edu.pe", "gob.pe",
        "com.ve", "net.ve", "org.ve", "edu.ve", "gob.ve",
        "com.ec", "com.uy", "com.py", "com.bo", "com.do", "com.gt", "com.sv", "com.hn", "com.ni", "com.pa",
        "co.ke", "or.ke", "ne.ke", "go.ke", "ac.ke",
        "com.gh", "com.tn", "com.dz", "com.ma", "co.ma", "com.lb", "com.jo", "com.kw", "com.qa", "com.bh", "com.om",
        "co.at", "or.at", "ac.at", "gv.at", "co.no", "co.hu", "co.ro", "co.bg", "co.rs", "co.hr", "co.si", "co.sk",
        "com.gr", "com.cy", "com.mt", "com.pt", "com.lt", "com.lv", "com.ee", "com.by", "com.kz", "com.uz",
        "gov.cn", "com.taipei"
    ]

    static func effectiveTLDPlusOne(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host.lowercased() }
        // 尝试 3 段后缀（如 com.cn 已是 2 段，这里取最后两段判断）
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return parts.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6 简化判定
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let v = Int(part), v >= 0, v <= 255 else { return false }
            return true
        }
    }

    /// cookie 的存储键：可注册域名，IP 直接使用
    static func getSubDomain(_ url: String) -> String {
        guard let base = getBaseUrl(url), let host = URL(string: base)?.host, !host.isEmpty else {
            return url
        }
        if isIPAddress(host) { return host }
        return effectiveTLDPlusOne(host)
    }

    static func getSubDomainOrNil(_ url: String) -> String? {
        guard getBaseUrl(url) != nil else { return nil }
        return getSubDomain(url)
    }

    // MARK: - 编码判定

    private static let querySafe: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!$&()*+,-./:;=?@[]^_`{|}~")
    private static let formSafe: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")

    static func encodedQuery(_ str: String) -> Bool {
        isEncoded(str, safe: querySafe)
    }

    static func encodedForm(_ str: String) -> Bool {
        isEncoded(str, safe: formSafe)
    }

    private static func isEncoded(_ str: String, safe: Set<Character>) -> Bool {
        let chars = Array(str)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if safe.contains(c) { i += 1; continue }
            if c == "%", i + 2 < chars.count {
                let c1 = chars[i + 1], c2 = chars[i + 2]
                if c1.isHexDigit && c2.isHexDigit { i += 3; continue }
            }
            if c == " " && safe == formSafe { return false }
            return false
        }
        return true
    }
}

extension Character {
    var isHexDigit: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) } == true
    }
}
