import Foundation

/// 规则切分器，逐行移植自上游 `RuleAnalyzer`。
/// 作用：在**不破坏选择器/正则内部符号**的前提下，按 `&&` `||` `%%` `@` 等分隔规则。
final class RuleAnalyzer {

    private let queue: [UInt16]
    private var pos = 0
    private var start = 0
    private var startX = 0

    private var rules: [String] = []
    private var step = 0
    private(set) var elementsType = ""

    private let code: Bool
    private static let esc: UInt16 = 0x5C // '\'

    init(_ data: String, code: Bool = false) {
        self.queue = Array(data.utf16)
        self.code = code
    }

    // MARK: - 基础

    private var length: Int { queue.count }

    private func char(_ index: Int) -> UInt16 {
        guard index >= 0, index < queue.count else { return 0 }
        return queue[index]
    }

    private func substring(_ from: Int, _ to: Int) -> String {
        let lower = max(0, min(from, queue.count))
        let upper = max(lower, min(to, queue.count))
        return String(decoding: queue[lower..<upper], as: UTF16.self)
    }

    private func substring(_ from: Int) -> String {
        substring(from, queue.count)
    }

    private func regionMatches(_ at: Int, _ seq: [UInt16]) -> Bool {
        guard at >= 0, at + seq.count <= queue.count else { return false }
        for i in 0..<seq.count where queue[at + i] != seq[i] { return false }
        return true
    }

    /// 修剪规则之前的 "@" 或空白符
    func trim() {
        guard pos < length else { return }
        if char(pos) == 0x40 || char(pos) < 0x21 { // '@' 或空白
            pos += 1
            while pos < length, char(pos) == 0x40 || char(pos) < 0x21 { pos += 1 }
            start = pos
            startX = pos
        }
    }

    private func consumeTo(_ seq: String) -> Bool {
        start = pos
        let seqChars = Array(seq.utf16)
        guard !seqChars.isEmpty else { return false }
        var index = pos
        while index + seqChars.count <= queue.count {
            if regionMatches(index, seqChars) {
                pos = index
                return true
            }
            index += 1
        }
        return false
    }

    private func consumeToAny(_ seqs: [String]) -> Bool {
        var cursor = pos
        while cursor != length {
            for s in seqs {
                let seqChars = Array(s.utf16)
                if regionMatches(cursor, seqChars) {
                    step = seqChars.count
                    pos = cursor
                    return true
                }
            }
            cursor += 1
        }
        return false
    }

    private func findToAny(_ chars: [UInt16]) -> Int {
        var cursor = pos
        while cursor != length {
            for c in chars where queue[cursor] == c { return cursor }
            cursor += 1
        }
        return -1
    }

    // MARK: - 平衡组

    private func chompCodeBalanced(_ open: UInt16, _ close: UInt16) -> Bool {
        var cursor = pos
        var depth = 0
        var otherDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        repeat {
            if cursor == length { break }
            let c = queue[cursor]
            cursor += 1
            if c != Self.esc {
                if c == 0x27 && !inDoubleQuote { inSingleQuote.toggle() }
                else if c == 0x22 && !inSingleQuote { inDoubleQuote.toggle() }

                if inSingleQuote || inDoubleQuote { continue }

                if c == 0x5B { depth += 1 }
                else if c == 0x5D { depth -= 1 }
                else if depth == 0 {
                    if c == open { otherDepth += 1 }
                    else if c == close { otherDepth -= 1 }
                }
            } else {
                cursor += 1
            }
        } while depth > 0 || otherDepth > 0

        if depth > 0 || otherDepth > 0 { return false }
        pos = cursor
        return true
    }

    private func chompRuleBalanced(_ open: UInt16, _ close: UInt16) -> Bool {
        var cursor = pos
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        repeat {
            if cursor == length { break }
            let c = queue[cursor]
            cursor += 1
            if c == 0x27 && !inDoubleQuote { inSingleQuote.toggle() }
            else if c == 0x22 && !inSingleQuote { inDoubleQuote.toggle() }

            if inSingleQuote || inDoubleQuote { continue }
            else if c == Self.esc { cursor += 1; continue }

            if c == open { depth += 1 }
            else if c == close { depth -= 1 }
        } while depth > 0

        if depth > 0 { return false }
        pos = cursor
        return true
    }

    private var chompBalanced: (UInt16, UInt16) -> Bool {
        code ? chompCodeBalanced : chompRuleBalanced
    }

