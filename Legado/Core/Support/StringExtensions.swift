import Foundation
import SwiftSoup

// MARK: - 正则缓存

/// NSRegularExpression 缓存。书源规则会在解析循环里反复编译同一正则，
/// 上游用 `regexCache.getOrPutLimit` 做了限制缓存，这里保持一致（容量 16）。
final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private var cache: [String: NSRegularExpression?] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private let limit = 64

    func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let compiled = try? NSRegularExpression(pattern: pattern, options: options)

        lock.lock()
        if cache.count >= limit, let first = order.first {
            order.removeFirst()
            cache.removeValue(forKey: first)
        }
        cache[key] = compiled
        order.append(key)
        lock.unlock()
        return compiled
    }
}

// MARK: - 字符串基础

extension String {

    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last == " " || last == "\n" || last == "\r" || last == "\t" {
            s.removeLast()
        }
        return s
    }

    func take(_ count: Int) -> String {
        guard count > 0 else { return "" }
        if self.count <= count { return self }
        return String(prefix(count))
    }

    var utf16Count: Int { (self as NSString).length }

    func nsRange(_ range: NSRange) -> NSRange {
        NSRange(location: range.location, length: range.length)
    }

    /// 全匹配（对齐 Kotlin `String.matches(Regex)`)
    func matchesFully(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = RegexCache.shared.regex(pattern, options: options) else { return false }
        let full = NSRange(location: 0, length: (self as NSString).length)
        return regex.firstMatch(in: self, options: [], range: full).map {
            $0.range.location == 0 && $0.range.length == full.length
        } ?? false
    }

    func containsRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = RegexCache.shared.regex(pattern, options: options) else { return false }
        return regex.firstMatch(in: self, options: [], range: NSRange(location: 0, length: utf16Count)) != nil
    }

    func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> NSTextCheckingResult? {
        guard let regex = RegexCache.shared.regex(pattern, options: options) else { return nil }
        return regex.firstMatch(in: self, options: [], range: NSRange(location: 0, length: utf16Count))
    }

    /// 第一个匹配的所有捕获组（group0 为整体）
    func firstMatchGroups(_ pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let match = firstMatch(pattern, options: options) else { return nil }
        return (0..<match.numberOfRanges).map { idx in
            let r = match.range(at: idx)
            return r.location == NSNotFound ? "" : (self as NSString).substring(with: r)
        }
    }

    func allMatchGroups(_ pattern: String, options: NSRegularExpression.Options = []) -> [[String]] {
        guard let regex = RegexCache.shared.regex(pattern, options: options) else { return [] }
        let matches = regex.matches(in: self, options: [], range: NSRange(location: 0, length: utf16Count))
        return matches.map { match in
            (0..<match.numberOfRanges).map { idx in
                let r = match.range(at: idx)
                return r.location == NSNotFound ? "" : (self as NSString).substring(with: r)
            }
        }
    }

    func replacingRegex(_ pattern: String, with template: String,
                        options: NSRegularExpression.Options = []) -> String {
        guard let regex = RegexCache.shared.regex(pattern, options: options) else { return self }
        return regex.stringByReplacingMatches(
            in: self, options: [],
            range: NSRange(location: 0, length: utf16Count),
            withTemplate: template
        )
    }

    /// 对齐 Kotlin `splitNotBlank(Regex)`
    func splitNotBlank(_ pattern: String = "[\\s,;，；]+") -> [String] {
        guard let regex = RegexCache.shared.regex(pattern) else { return [self] }
        var result: [String] = []
        var lastEnd = 0
        let ns = self as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: self, options: [], range: full) {
            if match.range.location > lastEnd {
                let piece = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                if !piece.isBlank { result.append(piece) }
            }
            lastEnd = match.range.location + match.range.length
        }
        if lastEnd < ns.length {
            let piece = ns.substring(from: lastEnd)
            if !piece.isBlank { result.append(piece) }
        }
        return result
    }

    // MARK: JSON / XML 判定

    var isJSONText: Bool {
        let s = self.trimmed
        guard let first = s.first, first == "{" || first == "[" else { return false }
        guard let last = s.last, last == "}" || last == "]" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) != nil
    }

    var isJSONObjectText: Bool {
        let s = self.trimmed
        guard s.hasPrefix("{"), s.hasSuffix("}") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) is [String: Any]
    }

    var isJSONArrayText: Bool {
        let s = self.trimmed
        guard s.hasPrefix("["), s.hasSuffix("]") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) is [Any]
    }

    var isXMLText: Bool {
        let s = self.trimmed
        return s.hasPrefix("<?xml") || (s.hasPrefix("<") && s.hasSuffix(">") && !s.hasPrefix("<html"))
    }

    var isAbsURL: Bool {
        let s = lowercased()
        return s.hasPrefix("http://") || s.hasPrefix("https://")
    }

    var isDataURL: Bool { lowercased().hasPrefix("data:") }

    // MARK: HTML 实体

    /// 对齐 `StringEscapeUtils.unescapeHtml4` 的常见行为
    var unescapeHTML: String {
        guard contains("&") else { return self }
        if let decoded = try? Entities.unescape(self) {
            return decoded
        }
        return HTMLEntityDecoder.decode(self)
    }

    var escapedHTML: String {
        var s = self
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        return s
    }

    /// 用于 HTML 文本节点转义（不转义引号，与 jsoup text() 输出一致）
    var escapedHTMLText: String {
        var s = self
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        return s
    }
}

