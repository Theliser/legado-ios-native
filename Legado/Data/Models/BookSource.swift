import Foundation
import GRDB

// MARK: - 书源类型

enum BookSourceType: Int, Codable, CaseIterable, Sendable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3
    case video = 4

    var label: String {
        switch self {
        case .text: return "文本"
        case .audio: return "音频"
        case .image: return "图片"
        case .file: return "文件"
        case .video: return "视频"
        }
    }
}

// MARK: - 规则 JSON 列

/// 规则在数据库里以 JSON 字符串存储（对齐 Room 的 TypeConverter）
protocol RuleJSONColumn: Codable {}

/// 规则结构体与数据库 JSON 文本之间的编解码。
/// 注意：不能放在 `RuleJSONColumn` 的协议扩展里当作 `DatabaseValueConvertible`
/// 的实现——协议扩展的成员不能作为另一个协议的 witness，编译器会报
/// "multiple matching properties"。所以每个类型都在下方单独写扩展。
enum RuleJSONCoding {
    static func encode<T: Encodable>(_ value: T) -> DatabaseValue {
        (JSONTool.stringify(value) ?? "null").databaseValue
    }

    static func decode<T: Decodable>(_ dbValue: DatabaseValue, as type: T.Type) -> T? {
        guard let text = String.fromDatabaseValue(dbValue), text != "null" else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

/// 规则字段既可能是对象，也可能是被写成字符串的 JSON（上游用 JsonDeserializer 兼容）
private func decodeRuleObject<T: Decodable>(_ type: T.Type, from decoder: Decoder) throws -> T {
    if let single = try? decoder.singleValueContainer(),
       let text = try? single.decode(String.self) {
        guard let data = text.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "rule string"))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    return try T(from: decoder)
}

// MARK: - 搜索规则

struct SearchRule: Codable, Equatable, RuleJSONColumn {
    var checkKeyWord: String?
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?

    init(checkKeyWord: String? = nil, bookList: String? = nil, name: String? = nil,
         author: String? = nil, intro: String? = nil, kind: String? = nil,
         lastChapter: String? = nil, updateTime: String? = nil, bookUrl: String? = nil,
         coverUrl: String? = nil, wordCount: String? = nil) {
        self.checkKeyWord = checkKeyWord
        self.bookList = bookList
        self.name = name
        self.author = author
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.wordCount = wordCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkKeyWord = try c.decodeIfPresent(String.self, forKey: .checkKeyWord)
        bookList = try c.decodeIfPresent(String.self, forKey: .bookList)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        intro = try c.decodeIfPresent(String.self, forKey: .intro)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        lastChapter = try c.decodeIfPresent(String.self, forKey: .lastChapter)
        updateTime = try c.decodeIfPresent(String.self, forKey: .updateTime)
        bookUrl = try c.decodeIfPresent(String.self, forKey: .bookUrl)
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        wordCount = try c.decodeIfPresent(String.self, forKey: .wordCount)
    }

    static func decodeFlexible(_ decoder: Decoder) throws -> SearchRule {
        try decodeRuleObject(SearchRule.self, from: decoder)
    }
}

// MARK: - 发现规则

struct ExploreRule: Codable, Equatable, RuleJSONColumn {
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookList = try c.decodeIfPresent(String.self, forKey: .bookList)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        intro = try c.decodeIfPresent(String.self, forKey: .intro)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        lastChapter = try c.decodeIfPresent(String.self, forKey: .lastChapter)
        updateTime = try c.decodeIfPresent(String.self, forKey: .updateTime)
        bookUrl = try c.decodeIfPresent(String.self, forKey: .bookUrl)
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        wordCount = try c.decodeIfPresent(String.self, forKey: .wordCount)
    }
}

// MARK: - 详情规则

struct BookInfoRule: Codable, Equatable, RuleJSONColumn {
    /// 上游字段名为 init，Swift 里改用 initRule 避免关键字冲突
    var initRule: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var coverUrl: String?
    var tocUrl: String?
    var wordCount: String?
    var canReName: String?
    var downloadUrls: String?
    var relatedBooks: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        initRule = try c.decodeIfPresent(String.self, forKey: .initRule)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        intro = try c.decodeIfPresent(String.self, forKey: .intro)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        lastChapter = try c.decodeIfPresent(String.self, forKey: .lastChapter)
        updateTime = try c.decodeIfPresent(String.self, forKey: .updateTime)
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
        tocUrl = try c.decodeIfPresent(String.self, forKey: .tocUrl)
        wordCount = try c.decodeIfPresent(String.self, forKey: .wordCount)
        canReName = try c.decodeIfPresent(String.self, forKey: .canReName)
        downloadUrls = try c.decodeIfPresent(String.self, forKey: .downloadUrls)
        relatedBooks = try c.decodeIfPresent(String.self, forKey: .relatedBooks)
    }

    enum CodingKeys: String, CodingKey {
        case initRule = "init"
        case name, author, intro, kind, lastChapter, updateTime, coverUrl, tocUrl
        case wordCount, canReName, downloadUrls, relatedBooks
    }
}

