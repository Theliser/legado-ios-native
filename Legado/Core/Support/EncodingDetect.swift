import Foundation

/// 字符集探测：meta 标签优先，其次 BOM / UTF-8 合法性 / 中文编码回退。
/// 上游使用 ICU 探测器，这里用可用的等价手段覆盖中文站点常见情况。
enum EncodingDetect {

    static func htmlEncoding(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return "UTF-8" }
        if data.starts(with: [0xFF, 0xFE]) { return "UTF-16LE" }
        if data.starts(with: [0xFE, 0xFF]) { return "UTF-16BE" }

        // 头部 8KB 足够覆盖 meta charset
        let headData = data.prefix(8192)
        if let head = String(data: headData, encoding: .isoLatin1) {
            if let charset = scanMetaCharset(head) {
                return normalize(charset)
            }
        }
        return sniff(data)
    }

    private static func scanMetaCharset(_ head: String) -> String? {
        if let groups = head.firstMatchGroups("(?i)<meta[^>]+charset\\s*=\\s*[\"']?([\\w\\-]+)") {
            return groups.count > 1 ? groups[1] : nil
        }
        if let groups = head.firstMatchGroups("(?i)<meta[^>]+content\\s*=\\s*[\"'][^\"']*charset=([\\w\\-]+)") {
            return groups.count > 1 ? groups[1] : nil
        }
        return nil
    }

    private static func normalize(_ charset: String) -> String {
        let c = charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch c {
        case "gb2312", "gb_2312", "gb-2312", "gbk", "x-gbk": return "GB18030"
        case "utf8", "utf-8": return "UTF-8"
        case "big5", "big-5": return "Big5"
        default: return charset.uppercased()
        }
    }

    /// 无 meta 时：UTF-8 → GB18030 → Big5
    static func sniff(_ data: Data) -> String {
        if String(data: data, encoding: .utf8) != nil { return "UTF-8" }
        if String(data: data, encoding: stringEncoding(for: "GB18030")) != nil { return "GB18030" }
        if String(data: data, encoding: stringEncoding(for: "Big5")) != nil { return "Big5" }
        return "UTF-8"
    }

    static func stringEncoding(for charset: String) -> String.Encoding {
        let name = charset.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        switch lower {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "iso-8859-1", "latin1", "gb2312": return .isoLatin1
        case "ascii", "us-ascii": return .ascii
        case "gbk", "gb18030", "gb2312-80":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: cf)
        case "big5", "big5-hkscs":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String.Encoding(rawValue: cf)
        case "shift_jis", "sjis", "windows-31j":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.shiftJIS.rawValue))
            return String.Encoding(rawValue: cf)
        case "euc-jp":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_JP.rawValue))
            return String.Encoding(rawValue: cf)
        case "euc-kr":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))
            return String.Encoding(rawValue: cf)
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            }
            return .utf8
        }
    }

    /// 按指定字符集解码，失败时逐级回退；自动去掉 UTF-8 BOM
    static func decode(_ data: Data, charset: String? = nil) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        if let charset, !charset.isEmpty, let s = String(data: bytes, encoding: stringEncoding(for: charset)) {
            return s
        }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        return String(data: bytes, encoding: stringEncoding(for: "GB18030")) ?? ""
    }
}
