import Foundation

/// 轻量 JSONPath 引擎，覆盖书源里实际会用到的 jayway 语法：
/// `$` 根、`.key`、`['key']`、`[0]`、`[-1]`、`[*]`、`..key`（递归）、切片 `[a:b:c]`、
/// 并集 `[0,2]` / `['a','b']`、过滤 `[?(@.x == 'y' && @.n > 3)]`、`length()` 等函数。
enum JSONPath {

    enum Step {
        case child(String)
        case recursiveChild(String)
        case wildcard
        case recursiveWildcard
        case index(Int)
        case slice(start: Int?, end: Int?, step: Int?)
        case unionIndexes([Int])
        case unionNames([String])
        case filter(Filter)
        case function(String)
        case recursiveFilter(Filter)
    }

    enum Filter {
        case exists(String)
        case notExists(String)
        case comparison(String, String, Literal)
        case regex(String, String)
        case and(Filter, Filter)
        case or(Filter, Filter)
        case not(Filter)
        case literalTruthy
    }

    enum Literal {
        case number(Double)
        case string(String)
        case bool(Bool)
        case null

        var value: Any {
            switch self {
            case .number(let d): return d
            case .string(let s): return s
            case .bool(let b): return b
            case .null: return NSNull()
            }
        }
    }

    // MARK: - 入口

    static func evaluate(_ path: String, on root: Any) throws -> [Any] {
        let normalized = normalize(path)
        let steps = try parse(normalized)
        var current: [Any] = [root]
        for step in steps {
            current = apply(step, to: current)
        }
        return current
    }