// MARK: - 目录规则

struct TocRule: Codable, Equatable, RuleJSONColumn {
    var preUpdateJs: String?
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var formatJs: String?
    var isVolume: String?
    var isVip: String?
    var isPay: String?
    var updateTime: String?
    var nextTocUrl: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preUpdateJs = try c.decodeIfPresent(String.self, forKey: .preUpdateJs)
        chapterList = try c.decodeIfPresent(String.self, forKey: .chapterList)
        chapterName = try c.decodeIfPresent(String.self, forKey: .chapterName)
        chapterUrl = try c.decodeIfPresent(String.self, forKey: .chapterUrl)
        formatJs = try c.decodeIfPresent(String.self, forKey: .formatJs)
        isVolume = try c.decodeIfPresent(String.self, forKey: .isVolume)
        isVip = try c.decodeIfPresent(String.self, forKey: .isVip)
        isPay = try c.decodeIfPresent(String.self, forKey: .isPay)
        updateTime = try c.decodeIfPresent(String.self, forKey: .updateTime)
        nextTocUrl = try c.decodeIfPresent(String.self, forKey: .nextTocUrl)
    }
}

// MARK: - 正文规则

struct ContentRule: Codable, Equatable, RuleJSONColumn {
    var content: String?
    var subContent: String?
    var title: String?
    var nextContentUrl: String?
    var webJs: String?
    var sourceRegex: String?
    var replaceRegex: String?
    var imageStyle: String?
    var imageDecode: String?
    var payAction: String?
    var callBackJs: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        subContent = try c.decodeIfPresent(String.self, forKey: .subContent)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        nextContentUrl = try c.decodeIfPresent(String.self, forKey: .nextContentUrl)
        webJs = try c.decodeIfPresent(String.self, forKey: .webJs)
        sourceRegex = try c.decodeIfPresent(String.self, forKey: .sourceRegex)
        replaceRegex = try c.decodeIfPresent(String.self, forKey: .replaceRegex)
        imageStyle = try c.decodeIfPresent(String.self, forKey: .imageStyle)
        imageDecode = try c.decodeIfPresent(String.self, forKey: .imageDecode)
        payAction = try c.decodeIfPresent(String.self, forKey: .payAction)
        callBackJs = try c.decodeIfPresent(String.self, forKey: .callBackJs)
    }
}

// MARK: - 段评规则（当前仅透传）

struct ReviewRule: Codable, Equatable, RuleJSONColumn {
    var reviewUrl: String?
    var reviewList: String?
    var reviewName: String?
    var reviewContent: String?
    var reviewTime: String?
    var reviewQuote: String?
    var reviewAvatart: String?
    var reviewLoadMore: String?
    var reviewPostUrl: String?
    var reviewPostBody: String?
    var reviewVisitName: String?
    var reviewVisitTime: String?
    var reviewPostQuote: String?
    var reviewPostTitle: String?
    var reviewPostContent: String?
    var reviewPostOther: String?
    var reviewPostHeaders: String?
    var reviewPostUrlRegex: String?
    var reviewPostBodyRegex: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewUrl = try c.decodeIfPresent(String.self, forKey: .reviewUrl)
        reviewList = try c.decodeIfPresent(String.self, forKey: .reviewList)
        reviewName = try c.decodeIfPresent(String.self, forKey: .reviewName)
        reviewContent = try c.decodeIfPresent(String.self, forKey: .reviewContent)
        reviewTime = try c.decodeIfPresent(String.self, forKey: .reviewTime)
        reviewQuote = try c.decodeIfPresent(String.self, forKey: .reviewQuote)
        reviewAvatart = try c.decodeIfPresent(String.self, forKey: .reviewAvatart)
        reviewLoadMore = try c.decodeIfPresent(String.self, forKey: .reviewLoadMore)
    }
}

