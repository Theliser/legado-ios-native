import Foundation
import SwiftSoup

/// 正文/简介净化，逐条对齐上游 `HtmlFormatter` 的管线顺序。
enum HtmlFormatter {

    private static let nbspRegex = "(&nbsp;)+"
    private static let espRegex = "(&ensp;|&emsp;)"
    private static let noPrintRegex = "(&thinsp;|&zwnj;|&zwj;|\u{2009}|\u{200C}|\u{200D})"
    private static let wrapHtmlRegex = "</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>"
    private static let commentRegex = "<!--[^>]*-->"
    private static let notImgHtmlRegex = "</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>"
    private static let otherHtmlRegex = "</?[a-zA-Z]+(?=[ >])[^<>]*>"

    private static let indent1Regex = "\\s*\\n+\\s*"
    private static let indent2Regex = "^[\\n\\s]+"
    private static let lastRegex = "[\\n\\s]+$"
    private static let paragraphIndent = "　　"

    private static let formatImagePattern =
        "<img[^>]*\\ssrc\\s*=\\s*['\"]([^'\"{>]*\\{(?:[^{}]|\\{[^}>]+\\})+\\})['\"][^>]*>"
        + "|<img[^>]*\\s(?:data-src|src)\\s*=\\s*['\"]([^'\">]+)['\"][^>]*>"
        + "|<img[^>]*\\sdata-[^=>]*=\\s*['\"]([^'\">]*)['\"][^>]*>"

    /// 简介（纯文本）
    static func format(_ html: String?) -> String {
        format(html, otherRegex: otherHtmlRegex, paragraphIndent: paragraphIndent)
    }

    private static func format(_ html: String?, otherRegex: String, paragraphIndent: String) -> String {
        guard var s = html else { return "" }
        s = s.replacingRegex(nbspRegex, with: " ")
        s = s.replacingRegex(espRegex, with: " ")
        s = s.replacingRegex(noPrintRegex, with: "")
        s = s.replacingRegex(wrapHtmlRegex, with: "\n")
        s = s.replacingRegex(commentRegex, with: "")
        s = s.replacingRegex(otherRegex, with: "")
        s = s.replacingRegex(indent1Regex, with: "\n\(paragraphIndent)")
        s = s.replacingRegex(indent2Regex, with: paragraphIndent)
        s = s.replacingRegex(lastRegex, with: "")
        return s
    }

    /// 正文（保留 img，并把相对地址转绝对地址）
    static func formatKeepImg(_ html: String?, redirectUrl: URL?) -> String {
        guard let html else { return "" }
        let keepImgHtml = format(html, otherRegex: notImgHtmlRegex, paragraphIndent: paragraphIndent)

        var result = ""
        var appendPos = 0
        let ns = keepImgHtml as NSString
        guard let regex = RegexCache.shared.regex(formatImagePattern, options: [.caseInsensitive]) else {
            return keepImgHtml
        }
        let matches = regex.matches(in: keepImgHtml, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            var param = ""
            let group1 = m.range(at: 1).location == NSNotFound ? nil : ns.substring(with: m.range(at: 1))
            var src = group1
            if let g1 = group1 {
                if let pm = g1.firstMatch("\\s*,\\s*(?=\\{)") {
                    let idx = pm.range.location
                    param = "," + String(g1.dropFirst(idx))
                    src = String(g1.prefix(idx))
                }
            }
            if src == nil {
                if m.range(at: 2).location != NSNotFound {
                    src = ns.substring(with: m.range(at: 2))
                } else if m.range(at: 3).location != NSNotFound {
                    src = ns.substring(with: m.range(at: 3))
                }
            }
            let absolute = NetworkUtils.getAbsoluteURL(redirectUrl?.absoluteString, src ?? "")
            result += ns.substring(with: NSRange(location: appendPos, length: m.range.location - appendPos))
            result += "<img src=\"\(absolute)\(param)\">"
            appendPos = m.range.location + m.range.length
        }
        if appendPos < ns.length {
            result += ns.substring(from: appendPos)
        }
        return result
    }

    /// 介绍/简介的只读展示文本
    static func formatDisplayText(_ html: String?) -> String {
        guard let html, !html.isBlank else { return "" }
        guard let document = try? SwiftSoup.parseBodyFragment(html) else { return format(html) }
        document.outputSettings().prettyPrint(pretty: false)
        _ = try? document.select("script, style, noscript").remove()
        let bodyHtml = (try? document.body()?.html()) ?? html
        let text = format(bodyHtml, otherRegex: otherHtmlRegex, paragraphIndent: "")
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\u{00a0}\u{2002}\u{2003}\u{2009}\u{3000}")) }
            .filter { !$0.isEmpty }
            .map { line -> String in
                let stripped = line.replacingRegex("^(?:[【\\[(（](?:内容简介|作品简介|小说简介|内容介绍|简介|文案|摘要)[】\\])）]|(?:内容简介|作品简介|小说简介|内容介绍|简介|文案|摘要)\\s*[：:])\\s*", with: "")
                return paragraphIndent + stripped.trimmingCharacters(in: .whitespaces)
            }
        return lines.joined(separator: "\n").unescapeHTML
    }
}
