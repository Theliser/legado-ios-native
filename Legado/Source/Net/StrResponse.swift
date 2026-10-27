import Foundation

/// 上游 `StrResponse` 的等价物：保留状态码、最终 URL、响应头与正文。
struct StrResponse {
    var url: String
    var body: String?
    var code: Int = 200
    var message: String = "OK"
    var headers: [String: String] = [:]
    var callTime: Int = 0
    var data: Data?
    /// 是否发生过重定向（对齐 `raw.priorResponse?.isRedirect`）
    var isRedirect: Bool = false
    var priorUrl: String?

    var isSuccessful: Bool { (200..<300).contains(code) }

    var errorBody: String? { isSuccessful ? nil : body }

    init(url: String, body: String?, code: Int = 200, message: String = "OK") {
        self.url = url
        self.body = body
        self.code = code
        self.message = message
    }

    init(url: String, error: String) {
        self.url = url
        self.body = error
        self.code = 500
        self.message = error
    }

    static func error(url: String, _ error: Error) -> StrResponse {
        StrResponse(url: url, error: error.localizedDescription)
    }

    func putCallTime(_ ms: Int) -> StrResponse {
        var copy = self
        copy.callTime = ms
        return copy
    }
}