// MARK: - 书源

struct BookSource: Codable, Identifiable, Hashable {
    var bookSourceUrl: String = ""
    var bookSourceName: String = ""
    var bookSourceGroup: String?
    var bookSourceType: Int = 0
    var bookUrlPattern: String?
    var customOrder: Int = 0
    var enabled: Bool = true
    var enabledExplore: Bool = true
    var jsLib: String?
    var enabledCookieJar: Bool? = true
    var concurrentRate: String?
    var header: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var coverDecodeJs: String?
    var bookSourceComment: String?
    var variableComment: String?
    var lastUpdateTime: Int64 = 0
    var respondTime: Int64 = 180000
    var weight: Int = 0
    var exploreUrl: String?
    var exploreScreen: String?
    var ruleExplore: ExploreRule?
    var searchUrl: String?
    var ruleSearch: SearchRule?
    var ruleBookInfo: BookInfoRule?
    var ruleToc: TocRule?
    var ruleContent: ContentRule?
    var ruleReview: ReviewRule?
    var eventListener: Bool = false
    var customButton: Bool = false
    var homepageModules: String?

    var id: String { bookSourceUrl }

    static let databaseTableName = "book_sources"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceUrl = try c.decodeIfPresent(String.self, forKey: .bookSourceUrl) ?? ""
        bookSourceName = try c.decodeIfPresent(String.self, forKey: .bookSourceName) ?? ""
        bookSourceGroup = try c.decodeIfPresent(String.self, forKey: .bookSourceGroup)
        bookSourceType = try c.decodeIfPresent(Int.self, forKey: .bookSourceType) ?? 0
        bookUrlPattern = try c.decodeIfPresent(String.self, forKey: .bookUrlPattern)
        customOrder = try c.decodeIfPresent(Int.self, forKey: .customOrder) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        enabledExplore = try c.decodeIfPresent(Bool.self, forKey: .enabledExplore) ?? true
        jsLib = try c.decodeIfPresent(String.self, forKey: .jsLib)
        enabledCookieJar = try c.decodeIfPresent(Bool.self, forKey: .enabledCookieJar) ?? true
        concurrentRate = try c.decodeIfPresent(String.self, forKey: .concurrentRate)
        header = try c.decodeIfPresent(String.self, forKey: .header)
        loginUrl = try c.decodeIfPresent(String.self, forKey: .loginUrl)
        loginUi = try c.decodeIfPresent(String.self, forKey: .loginUi)
        loginCheckJs = try c.decodeIfPresent(String.self, forKey: .loginCheckJs)
        coverDecodeJs = try c.decodeIfPresent(String.self, forKey: .coverDecodeJs)
        bookSourceComment = try c.decodeIfPresent(String.self, forKey: .bookSourceComment)
        variableComment = try c.decodeIfPresent(String.self, forKey: .variableComment)
        lastUpdateTime = try c.decodeIfPresent(Int64.self, forKey: .lastUpdateTime) ?? 0
        respondTime = try c.decodeIfPresent(Int64.self, forKey: .respondTime) ?? 180000
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 0
        exploreUrl = try c.decodeIfPresent(String.self, forKey: .exploreUrl)
        exploreScreen = try c.decodeIfPresent(String.self, forKey: .exploreScreen)

        // 规则字段：对象或字符串两种写法都接受
        if let container = try? c.decode(SingleRuleBox<ExploreRule>.self, forKey: .ruleExplore) {
            ruleExplore = container.value
        }
        if let container = try? c.decode(SingleRuleBox<SearchRule>.self, forKey: .ruleSearch) {
            ruleSearch = container.value
        }
        if let container = try? c.decode(SingleRuleBox<BookInfoRule>.self, forKey: .ruleBookInfo) {
            ruleBookInfo = container.value
        }
        if let container = try? c.decode(SingleRuleBox<TocRule>.self, forKey: .ruleToc) {
            ruleToc = container.value
        }
        if let container = try? c.decode(SingleRuleBox<ContentRule>.self, forKey: .ruleContent) {
            ruleContent = container.value
        }
        if let container = try? c.decode(SingleRuleBox<ReviewRule>.self, forKey: .ruleReview) {
            ruleReview = container.value
        }

