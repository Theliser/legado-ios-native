import Foundation
import SwiftSoup

/// XPath 规则解析，替代上游 `AnalyzeByXPath`（JXDocument）。
final class AnalyzeByXPath {

    private let document: XPathDocument
    private let node: XPathNode?

    init(_ doc: Any) {
        if let xpathNode = doc as? XPathNode {
            self.node = xpathNode
            if xpathNode.isElement,
               let parsed = XPathDocument(html: xpathNode.outerHtml) {
                self.document = parsed
            } else if let parsed = XPathDocument(html: xpathNode.stringValue) {
                self.document = parsed
            } else {
                self.document = XPathDocument(html: "<html></html>")!
            }
        } else if let element = doc as? SwiftSoup.Element {
            let html = (try? element.outerHtml()) ?? "\(doc)"
            self.node = nil
            self.document = XPathDocument(html: html) ?? XPathDocument(html: "<html></html>")!
        } else {
            let html = "\(doc)"
            self.node = nil
            self.document = XPathDocument(html: html) ?? XPathDocument(html: "<html></html>")!
        }
    }

    private func getResult(_ xpath: String) -> [XPathNode] {
        if let node {
            // 节点上下文：在片段内部查找
            let html = node.outerHtml
            if let scoped = XPathDocument(html: html) {
                return scoped.select(xpath)
            }
        }
        return document.select(xpath)
    }

    func getElements(_ xpath: String) -> [XPathNode] {
        guard !xpath.isEmpty else { return [] }
        let analyzer = RuleAnalyzer(xpath)
        let rules = analyzer.splitRule("&&", "||", "%%")
        if rules.count == 1 {
            return getResult(rules[0])
        }

        var results: [[XPathNode]] = []
        for rule in rules {
            let temp = getElements(rule)
            if !temp.isEmpty {
                results.append(temp)
                if analyzer.elementsType == "||" { break }
            }
        }
        var output: [XPathNode] = []
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

    func getStringList(_ xpath: String) -> [String] {
        var result: [String] = []
        let analyzer = RuleAnalyzer(xpath)
        let rules = analyzer.splitRule("&&", "||", "%%")

        if rules.count == 1 {
            return getResult(xpath).map { $0.stringValue }
        }

        var results: [[String]] = []
        for rule in rules {
            let temp = getStringList(rule)
            if !temp.isEmpty {
                results.append(temp)
                if analyzer.elementsType == "||" { break }
            }
        }
        if !results.isEmpty {
            if analyzer.elementsType == "%%" {
                for i in 0..<results[0].count {
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

    func getString(_ rule: String) -> String? {
        let analyzer = RuleAnalyzer(rule)
        let rules = analyzer.splitRule("&&", "||")
        if rules.count == 1 {
            let nodes = getResult(rule)
            if nodes.isEmpty { return nil }
            return nodes.map { $0.stringValue }.joined(separator: "\n")
        }
        var texts: [String] = []
        for rule in rules {
            if let text = getString(rule), !text.isEmpty {
                texts.append(text)
                if analyzer.elementsType == "||" { break }
            }
        }
        return texts.joined(separator: "\n")
    }

    func getObject(_ rule: String) -> Any? {
        getResult(rule).first
    }

    func getList(_ rule: String) -> [Any] {
        getResult(rule)
    }
}