// MARK: - 兜底实体解码

enum HTMLEntityDecoder {
    private static let map: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "hellip": "…", "mdash": "—", "ndash": "–", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "middot": "·", "bull": "•", "copy": "©",
        "reg": "®", "trade": "™", "times": "×", "divide": "÷", "laquo": "«",
        "raquo": "»", "deg": "°", "plusmn": "±", "sup2": "²", "sup3": "³",
        "frac12": "½", "emsp": "\u{2003}", "ensp": "\u{2002}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}",
        "shy": "\u{00AD}", "sect": "§", "para": "¶", "dagger": "†", "Dagger": "‡",
        "permil": "‰", "lsaquo": "‹", "rsaquo": "›", "euro": "€", "pound": "£",
        "yen": "¥", "cent": "¢", "curren": "¤", "brvbar": "¦", "uml": "¨",
        "ordf": "ª", "ordm": "º", "not": "¬", "macr": "¯", "acute": "´",
        "micro": "µ", "cedil": "¸", "sup1": "¹", "iexcl": "¡", "iquest": "¿",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä",
        "aring": "å", "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é",
        "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î",
        "iuml": "ï", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô",
        "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù", "uacute": "ú",
        "ucirc": "û", "uuml": "ü", "yacute": "ý", "yuml": "ÿ", "szlig": "ß",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ", "omega": "ω",
        "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈",
        "radic": "√", "sum": "∑", "prod": "∏", "int": "∫", "part": "∂",
        "there4": "∴", "sim": "∼", "cong": "≅", "equiv": "≡", "sub": "⊂",
        "sup": "⊃", "nsub": "⊄", "sube": "⊆", "supe": "⊇", "oplus": "⊕",
        "otimes": "⊗", "perp": "⊥", "sdot": "⋅", "larr": "←", "uarr": "↑",
        "rarr": "→", "darr": "↓", "harr": "↔", "crarr": "↵", "lArr": "⇐",
        "uArr": "⇑", "rArr": "⇒", "dArr": "⇓", "hArr": "⇔", "forall": "∀",
        "exist": "∃", "empty": "∅", "nabla": "∇", "isin": "∈", "notin": "∉",
        "ni": "∋", "loz": "◊", "spades": "♠", "clubs": "♣", "hearts": "♥",
        "diams": "♦", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "lang": "〈", "rang": "〉", "lozge": "◊"
    ]

    static func decode(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var idx = input.startIndex

        while idx < input.endIndex {
            guard input[idx] == "&",
                  let semi = input[idx...].firstIndex(of: ";"),
                  input.distance(from: idx, to: semi) <= 32 else {
                result.append(input[idx])
                idx = input.index(after: idx)
                continue
            }

            let body = String(input[input.index(after: idx)..<semi])
            if body.hasPrefix("#") {
                let numPart = String(body.dropFirst())
                var scalar: UnicodeScalar?
                if numPart.hasPrefix("x") || numPart.hasPrefix("X") {
                    if let v = UInt32(numPart.dropFirst(), radix: 16) { scalar = UnicodeScalar(v) }
                } else if let v = UInt32(numPart) {
                    scalar = UnicodeScalar(v)
                }
                if let scalar {
                    result.append(Character(scalar))
                    idx = input.index(after: semi)
                    continue
                }
            } else if let decoded = map[body] {
                result.append(decoded)
                idx = input.index(after: semi)
                continue
            }

            result.append(input[idx])
            idx = input.index(after: idx)
        }
        return result
    }
}