        searchUrl = try c.decodeIfPresent(String.self, forKey: .searchUrl)
        eventListener = try c.decodeIfPresent(Bool.self, forKey: .eventListener) ?? false
        customButton = try c.decodeIfPresent(Bool.self, forKey: .customButton) ?? false
        homepageModules = try c.decodeIfPresent(String.self, forKey: .homepageModules)
    }

    // MARK: 便捷访问

    var sourceType: BookSourceType { BookSourceType(rawValue: bookSourceType) ?? .text }
    var key: String { bookSourceUrl }
    var tag: String { bookSourceName }

    var searchRule: SearchRule {
        get { ruleSearch ?? SearchRule() }
        set { ruleSearch = newValue }
    }
    var exploreRuleObj: ExploreRule {
        get { ruleExplore ?? ExploreRule() }
        set { ruleExplore = newValue }
    }
    var bookInfoRule: BookInfoRule {
        get { ruleBookInfo ?? BookInfoRule() }
        set { ruleBookInfo = newValue }
    }
    var tocRule: TocRule {
        get { ruleToc ?? TocRule() }
        set { ruleToc = newValue }
    }
    var contentRule: ContentRule {
        get { ruleContent ?? ContentRule() }
        set { ruleContent = newValue }
    }

    func getCheckKeyWord(default def: String) -> String {
        guard let keyword = ruleSearch?.checkKeyWord,
              !keyword.isBlank,
              !keyword.contains("http"),
              !keyword.contains("::"),
              !keyword.contains("++"),
              !keyword.contains("--") else { return def }
        return keyword
    }

    var displayNameGroup: String {
        if let group = bookSourceGroup, !group.isBlank {
            return "\(bookSourceName) (\(group))"
        }
        return bookSourceName
    }

    func hasGroup(_ group: String) -> Bool {
        guard let bookSourceGroup else { return false }
        return bookSourceGroup.splitNotBlank("[,;，；]").contains(group)
    }

    mutating func addGroup(_ groups: String) {
        var set = Set(bookSourceGroup?.splitNotBlank("[,;，；]") ?? [])
        set.formUnion(groups.splitNotBlank("[,;，；]"))
        bookSourceGroup = set.joined(separator: ",")
    }

    mutating func removeGroup(_ groups: String) {
        var set = Set(bookSourceGroup?.splitNotBlank("[,;，；]") ?? [])
        set.subtract(groups.splitNotBlank("[,;，；]"))
        bookSourceGroup = set.joined(separator: ",")
    }

    func headerMap(userAgent: String? = nil) -> [String: String] {
        var map: [String: String] = [:]
        if let header, let obj = JSONTool.parseObject(header) {
            for (k, v) in obj {
                if let s = JSONTool.stringify(v) { map[k] = s }
            }
        }
        if let ua = map["User-Agent"], !ua.isBlank { return map }
        if let userAgent { map["User-Agent"] = userAgent }
        return map
    }

    static func == (lhs: BookSource, rhs: BookSource) -> Bool {
        lhs.bookSourceUrl == rhs.bookSourceUrl
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bookSourceUrl)
    }
}

/// 兼容 "ruleXxx": "{...}" 这种把 JSON 当字符串写的书源
private struct SingleRuleBox<T: Decodable>: Decodable {
    let value: T

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            guard let data = text.data(using: .utf8) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "rule"))
            }
            value = try JSONDecoder().decode(T.self, from: data)
            return
        }
        value = try T(from: decoder)
    }
}

// MARK: - DatabaseValueConvertible


extension SearchRule: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { RuleJSONCoding.encode(self) }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> SearchRule? {
        RuleJSONCoding.decode(dbValue, as: SearchRule.self)
    }
}

extension ExploreRule: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { RuleJSONCoding.encode(self) }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> ExploreRule? {
        RuleJSONCoding.decode(dbValue, as: ExploreRule.self)
    }
}

extension BookInfoRule: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { RuleJSONCoding.encode(self) }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> BookInfoRule? {
        RuleJSONCoding.decode(dbValue, as: BookInfoRule.self)
    }
}

extension TocRule: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { RuleJSONCoding.encode(self) }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> TocRule? {
        RuleJSONCoding.decode(dbValue, as: TocRule.self)
    }
}

extension ContentRule: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { RuleJSONCoding.encode(self) }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> ContentRule? {
        RuleJSONCoding.decode(dbValue, as: ContentRule.self)
    }
}

extension ReviewRule: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { RuleJSONCoding.encode(self) }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> ReviewRule? {
        RuleJSONCoding.decode(dbValue, as: ReviewRule.self)
    }
}
