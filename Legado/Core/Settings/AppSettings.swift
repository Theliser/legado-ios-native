import Foundation
import SwiftUI

/// 应用级设置。对齐上游 `DownloadCacheSettings` / 阅读设置的关键项。
@Observable
final class AppSettings {
    static let defaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    var userAgent: String {
        didSet { defaults.set(userAgent, forKey: Keys.userAgent) }
    }

    var threadCount: Int {
        didSet { defaults.set(threadCount, forKey: Keys.threadCount) }
    }

    /// 阅读页字体大小
    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    var lineSpacing: Double {
        didSet { defaults.set(lineSpacing, forKey: Keys.lineSpacing) }
    }

    /// 阅读背景（0 纸黄 1 白 2 夜间）
    var readerTheme: Int {
        didSet { defaults.set(readerTheme, forKey: Keys.readerTheme) }
    }

    var enableDebugLog: Bool {
        didSet {
            defaults.set(enableDebugLog, forKey: Keys.debugLog)
            DebugLog.shared.enabled = enableDebugLog
        }
    }

    /// 正文净化后是否自动补段首缩进（对齐上游 replaceRegex 后的处理）
    var autoIndent: Bool {
        didSet { defaults.set(autoIndent, forKey: Keys.autoIndent) }
    }

    /// 是否信任自签/过期证书。上游为“放开所有证书”，书源站点常见此类问题，
    /// 因此默认开启；可在设置页关闭以恢复系统默认校验。
    var allowInsecureTLS: Bool {
        didSet { defaults.set(allowInsecureTLS, forKey: Keys.insecureTLS) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let userAgent = "settings.userAgent"
        static let threadCount = "settings.threadCount"
        static let fontSize = "settings.fontSize"
        static let lineSpacing = "settings.lineSpacing"
        static let readerTheme = "settings.readerTheme"
        static let debugLog = "settings.debugLog"
        static let autoIndent = "settings.autoIndent"
        static let insecureTLS = "settings.insecureTLS"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let ua = defaults.string(forKey: Keys.userAgent) ?? Self.defaultUserAgent
        self.userAgent = ua.isEmpty ? Self.defaultUserAgent : ua
        let threads = defaults.integer(forKey: Keys.threadCount)
        self.threadCount = threads == 0 ? 16 : threads
        let size = defaults.double(forKey: Keys.fontSize)
        self.fontSize = size == 0 ? 19 : size
        let spacing = defaults.double(forKey: Keys.lineSpacing)
        self.lineSpacing = spacing == 0 ? 8 : spacing
        self.readerTheme = defaults.object(forKey: Keys.readerTheme) as? Int ?? 0
        self.enableDebugLog = defaults.object(forKey: Keys.debugLog) as? Bool ?? true
        self.autoIndent = defaults.object(forKey: Keys.autoIndent) as? Bool ?? true
        self.allowInsecureTLS = defaults.object(forKey: Keys.insecureTLS) as? Bool ?? true
        DebugLog.shared.enabled = self.enableDebugLog
    }
}
