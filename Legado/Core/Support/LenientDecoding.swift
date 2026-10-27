import Foundation

/// 宽松解码。
///
/// 真实书源 JSON 是「人写 + 各种工具生成」的，同一个字段时而是数字、时而是字符串：
/// `"lastUpdateTime": 1730000000` 与 `"lastUpdateTime": "1730000000"` 都见过，
/// 甚至出现过 `"enabled": 1`。上游用 Gson，对这类写法一律包容；
/// Swift 的 `Codable` 默认严格，一条不合法就会让整份书源导入失败。
///
/// 这里统一按「能读就读」的策略：读不出就返回 nil，由调用方给默认值。
extension KeyedDecodingContainer {

    func lenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed) { return value }
            if let value = Double(trimmed) { return Int(value) }
            // "true"/"false" 也当成 1/0
            switch trimmed.lowercased() {
            case "true": return 1
            case "false": return 0
            default: return nil
            }
        }
        return nil
    }

    func lenientInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        return lenientInt(forKey: key).map(Int64.init)
    }

    func lenientBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = lenientInt(forKey: key) { return value != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// 字符串字段偶尔被写成数字（如 `"bookSourceGroup": 1`），一并包容
    func lenientString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return "\(value)" }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return "\(value)" }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return "\(value)" }
        return nil
    }
}
