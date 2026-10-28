import Foundation

/// JSON 解析与访问工具。
/// 上游先用 GSONStrict（严格）解析，失败再用 GSON（宽松）兜底，这里复刻同样的策略。
enum JSONTool {

    static func parse(_ text: String?) -> Any? {
        guard let text, !text.isBlank else { return nil }
        if let strict = strictParse(text) { return strict }
        if let lenient = lenientParse(text) { return lenient }
        return nil
    }

    static func parseObject(_ text: String?) -> [String: Any]? {
        // 书源里有些字段被写成 JSON 字符串（"{...}" 外层还有引号）
        var t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = t, s.hasPrefix("\""), s.hasSuffix("\"") {
            t = String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if let obj = parse(t) as? [String: Any] { return obj }
        return nil
    }

    static func parseArray(_ text: String?) -> [Any]? {
        var t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = t, s.hasPrefix("\""), s.hasSuffix("\"") {
            t = String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if let arr = parse(t) as? [Any] { return arr }
        return nil
    }

    static func strictParse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func lenientParse(_ text: String) -> Any? {
        let fixed = lenientize(text)
        guard let data = fixed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 修正常见的非规范 JSON：单引号、未加引号的 key / value、尾逗号、注释。
    /// GSON 的宽松模式连「值不加引号」都接受（`@put:{name:.title@text}` 就靠这个），
    /// 所以这里也要补上值的处理。
    static func lenientize(_ text: String) -> String {
        var s = text
        s = s.replacingRegex("(?s)/\\*.*?\\*/", with: "")
        s = s.replacingRegex("(?m)^\\s*//.*$", with: "")
        s = s.replacingRegex(",\\s*([}\\]])", with: "$1")

        var out = ""
        var inString = false
        var quoteChar: Character = "\""
        var escaped = false
        var prevNonSpace: Character?

        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                    out.append(c)
                } else if c == "\\" {
                    escaped = true
                    out.append(c)
                } else if c == quoteChar {
                    inString = false
                    out.append("\"")
                } else {
                    out.append(c)
                }
                i += 1
                continue
            }

            if c == "'" || c == "\"" {
                inString = true
                quoteChar = c
                out.append("\"")
                i += 1
                continue
            }

            if c == ":" {
                out.append(c)
                prevNonSpace = c
                i += 1

                // 跳过空白后检查值。不是结构/字面量/引号时按未加引号的字符串处理。
                var j = i
                while j < chars.count, chars[j] == " " || chars[j] == "\t"
                    || chars[j] == "\n" || chars[j] == "\r" {
                    out.append(chars[j])
                    j += 1
                }
                guard j < chars.count else { i = j; continue }
                let first = chars[j]
                let looksStructured = first == "{" || first == "["
                let looksQuoted = first == "\"" || first == "'"
                let prefix = String(chars[j...min(j + 4, chars.count - 1)])
                let looksLiteral = prefix.hasPrefix("true") || prefix.hasPrefix("false")
                    || prefix.hasPrefix("null")
                let looksNumber = first == "-" || first.isNumber
                if looksStructured || looksQuoted || looksLiteral || looksNumber {
                    i = j
                    continue
                }

                // 读到当前层级的分隔符（`,` 或对象结束的 `}`）为止
                var depth = 0
                var value = ""
                var k = j
                while k < chars.count {
                    let vc = chars[k]
                    if vc == "{" || vc == "[" {
                        depth += 1
                    } else if vc == "}" || vc == "]" {
                        if depth == 0 { break }
                        depth -= 1
                    } else if vc == "," && depth == 0 {
                        break
                    }
                    value.append(vc)
                    k += 1
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let escapedValue = trimmed
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                out.append("\"\(escapedValue)\"")
                i = k
                continue
            }

            if c == "{", i + 1 < chars.count {
                out.append(c)
                prevNonSpace = c
                i += 1
                continue
            }

            // 未加引号的 key
            if (c.isLetter || c == "_" || c == "$"), prevNonSpace == "{" || prevNonSpace == "," {
                var j = i
                var key = ""
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "-" || chars[j] == "$" {
                    key.append(chars[j])
                    j += 1
                }
                var k = j
                while k < chars.count, chars[k] == " " || chars[k] == "\t" || chars[k] == "\n" {
                    k += 1
                }
                if k < chars.count, chars[k] == ":" {
                    out.append("\"\(key)\"")
                    i = j
                    continue
                }
            }

            if !c.isWhitespace { prevNonSpace = c }
            out.append(c)
            i += 1
        }
        return out
    }

    static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(value)"
    }

    static func stringifyPretty(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}

// MARK: - 便于 JS 桥/规则引擎取值

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        if let s = v as? String { return s }
        if let d = v as? Double, d.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", d)
        }
        if let n = v as? NSNumber { return n.stringValue }
        return JSONTool.stringify(v)
    }
}
