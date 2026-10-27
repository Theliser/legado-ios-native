import Foundation

/// 用系统 libxml2 实现 XPath 1.0，替代上游的 JXDocument（jsoup + Jaxen）。
/// 对外只暴露与解析链路相关的少量能力：选择节点、取文本、取属性、取 outerHtml。
final class XPathDocument {

    fileprivate let doc: xmlDocPtr
    private let isXML: Bool
    let sourceHTML: String

    init?(html: String) {
        var text = html
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 上游对片段表格做了补全，libxml2 的 HTML 解析器同样需要完整结构
        if text.hasSuffix("</td>") {
            text = "<tr>\(text)</tr>"
        }
        if text.hasSuffix("</tr>") || text.hasSuffix("</tbody>") {
            text = "<table>\(text)</table>"
        }
        // 先落成局部变量：闭包里不能读 self（此时成员尚未全部初始化）
        let xmlInput = trimmed.lowercased().hasPrefix("<?xml")

        var bytes = Array(text.utf8)
        let docPtr: xmlDocPtr? = bytes.withUnsafeBufferPointer { buf -> xmlDocPtr? in
            guard let base = buf.baseAddress else { return nil }
            return base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cptr in
                if xmlInput {
                    return xmlReadMemory(cptr, Int32(buf.count), nil, nil,
                                         Int32(XML_PARSE_RECOVER.rawValue | XML_PARSE_NOERROR.rawValue | XML_PARSE_NOWARNING.rawValue))
                }
                return htmlReadMemory(cptr, Int32(buf.count), nil, nil,
                                      Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue))
            }
        }
        guard let docPtr else { return nil }
        self.sourceHTML = text
        self.isXML = xmlInput
        self.doc = docPtr
    }

    deinit {
        xmlFreeDoc(doc)
    }

    func select(_ xpath: String) -> [XPathNode] {
        guard let ctx = xmlXPathNewContext(doc) else { return [] }
        defer { xmlXPathFreeContext(ctx) }
        guard let expr = xmlXPathEvalExpression(xpath, ctx) else { return [] }
        defer { xmlXPathFreeObject(expr) }

        guard expr.pointee.type == XPATH_NODESET,
              let nodeSet = expr.pointee.nodesetval else {
            return []
        }
        let count = Int(nodeSet.pointee.nodeNr)
        guard count > 0, let table = nodeSet.pointee.nodeTab else { return [] }
        var result: [XPathNode] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            if let node = table[i] {
                result.append(XPathNode(owner: self, node: node))
            }
        }
        return result
    }

    /// XPath 结果为标量（count()/string() 等）时使用
    func evaluateString(_ xpath: String) -> String? {
        guard let ctx = xmlXPathNewContext(doc) else { return nil }
        defer { xmlXPathFreeContext(ctx) }
        guard let expr = xmlXPathEvalExpression(xpath, ctx) else { return nil }
        defer { xmlXPathFreeObject(expr) }
        if let cstr = xmlXPathCastToString(expr) {
            let s = String(cString: cstr)
            xmlFree(cstr)
            return s
        }
        return nil
    }

    fileprivate func dump(_ node: xmlNodePtr, outer: Bool) -> String {
        guard let buffer = xmlBufferCreate() else { return "" }
        defer { xmlBufferFree(buffer) }
        if isXML {
            _ = xmlNodeDump(buffer, doc, node, 0, 1)
        } else {
            htmlNodeDump(buffer, doc, node)
        }
        guard let content = xmlBufferContent(buffer) else { return "" }
        return String(cString: content)
    }
}

struct XPathNode: Hashable {
    fileprivate let owner: XPathDocument
    fileprivate let node: xmlNodePtr

    static func == (lhs: XPathNode, rhs: XPathNode) -> Bool {
        lhs.node == rhs.node
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(UInt(bitPattern: node))
    }

    var isElement: Bool { node.pointee.type == XML_ELEMENT_NODE }
    var isAttribute: Bool { node.pointee.type == XML_ATTRIBUTE_NODE }
    var isText: Bool { node.pointee.type == XML_TEXT_NODE || node.pointee.type == XML_CDATA_SECTION_NODE }

    var name: String {
        guard let n = node.pointee.name else { return "" }
        return String(cString: n)
    }

    /// 对齐 JXNode.asString()：元素取文本（空白折叠），文本节点取原文，属性取值
    var stringValue: String {
        if isAttribute {
            return rawContent
        }
        if isText {
            return rawContent
        }
        let content = rawContent
        return content
            .replacingRegex("[\\t\\r\\n ]+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var rawContent: String {
        guard let c = xmlNodeGetContent(node) else { return "" }
        defer { xmlFree(c) }
        return String(cString: c)
    }

    var outerHtml: String {
        if isText { return stringValue }
        if isAttribute { return stringValue }
        return owner.dump(node, outer: true)
    }

    var innerHtml: String {
        var out = ""
        var child = node.pointee.children
        while let c = child {
            out += owner.dump(c, outer: true)
            child = c.pointee.next
        }
        return out
    }

    func attr(_ name: String) -> String? {
        guard let prop = xmlGetProp(node, name) else { return nil }
        defer { xmlFree(prop) }
        return String(cString: prop)
    }

    var attributes: [String: String] {
        var result: [String: String] = [:]
        var attrPtr = node.pointee.properties
        while let a = attrPtr {
            if let n = a.pointee.name,
               let value = xmlNodeListGetString(a.pointee.doc, a.pointee.children, 1) {
                result[String(cString: n)] = String(cString: value)
                xmlFree(value)
            }
            attrPtr = a.pointee.next
        }
        return result
    }

    var children: [XPathNode] {
        var result: [XPathNode] = []
        var child = node.pointee.children
        while let c = child {
            result.append(XPathNode(owner: owner, node: c))
            child = c.pointee.next
        }
        return result
    }

    var parent: XPathNode? {
        guard let p = node.pointee.parent else { return nil }
        return XPathNode(owner: owner, node: p)
    }
}
