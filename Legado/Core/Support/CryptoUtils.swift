import Foundation
import CryptoKit

/// 对齐 `JsExtensions` 里的编解码工具，供 JS 桥与规则引擎复用。
enum CryptoUtils {

    static func md5(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Upper(_ input: String) -> String {
        md5(input).uppercased()
    }

    static func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    static func base64Decode(_ input: String) -> String? {
        guard let data = base64DecodeData(input) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func base64DecodeData(_ input: String) -> Data? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s, options: [.ignoreUnknownCharacters])
    }

    static func hexEncode(_ utf8: String) -> String {
        Data(utf8.utf8).map { String(format: "%02x", $0) }.joined()
    }

    static func hexDecode(_ hex: String) -> Data? {
        var data = Data()
        var chars = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if chars.count % 2 != 0 { return nil }
        var i = 0
        while i < chars.count {
            let pair = String(chars[i...i + 1])
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            data.append(byte)
            i += 2
        }
        return data
    }

    static func hexDecodeToString(_ hex: String) -> String? {
        guard let data = hexDecode(hex) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// JavaScript `escape()`，对齐 OkHttp 里的 `escape` 模式
    static func escape(_ input: String) -> String {
        var out = ""
        for scalar in input.unicodeScalars {
            let v = scalar.value
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9":
                out.unicodeScalars.append(scalar)
            case "@", "*", "_", "+", "-", ".", "/":
                out.unicodeScalars.append(scalar)
            default:
                if v < 256 {
                    out += String(format: "%%%02X", v)
                } else if v <= 0xFFFF {
                    out += String(format: "%%u%04X", v)
                } else {
                    // 代理对
                    let vv = v - 0x10000
                    let high = 0xD800 + (vv >> 10)
                    let low = 0xDC00 + (vv & 0x3FF)
                    out += String(format: "%%u%04X%%u%04X", high, low)
                }
            }
        }
        return out
    }

    static func urlEncode(_ input: String, charset: String) -> String {
        if charset.lowercased() == "escape" { return escape(input) }
        let encoding = EncodingDetect.stringEncoding(for: charset)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "*-._")
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }
}