    private static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.hasPrefix("$") {
            p = p.hasPrefix("[") || p.hasPrefix(".") ? "$" + p : "$." + p
        }
        return p
    }

    // MARK: - 解析

    private static func parse(_ path: String) throws -> [Step] {
        var steps: [Step] = []
        let chars = Array(path)
        var i = 0
        guard chars.first == "$" else { throw JSONPathError.invalidPath }
        i = 1

        while i < chars.count {
            let c = chars[i]
            if c == "." {
                if i + 1 < chars.count && chars[i + 1] == "." {
                    // 递归下降
                    i += 2
                    if i < chars.count && chars[i] == "*" {
                        steps.append(.recursiveWildcard)
                        i += 1
                    } else if i < chars.count && chars[i] == "[" {
                        // ..[?()] 之类交给下一步处理
                        continue
                    } else {
                        var name = ""
                        while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "-") {
                            name.append(chars[i]); i += 1
                        }
                        steps.append(name.isEmpty ? .recursiveWildcard : .recursiveChild(name))
                    }
                    continue
                }
                i += 1
                var name = ""
                while i < chars.count && chars[i] != "." && chars[i] != "[" {
                    name.append(chars[i]); i += 1
                }
                if name.hasSuffix("()") {
                    steps.append(.function(String(name.dropLast(2))))
                } else if !name.isEmpty {
                    steps.append(.child(name))
                }
                continue
            }

            if c == "[" {
                let (step, next) = try parseBracket(chars, i)
                steps.append(step)
                i = next
                continue
            }

            // 未知字符，跳过
            i += 1
        }
        return steps
    }

    private static func parseBracket(_ chars: [Character], _ start: Int) throws -> (Step, Int) {
        var i = start + 1
        guard i < chars.count else { throw JSONPathError.invalidPath }
        let head = chars[i]

        if head == "*" {
            i += 1
            while i < chars.count && chars[i] != "]" { i += 1 }
            return (.wildcard, i + 1)
        }

        if head == "?" {
            i += 1
            var expr = ""
            var depth = 0
            var inString: Character?
            while i < chars.count {
                let c = chars[i]
                if let q = inString {
                    expr.append(c)
                    if c == q { inString = nil }
                } else if c == "'" || c == "\"" {
                    inString = c; expr.append(c)
                } else if c == "(" || c == "[" {
                    depth += 1; expr.append(c)
                } else if c == ")" || c == "]" {
                    if depth == 0 && c == "]" { break }
                    depth -= 1; expr.append(c)
                } else {
                    expr.append(c)
                }
                i += 1
            }
            // 去掉外层括号
            var body = expr.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("(") && body.hasSuffix(")") {
                body = String(body.dropFirst().dropLast())
            }
            let filter = FilterParser(body).parse()
            return (.filter(filter), i + 1)
        }

        // 收集到匹配的 ']'
        var content = ""
        var inString: Character?
        while i < chars.count {
            let c = chars[i]
            if let q = inString {
                content.append(c)
                if c == q { inString = nil }
            } else if c == "'" || c == "\"" {
                inString = c; content.append(c)
            } else if c == "]" {
                break
            } else {
                content.append(c)
            }
            i += 1
        }
        let next = i + 1
        let text = content.trimmingCharacters(in: .whitespaces)

        // 并集：含逗号且不在引号内
        if text.contains(",") && !text.hasPrefix("'") && !text.hasPrefix("\"") {
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.allSatisfy({ Int($0) != nil }) {
                return (.unionIndexes(parts.compactMap { Int($0) }), next)
            }
            if parts.allSatisfy({ $0.hasPrefix("'") || $0.hasPrefix("\"") }) {
                return (.unionNames(parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }), next)
            }
        }
        if text.contains(",") && (text.hasPrefix("'") || text.hasPrefix("\"")) {
            let parts = text.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            if parts.count > 1 { return (.unionNames(parts), next) }
        }

        if (text.hasPrefix("'") && text.hasSuffix("'")) || (text.hasPrefix("\"") && text.hasSuffix("\"")) {
            return (.child(String(text.dropFirst().dropLast())), next)
        }

        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            let startVal = parts.count > 0 ? Int(parts[0].trimmingCharacters(in: .whitespaces)) : nil
            let endVal = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            let stepVal = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespaces)) : nil
            return (.slice(start: startVal, end: endVal, step: stepVal), next)
        }

        if let index = Int(text) {
            return (.index(index), next)
        }
        // `[(@.length-1)]` 等复杂语法暂不支持，按字段名兜底
        return (.child(text), next)
    }

    // MARK: - 求值

    private static func apply(_ step: Step, to nodes: [Any]) -> [Any] {
        switch step {
        case .child(let name):
            var out: [Any] = []
            for node in nodes {
                if let dict = node as? [String: Any], let value = dict[name] {
                    out.append(value)
                }
            }
            return out

        case .recursiveChild(let name):
            var out: [Any] = []
            for node in nodes {
                collectRecursive(node) { dict in
                    if let value = dict[name] { out.append(value) }
                }
            }
            return out

        case .wildcard:
            var out: [Any] = []
            for node in nodes {
                if let dict = node as? [String: Any] { out.append(contentsOf: dict.values) }
                else if let array = node as? [Any] { out.append(contentsOf: array) }
            }
            return out

        case .recursiveWildcard:
            var out: [Any] = []
            for node in nodes {
                collectAll(node) { out.append($0) }
            }
            return out

        case .index(let index):
            var out: [Any] = []
            for node in nodes {
                if let array = node as? [Any] {
                    let real = index < 0 ? array.count + index : index
                    if real >= 0 && real < array.count { out.append(array[real]) }
                }
            }
            return out

        case .slice(let start, let end, let step):
            var out: [Any] = []
            for node in nodes {
                guard let array = node as? [Any] else { continue }
                let count = array.count
                var s = start ?? 0
                var e = end ?? count
                if s < 0 { s += count }
                if e < 0 { e += count }
                s = max(0, min(s, count))
                e = max(0, min(e, count))
                let stride = step ?? 1
                if stride > 0 {
                    var i = s
                    while i < e { out.append(array[i]); i += stride }
                } else if stride < 0 {
                    var i = min(e, count - 1)
                    while i > s - 1 && i >= 0 { out.append(array[i]); i += stride }
                }
            }
            return out

        case .unionIndexes(let indexes):
            var out: [Any] = []
            for node in nodes {
                guard let array = node as? [Any] else { continue }
                for index in indexes {
                    let real = index < 0 ? array.count + index : index
                    if real >= 0 && real < array.count { out.append(array[real]) }
                }
            }
            return out

        case .unionNames(let names):
            var out: [Any] = []
            for node in nodes {
                guard let dict = node as? [String: Any] else { continue }
                for name in names {
                    if let value = dict[name] { out.append(value) }
                }
            }
            return out

        case .filter(let filter):
            var out: [Any] = []
            for node in nodes {
                if let array = node as? [Any] {
                    out.append(contentsOf: array.filter { filterMatch(filter, $0) })
                } else if let dict = node as? [String: Any] {
                    if filterMatch(filter, dict) { out.append(dict) }
                }
            }
            return out

        case .recursiveFilter(let filter):
            var out: [Any] = []
            for node in nodes {
                collectAll(node) { item in
                    if filterMatch(filter, item) { out.append(item) }
                }
            }
            return out

        case .function(let name):
            return nodes.map { applyFunction(name, $0) ?? $0 }
        }
    }

    private static func applyFunction(_ name: String, _ node: Any) -> Any? {
        switch name.lowercased() {
        case "length", "size":
            if let array = node as? [Any] { return array.count }
            if let dict = node as? [String: Any] { return dict.count }
            if let s = node as? String { return s.count }
            return nil
        case "keys", "keyset":
            if let dict = node as? [String: Any] { return Array(dict.keys) }
            return nil
        case "min":
            if let array = node as? [Any] { return array.compactMap { doubleValue($0) }.min() }
            return nil
        case "max":
            if let array = node as? [Any] { return array.compactMap { doubleValue($0) }.max() }
            return nil
        case "sum":
            if let array = node as? [Any] { return array.compactMap { doubleValue($0) }.reduce(0, +) }
            return nil
        case "avg":
            if let array = node as? [Any] {
                let values = array.compactMap { doubleValue($0) }
                return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            }
            return nil
        case "first":
            if let array = node as? [Any] { return array.first }
            return nil
        case "last":
            if let array = node as? [Any] { return array.last }
            return nil
        default:
            return nil
        }
    }

    private static func collectAll(_ node: Any, _ visit: (Any) -> Void) {
        if let dict = node as? [String: Any] {
            for (_, value) in dict {
                visit(value)
                collectAll(value, visit)
            }
        } else if let array = node as? [Any] {
            for value in array {
                visit(value)
                collectAll(value, visit)
            }
        }
    }

    private static func collectRecursive(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let dict = node as? [String: Any] {
            visit(dict)
            for (_, value) in dict { collectRecursive(value, visit) }
        } else if let array = node as? [Any] {
            for value in array { collectRecursive(value, visit) }
        }
    }

    // MARK: - 过滤求值

    private static func filterMatch(_ filter: Filter, _ item: Any) -> Bool {
        switch filter {
        case .exists(let path):
            return resolve(path, in: item) != nil
        case .notExists(let path):
            return resolve(path, in: item) == nil
        case .comparison(let path, let op, let literal):
            guard let value = resolve(path, in: item) else { return false }
            return compare(value, op, literal.value)
        case .regex(let path, let pattern):
            guard let value = resolve(path, in: item) else { return false }
            return "\(value)".containsRegex(pattern)
        case .and(let a, let b):
            return filterMatch(a, item) && filterMatch(b, item)
        case .or(let a, let b):
            return filterMatch(a, item) || filterMatch(b, item)
        case .not(let a):
            return !filterMatch(a, item)
        case .literalTruthy:
            return true
        }
    }

    private static func resolve(_ path: String, in item: Any) -> Any? {
        var current: Any? = item
        var rest = path
        if rest.hasPrefix("@") { rest = String(rest.dropFirst()) }
        if rest.hasPrefix(".") { rest = String(rest.dropFirst()) }
        if rest.isEmpty { return item }
        for part in rest.split(separator: ".") {
            let key = String(part)
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else if let array = current as? [Any], let index = Int(key) {
                current = (index >= 0 && index < array.count) ? array[index] : nil
            } else {
                return nil
            }
            if current == nil { return nil }
        }
        return current
    }

    private static func compare(_ lhs: Any, _ op: String, _ rhs: Any) -> Bool {
        switch op {
        case "==", "===":
            if let a = doubleValue(lhs), let b = doubleValue(rhs) { return a == b }
            return "\(lhs)" == "\(rhs)"
        case "!=", "!==":
            if let a = doubleValue(lhs), let b = doubleValue(rhs) { return a != b }
            return "\(lhs)" != "\(rhs)"
        case "<":
            if let a = doubleValue(lhs), let b = doubleValue(rhs) { return a < b }
            return "\(lhs)" < "\(rhs)"
        case "<=":
            if let a = doubleValue(lhs), let b = doubleValue(rhs) { return a <= b }
            return "\(lhs)" <= "\(rhs)"
        case ">":
            if let a = doubleValue(lhs), let b = doubleValue(rhs) { return a > b }
            return "\(lhs)" > "\(rhs)"
        case ">=":
            if let a = doubleValue(lhs), let b = doubleValue(rhs) { return a >= b }
            return "\(lhs)" >= "\(rhs)"
        default:
            return false
        }
    }

    static func doubleValue(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

enum JSONPathError: Error {
    case invalidPath
}

// MARK: - 过滤表达式解析

private final class FilterParser {
    private let chars: [Character]
    private var pos = 0

    init(_ text: String) {
        self.chars = Array(text)
    }

    func parse() -> JSONPath.Filter {
        let expr = parseOr()
        return expr
    }

    private func skipSpaces() {
        while pos < chars.count && chars[pos] == " " { pos += 1 }
    }

    private func parseOr() -> JSONPath.Filter {
        var left = parseAnd()
        while true {
            skipSpaces()
            if matches("||") {
                pos += 2
                let right = parseAnd()
                left = .or(left, right)
            } else {
                return left
            }
        }
    }

    private func parseAnd() -> JSONPath.Filter {
        var left = parseUnary()
        while true {
            skipSpaces()
            if matches("&&") {
                pos += 2
                let right = parseUnary()
                left = .and(left, right)
            } else {
                return left
            }
        }
    }

    private func parseUnary() -> JSONPath.Filter {
        skipSpaces()
        if matches("!") && !matches("!=") {
            pos += 1
            return .not(parseUnary())
        }
        return parsePrimary()
    }

    private func parsePrimary() -> JSONPath.Filter {
        skipSpaces()
        if matches("(") {
            pos += 1
            let inner = parseOr()
            skipSpaces()
            if matches(")") { pos += 1 }
            return inner
        }

        guard let path = readPath() else { return .literalTruthy }
        skipSpaces()

        if matches("=~") {
            pos += 2
            skipSpaces()
            var pattern = ""
            if pos < chars.count && chars[pos] == "/" {
                pos += 1
                while pos < chars.count && chars[pos] != "/" {
                    pattern.append(chars[pos]); pos += 1
                }
                if pos < chars.count { pos += 1 }
            } else {
                pattern = readLiteralString()
            }
            return .regex(path, pattern)
        }

        for op in ["==", "!=", "<=", ">=", "<", ">"] {
            if matches(op) {
                pos += op.count
                skipSpaces()
                let literal = readLiteral()
                return .comparison(path, op, literal)
            }
        }

        return .exists(path)
    }

    private func readPath() -> String? {
        skipSpaces()
        guard pos < chars.count, chars[pos] == "@" else { return nil }
        var path = ""
        pos += 1
        while pos < chars.count {
            let c = chars[pos]
            if c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" {
                path.append(c); pos += 1
            } else {
                break
            }
        }
        return path.isEmpty ? "@" : path
    }

    private func readLiteralString() -> String {
        skipSpaces()
        guard pos < chars.count else { return "" }
        let quote = chars[pos]
        guard quote == "'" || quote == "\"" else {
            var s = ""
            while pos < chars.count && chars[pos] != ")" && chars[pos] != " " && chars[pos] != "]" {
                s.append(chars[pos]); pos += 1
            }
            return s
        }
        pos += 1
        var s = ""
        while pos < chars.count && chars[pos] != quote {
            s.append(chars[pos]); pos += 1
        }
        if pos < chars.count { pos += 1 }
        return s
    }

    private func readLiteral() -> JSONPath.Literal {
        skipSpaces()
        var raw = ""
        if pos < chars.count, chars[pos] == "'" || chars[pos] == "\"" {
            return .string(readLiteralString())
        }
        while pos < chars.count {
            let c = chars[pos]
            if c == " " || c == ")" || c == "&" || c == "|" || c == "]" { break }
            raw.append(c)
            pos += 1
        }
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw == "null" { return .null }
        if let d = Double(raw) { return .number(d) }
        return .string(raw)
    }

    private func matches(_ prefix: String) -> Bool {
        let p = Array(prefix)
        guard pos + p.count <= chars.count else { return false }
        for i in 0..<p.count where chars[pos + i] != p[i] { return false }
        return true
    }
}
