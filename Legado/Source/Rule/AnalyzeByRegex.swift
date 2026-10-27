import Foundation

/// 正则规则解析，对齐上游 `AnalyzeByRegex`。
/// 规则形如 `正则1&&正则2`，最后一段的捕获组即结果。
enum AnalyzeByRegex {

    static func getElement(_ res: String, _ regs: [String], index: Int = 0) -> [String]? {
        guard index < regs.count else { return nil }
        guard let regex = RegexCache.shared.regex(regs[index]) else { return nil }
        let ns = res as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let first = regex.firstMatch(in: res, options: [], range: full) else { return nil }

        if index + 1 == regs.count {
            return (0..<first.numberOfRanges).map { i in
                let r = first.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
        var joined = ""
        for match in regex.matches(in: res, options: [], range: full) {
            joined += ns.substring(with: match.range)
        }
        return getElement(joined, regs, index: index + 1)
    }

    static func getElements(_ res: String, _ regs: [String], index: Int = 0) -> [[String]] {
        guard index < regs.count, let regex = RegexCache.shared.regex(regs[index]) else { return [] }
        let ns = res as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard regex.firstMatch(in: res, options: [], range: full) != nil else { return [] }

        if index + 1 == regs.count {
            var list: [[String]] = []
            for match in regex.matches(in: res, options: [], range: full) {
                let groups = (0..<match.numberOfRanges).map { i -> String in
                    let r = match.range(at: i)
                    return r.location == NSNotFound ? "" : ns.substring(with: r)
                }
                list.append(groups)
            }
            return list
        }

        var joined = ""
        for match in regex.matches(in: res, options: [], range: full) {
            joined += ns.substring(with: match.range)
        }
        return getElements(joined, regs, index: index + 1)
    }
}