    // MARK: - 切分

    /// 首段匹配；`elementsType` 初始为空
    func splitRule(_ splits: String...) -> [String] {
        splitRule(splits)
    }

    func splitRule(_ splits: [String]) -> [String] {
        if splits.count == 1 {
            elementsType = splits[0]
            if !consumeTo(elementsType) {
                rules.append(substring(startX))
                return rules
            }
            step = splits[0].utf16.count
            return splitRuleSecondary()
        }

        if !consumeToAny(splits) {
            rules.append(substring(startX))
            return rules
        }

        let end = pos
        pos = start

        repeat {
            let st = findToAny([0x5B, 0x28]) // '[' '('

            if st == -1 {
                rules = [substring(startX, end)]
                elementsType = substring(end, end + step)
                pos = end + step
                while consumeTo(elementsType) {
                    rules.append(substring(start, pos))
                    pos += step
                }
                rules.append(substring(pos))
                return rules
            }

            if st > end {
                rules = [substring(startX, end)]
                elementsType = substring(end, end + step)
                pos = end + step
                while consumeTo(elementsType) && pos < st {
                    rules.append(substring(start, pos))
                    pos += step
                }
                if pos > st {
                    startX = start
                    return splitRuleSecondary()
                }
                rules.append(substring(pos))
                return rules
            }

            pos = st
            let next: UInt16 = char(pos) == 0x5B ? 0x5D : 0x29
            if !chompBalanced(char(pos), next) {
                DebugLog.shared.log("Rule", "规则括号不平衡: \(substring(0, start))")
                rules.append(substring(startX))
                return rules
            }
        } while end > pos

        start = pos
        return splitRule(splits)
    }

    /// 二段匹配：`elementsType` 已确定
    private func splitRuleSecondary() -> [String] {
        let end = pos
        pos = start

        repeat {
            let st = findToAny([0x5B, 0x28])

            if st == -1 {
                rules.append(substring(startX, end))
                pos = end + step
                while consumeTo(elementsType) {
                    rules.append(substring(start, pos))
                    pos += step
                }
                rules.append(substring(pos))
                return rules
            }

            if st > end {
                rules.append(substring(startX, end))
                pos = end + step
                while consumeTo(elementsType) && pos < st {
                    rules.append(substring(start, pos))
                    pos += step
                }
                if pos > st {
                    startX = start
                    return splitRuleSecondary()
                }
                rules.append(substring(pos))
                return rules
            }

            pos = st
            let next: UInt16 = char(pos) == 0x5B ? 0x5D : 0x29
            if !chompBalanced(char(pos), next) {
                DebugLog.shared.log("Rule", "规则括号不平衡: \(substring(0, start))")
                rules.append(substring(startX))
                return rules
            }
        } while end > pos

        start = pos
        if !consumeTo(elementsType) {
            rules.append(substring(startX))
            return rules
        }
        return splitRuleSecondary()
    }

    // MARK: - 内嵌规则

    /// 替换 `{{ }}` 一类内嵌规则（使用代码平衡组）
    func innerRule(_ inner: String, startStep: Int = 1, endStep: Int = 1,
                   _ transform: (String) -> String?) -> String {
        var builder = ""
        var hasMatch = false

        while consumeTo(inner) {
            let posPre = pos
            if chompCodeBalanced(0x7B, 0x7D) { // '{' '}'
                let value = transform(substring(posPre + startStep, pos - endStep))
                if let value, !value.isEmpty {
                    builder += substring(startX, posPre) + value
                    startX = pos
                    hasMatch = true
                    continue
                }
            }
            pos += inner.utf16.count
        }

        if !hasMatch { return "" }
        builder += substring(startX)
        return builder
    }

    /// 替换成对标签内的内容（如 `{{ }}` 的直接切片版本）
    func innerRule(_ startStr: String, _ endStr: String,
                   _ transform: (String) -> String?) -> String {
        var builder = ""
        var hasMatch = false

        while consumeTo(startStr) {
            pos += startStr.utf16.count
            let posPre = pos
            if consumeTo(endStr) {
                let value = transform(substring(posPre, pos)) ?? ""
                builder += substring(startX, posPre - startStr.utf16.count) + value
                pos += endStr.utf16.count
                startX = pos
                hasMatch = true
            }
        }

        if !hasMatch { return "" }
        builder += substring(startX)
        return builder
    }
}
