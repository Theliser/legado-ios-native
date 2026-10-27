import Foundation

/// JSONPath 解析包装，替代上游 `AnalyzeByJSonPath`（Jayway）。
final class AnalyzeByJSONPath {

    private let json: Any

    init(_ json: Any) {
        if let text = json as? String {
            self.json = JSONTool.parse(text) ?? [String: Any]()
        } else {
            self.json = json
        }
    }

    private var root: Any {
        if let dict = json as? [String: Any], dict.isEmpty { return [String: Any]() }
        return json
    }

    func getString(_ rule: String) -> String? {
        guard !rule.isEmpty else { return nil }
        let analyzer = RuleAnalyzer(rule, code: true)
        let rules = analyzer.splitRule("&&", "||")
        if rules.count == 1 {
            let replaced = analyzer.innerRule("{$.") { [weak self] inner in
                self?.getString(inner)
            }
            if !replaced.isEmpty { return replaced }
            guard let values = try? JSONPath.evaluate(rule, on: root) else { return nil }
            guard !values.isEmpty else { return nil }
            // jayway 的 ctx.read()：不定路径（通配/过滤）返回匹配列表，定路径返回值本身。
            // 两种情况最终都用 "\n" 拼，这里统一按「多结果先拼、单结果若为数组再拆」处理。
            if values.count > 1 {
                return values.map { AnalyzeRule.stringValue($0) }.joined(separator: "\n")
            }
            let value = values[0]
            if let array = value as? [Any] {
                return array.map { AnalyzeRule.stringValue($0) }.joined(separator: "\n")
            }
            return AnalyzeRule.stringValue(value)
        }

        var texts: [String] = []
        for part in rules {
            if let text = getString(part), !text.isEmpty {
                texts.append(text)
                if analyzer.elementsType == "||" { break }
            }
        }
        return texts.joined(separator: "\n")
    }

    func getStringList(_ rule: String) -> [String] {
        guard !rule.isEmpty else { return [] }
        let analyzer = RuleAnalyzer(rule, code: true)
        let rules = analyzer.splitRule("&&", "||", "%%")
        if rules.count == 1 {
            let replaced = analyzer.innerRule("{$.") { [weak self] inner in
                self?.getString(inner)
            }
            if !replaced.isEmpty { return [replaced] }
            guard let value = try? JSONPath.evaluate(rule, on: root) else { return [] }
            return value.map { AnalyzeRule.stringValue($0) }
        }

        var results: [[String]] = []
        for part in rules {
            let temp = getStringList(part)
            if !temp.isEmpty {
                results.append(temp)
                if analyzer.elementsType == "||" { break }
            }
        }
        var output: [String] = []
        if !results.isEmpty {
            if analyzer.elementsType == "%%" {
                for i in 0..<results[0].count {
                    for temp in results where i < temp.count {
                        output.append(temp[i])
                    }
                }
            } else {
                for temp in results { output.append(contentsOf: temp) }
            }
        }
        return output
    }

    func getObject(_ rule: String) -> Any? {
        (try? JSONPath.evaluate(rule, on: root))?.first
    }

    func getList(_ rule: String) -> [Any] {
        guard !rule.isEmpty else { return [] }
        let analyzer = RuleAnalyzer(rule, code: true)
        let rules = analyzer.splitRule("&&", "||", "%%")
        if rules.count == 1 {
            return (try? JSONPath.evaluate(rules[0], on: root)) ?? []
        }
        var results: [[Any]] = []
        for part in rules {
            let temp = getList(part)
            if !temp.isEmpty {
                results.append(temp)
                if analyzer.elementsType == "||" { break }
            }
        }
        var output: [Any] = []
        if !results.isEmpty {
            if analyzer.elementsType == "%%" {
                for i in 0..<results[0].count {
                    for temp in results where i < temp.count {
                        output.append(temp[i])
                    }
                }
            } else {
                for temp in results { output.append(contentsOf: temp) }
            }
        }
        return output
    }
}
