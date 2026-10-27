import Foundation
import SwiftSoup

/// CSS 规则解析，移植自上游 `AnalyzeByJSoup`（jsoup → SwiftSoup）。
///
/// 支持书源的扩展语法：
/// - `@CSS:` 显式 CSS 模式
/// - `tag.div.-1`（旧式索引）、`tag.div[0:3:2]`（区间/步长/负索引/`!` 排除）
/// - `@text` `@ownText` `@textNodes` `@html` `@all` 以及任意属性名
/// - `&&` 并集、`||` 短路、`%%` 交叉
final class AnalyzeByJSoup {

    private let element: Element

    init(_ doc: Any) {
        self.element = Self.parse(doc)
    }

    private static func parse(_ doc: Any) -> Element {
        if let element = doc as? Element { return element }
        if let document = doc as? Document {
            return document.body() ?? document
        }
        if let node = doc as? XPathNode {
            if node.isElement, let parsed = try? SwiftSoup.parse(node.outerHtml) {
                return parsed.body() ?? parsed
            }
            return parse(node.outerHtml)
        }
        let text = "\(doc)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<?xml") {
            if let doc = try? SwiftSoup.parse(text, "", Parser.xmlParser()) {
                return doc
            }
        }
        if let doc = try? SwiftSoup.parse(text) {
            return doc
        }
        return Element(Tag("body"), "")
    }

    // MARK: - 对外

    func getElements(_ rule: String) -> [Element] {
        getElements(element, rule)
    }

    /// 合并内容列表
    func getString(_ ruleStr: String) -> String? {
        guard !ruleStr.isEmpty else { return nil }
        let list = getStringList(ruleStr)
        if list.isEmpty { return nil }
        if list.count == 1 { return list.first }
        return list.joined(separator: "\n")
    }

    func getString0(_ ruleStr: String) -> String {
        getStringList(ruleStr).first ?? ""
    }

    func getStringList(_ ruleStr: String) -> [String] {
        var result: [String] = []
        guard !ruleStr.isEmpty else { return result }

        let sourceRule = SourceRule(ruleStr)
        if sourceRule.elementsRule.isEmpty {
            result.append((try? element.data()) ?? "")
            return result
        }

        let analyzer = RuleAnalyzer(sourceRule.elementsRule)
        let ruleParts = analyzer.splitRule("&&", "||", "%%")
        var results: [[String]] = []

        for part in ruleParts {
            var temp: [String] = []
            if sourceRule.isCss {
                let lastIndex = part.lastIndex(of: "@")
                if let lastIndex {
                    let selector = String(part[part.startIndex..<lastIndex])
                    let lastRule = String(part[part.index(after: lastIndex)...])
                    let elements = (try? element.select(selector))?.array() ?? []
                    temp = getResultLast(elements, lastRule)
                } else {
                    let elements = (try? element.select(part))?.array() ?? []
                    temp = elements.map { (try? $0.text()) ?? "" }.filter { !$0.isEmpty }
                }
            } else {
                temp = getResultList(part) ?? []
            }
            if !temp.isEmpty {
                results.append(temp)
                if analyzer.elementsType == "||" { break }
            }
        }

        if !results.isEmpty {
            if analyzer.elementsType == "%%" {
                let firstCount = results[0].count
                for i in 0..<firstCount {
                    for temp in results where i < temp.count {
                        result.append(temp[i])
                    }
                }
            } else {
                for temp in results { result.append(contentsOf: temp) }
            }
        }
        return result
    }

    // MARK: - Elements

    private func getElements(_ temp: Element?, _ rule: String) -> [Element] {
        guard let temp, !rule.isEmpty else { return [] }

        let sourceRule = SourceRule(rule)
        let analyzer = RuleAnalyzer(sourceRule.elementsRule)
        let ruleParts = analyzer.splitRule("&&", "||", "%%")
        var lists: [[Element]] = []

        if sourceRule.isCss {
            for part in ruleParts {
                let selected = (try? temp.select(part))?.array() ?? []
                lists.append(selected)
                if !selected.isEmpty && analyzer.elementsType == "||" { break }
            }
        } else {
            for part in ruleParts {
                let rsRule = RuleAnalyzer(part)
                rsRule.trim()
                let subRules = rsRule.splitRule("@")

                var current: [Element]
                if subRules.count > 1 {
                    current = [temp]
                    for sub in subRules {
                        var next: [Element] = []
                        for el in current {
                            next.append(contentsOf: getElements(el, sub))
                        }
                        current = next
                    }
                } else {
                    current = ElementsSingle().getElementsSingle(temp, part)
                }
                lists.append(current)
                if !current.isEmpty && analyzer.elementsType == "||" { break }
            }
        }

        var elements: [Element] = []
        if !lists.isEmpty {
            if analyzer.elementsType == "%%" {
                for i in 0..<lists[0].count {
                    for list in lists where i < list.count {
                        elements.append(list[i])
                    }
                }
            } else {
                for list in lists { elements.append(contentsOf: list) }
            }
        }
        return elements
    }

    private func getResultList(_ ruleStr: String) -> [String]? {
        guard !ruleStr.isEmpty else { return nil }

        var elements: [Element] = [element]
        let analyzer = RuleAnalyzer(ruleStr)
        analyzer.trim()
        let rules = analyzer.splitRule("@")
        guard !rules.isEmpty else { return nil }

        let last = rules.count - 1
        if last > 0 {
            for i in 0..<last {
                var next: [Element] = []
                for el in elements {
                    next.append(contentsOf: ElementsSingle().getElementsSingle(el, rules[i]))
                }
                elements = next
            }
        }
        if elements.isEmpty { return nil }
        return getResultLast(elements, rules[last])
    }

    private func getResultLast(_ elements: [Element], _ lastRule: String) -> [String] {
        var result: [String] = []
        switch lastRule {
        case "text":
            for element in elements {
                let text = (try? element.text()) ?? ""
                if !text.isEmpty { result.append(text) }
            }
        case "textNodes":
            for element in elements {
                var items: [String] = []
                for node in element.textNodes() {
                    let text = (node.text() ?? "").trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { items.append(text) }
                }
                if !items.isEmpty { result.append(items.joined(separator: "\n")) }
            }
        case "ownText":
            for element in elements {
                let text = (try? element.ownText()) ?? ""
                if !text.isEmpty { result.append(text) }
            }
        case "html":
            let html = elements.map { (try? $0.outerHtml()) ?? "" }.joined()
                .replacingRegex("(?is)<script\\b[^>]*>.*?</script>", with: "")
                .replacingRegex("(?is)<style\\b[^>]*>.*?</style>", with: "")
            if !html.isEmpty { result.append(html) }
        case "all":
            result.append(elements.map { (try? $0.outerHtml()) ?? "" }.joined())
        default:
            for element in elements {
                let value = (try? element.attr(lastRule)) ?? ""
                if value.isBlank || result.contains(value) { continue }
                result.append(value)
            }
        }
        return result
    }

    // MARK: - 规则对象

    private struct SourceRule {
        var isCss = false
        var elementsRule: String

        init(_ ruleStr: String) {
            if ruleStr.lowercased().hasPrefix("@css:") {
                isCss = true
                elementsRule = String(ruleStr.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else {
                elementsRule = ruleStr
            }
        }
    }

    // MARK: - 索引语法

    /// 上游 `ElementsSingle`：处理 `tag.div.-1`、`tag.div[0:3]`、`tag.div!0` 等索引写法
    final class ElementsSingle {
        var split: Character = "."
        var beforeRule: String = ""
        var indexDefault: [Int] = []
        var indexes: [Any] = [] // Int 或 (Int?, Int?, Int)

        func getElementsSingle(_ temp: Element, _ rule: String) -> [Element] {
            findIndexSet(rule)

            var elements: [Element]
            if beforeRule.isEmpty {
                elements = temp.children().array()
            } else {
                let parts = beforeRule.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                switch parts[0] {
                case "children":
                    elements = temp.children().array()
                case "class":
                    elements = parts.count > 1 ? ((try? temp.getElementsByClass(parts[1]))?.array() ?? []) : []
                case "tag":
                    elements = parts.count > 1 ? ((try? temp.getElementsByTag(parts[1]))?.array() ?? []) : []
                case "id":
                    let target = parts.count > 1 ? parts[1] : ""
                    elements = Self.descendants(temp).filter { (try? $0.attr("id")) == target }
                case "text":
                    let target = parts.count > 1 ? parts[1] : ""
                    elements = Self.descendants(temp).filter {
                        ((try? $0.ownText()) ?? "").contains(target)
                    }
                default:
                    elements = (try? temp.select(beforeRule))?.array() ?? []
                }
            }

            let count = elements.count
            let lastIndex = indexDefault.isEmpty ? indexes.count - 1 : indexDefault.count - 1
            guard lastIndex >= 0 else { return elements }

            var indexList: [Int] = []
            var seen = Set<Int>()

            if indexes.isEmpty {
                var ix = lastIndex
                while ix >= 0 {
                    let value = indexDefault[ix]
                    if value >= 0 && value < count {
                        if seen.insert(value).inserted { indexList.append(value) }
                    } else if value < 0 && count >= -value {
                        let real = value + count
                        if seen.insert(real).inserted { indexList.append(real) }
                    }
                    ix -= 1
                }
            } else {
                var ix = lastIndex
                while ix >= 0 {
                    if let triple = indexes[ix] as? IndexRange {
                        var start = triple.start ?? 0
                        if start < 0 { start += count }
                        var end = triple.end ?? (count - 1)
                        if end < 0 { end += count }

                        if (start < 0 && end < 0) || (start >= count && end >= count) {
                            ix -= 1
                            continue
                        }
                        if start >= count { start = count - 1 } else if start < 0 { start = 0 }
                        if end >= count { end = count - 1 } else if end < 0 { end = 0 }

                        if start == end || triple.step >= count {
                            if seen.insert(start).inserted { indexList.append(start) }
                            ix -= 1
                            continue
                        }

                        let step: Int
                        if triple.step > 0 {
                            step = triple.step
                        } else if -triple.step < count {
                            step = triple.step + count
                        } else {
                            step = 1
                        }

                        if end > start {
                            var i = start
                            while i <= end {
                                if seen.insert(i).inserted { indexList.append(i) }
                                i += step
                            }
                        } else {
                            var i = start
                            while i >= end {
                                if seen.insert(i).inserted { indexList.append(i) }
                                i -= step
                            }
                        }
                    } else if let value = indexes[ix] as? Int {
                        if value >= 0 && value < count {
                            if seen.insert(value).inserted { indexList.append(value) }
                        } else if value < 0 && count >= -value {
                            let real = value + count
                            if seen.insert(real).inserted { indexList.append(real) }
                        }
                    }
                    ix -= 1
                }
            }

            if split == "!" {
                let removeSet = Set(indexList)
                elements = elements.enumerated().filter { !removeSet.contains($0.offset) }.map { $0.element }
            } else if split == "." {
                elements = indexList.compactMap { $0 < elements.count ? elements[$0] : nil }
            }
            return elements
        }

        private static func descendants(_ root: Element) -> [Element] {
            (try? root.getAllElements())?.array() ?? [root]
        }

        struct IndexRange {
            var start: Int?
            var end: Int?
            var step: Int
        }

        private func findIndexSet(_ rule: String) {
            let chars = Array(rule.utf16)
            guard !chars.isEmpty else {
                split = " "
                beforeRule = rule
                return
            }

            func charAt(_ i: Int) -> UInt16 { i >= 0 && i < chars.count ? chars[i] : 0 }
            func str(_ from: Int, _ to: Int) -> String {
                let lower = max(0, min(from, chars.count))
                let upper = max(lower, min(to, chars.count))
                return String(decoding: chars[lower..<upper], as: UTF16.self)
            }
            func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

            /// 与上游一致：找不到索引结构时 split 置空格、beforeRule 为整条规则
            func fallback() {
                split = " "
                beforeRule = rule.trimmingCharacters(in: .whitespaces)
            }

            let head = charAt(chars.count - 1) == 0x5D // ']'

            if head {
                var i = chars.count - 2
                var current: Int?
                var minus = false
                var currentList: [Int?] = []
                var digits = ""

                func flush() -> Int? {
                    guard !digits.isEmpty, let v = Int(digits) else { return nil }
                    return minus ? -v : v
                }

                while i >= 0 {
                    let rl = charAt(i)
                    i -= 1
                    if rl == 0x20 { continue }
                    if isDigit(rl) {
                        digits = String(UnicodeScalar(rl)!) + digits
                        continue
                    }
                    if rl == 0x2D { minus = true; continue }

                    current = flush()

                    if rl == 0x3A { // ':'
                        currentList.append(current)
                        digits = ""
                        minus = false
                        continue
                    }

                    // 单个索引或区间结束
                    if currentList.isEmpty {
                        guard let current else { break }
                        indexes.append(current)
                    } else {
                        let endValue: Int? = currentList.last ?? nil
                        let stepValue: Int = (currentList.count == 2 ? ((currentList.first ?? nil) ?? 1) : 1)
                        indexes.append(IndexRange(start: current, end: endValue, step: stepValue))
                        currentList.removeAll()
                    }

                    if rl == 0x21 { // '!'
                        split = "!"
                        repeat { i -= 1 } while i > 0 && charAt(i) == 0x20
                    }

                    if charAt(i) == 0x5B { // '['
                        beforeRule = str(0, i)
                        return
                    }

                    if rl != 0x2C { break } // ','
                    digits = ""
                    minus = false
                }

                // 不是索引写法（例如 `#id[title]`），整体当选择器
                if beforeRule.isEmpty { fallback() }
                return
            }

            // 旧式写法：tag.div.-1 / tag.div!0 / tag.div:2:3
            var j = chars.count - 1
            var minus = false
            var digits = ""
            while j >= 0 {
                let rl = charAt(j)
                j -= 1
                if rl == 0x20 { continue }
                if isDigit(rl) {
                    digits = String(UnicodeScalar(rl)!) + digits
                    continue
                }
                if rl == 0x2D { minus = true; continue }

                if rl == 0x21 || rl == 0x2E || rl == 0x3A { // ! . :
                    let value = Int(digits) ?? 0
                    indexDefault.append(minus ? -value : value)
                    if rl != 0x3A {
                        split = rl == 0x21 ? "!" : "."
                        beforeRule = str(0, j + 1)
                        return
                    }
                } else {
                    break
                }
                digits = ""
                minus = false
            }

            fallback()
        }
    }
}

// MARK: - SwiftSoup Elements 便捷

extension Elements {
    func array() -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(size())
        for i in 0..<size() {
            result.append(get(i))
        }
        return result
    }
}
