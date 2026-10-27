import Foundation
import GRDB

// MARK: - 变量容器

protocol RuleDataInterface: AnyObject {
    var variableMap: [String: String] { get set }
    func putVariable(_ key: String, _ value: String?) -> Bool
    func getVariable(_ key: String) -> String?
}

extension RuleDataInterface {
    func getVariable(_ key: String) -> String? {
        variableMap[key]
    }
}

// MARK: - 书籍

struct Book: Codable, Identifiable, Hashable {
    var bookUrl: String = ""
    var tocUrl: String = ""
    var origin: String = BookType.localTag
    var originName: String = ""
    var name: String = ""
    var author: String = ""
    var kind: String?
    var customTag: String?
    var coverUrl: String?
    var customCoverUrl: String?
    var intro: String?
    var customIntro: String?
    var remark: String?
    var charset: String?
    var type: Int = BookType.text
    var group: Int64 = 0
    var isPrivate: Bool = false
    var latestChapterTitle: String?
    var latestChapterTime: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var lastCheckTime: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var lastCheckCount: Int = 0
    var totalChapterNum: Int = 0
    var durChapterTitle: String?
    var durChapterIndex: Int = 0
    var durChapterPos: Int = 0
    var durChapterTime: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var wordCount: String?
    var canUpdate: Bool = true
    var disableReadRecord: Bool = false
    var order: Int = 0
    var originOrder: Int = 0
    var variable: String?
    /// 阅读设置，原样保存 JSON（对齐上游 ReadConfig）
    var readConfig: String?
    var syncTime: Int64 = 0
    var listIntro: String?

    var id: String { bookUrl }

    static let databaseTableName = "books"

    // 运行期字段（不入库，对齐 @Ignore）
    var infoHtml: String?
    var tocHtml: String?
    var downloadUrls: [String]?

    enum CodingKeys: String, CodingKey {
        case bookUrl, tocUrl, origin, originName, name, author, kind, customTag
        case coverUrl, customCoverUrl, intro, customIntro, remark, charset, type, group
        case isPrivate, latestChapterTitle, latestChapterTime, lastCheckTime, lastCheckCount
        case totalChapterNum, durChapterTitle, durChapterIndex, durChapterPos, durChapterTime
        case wordCount, canUpdate, disableReadRecord, order, originOrder, variable
        case readConfig, syncTime, listIntro
    }

    init() {}

    var variableMap: [String: String] {
        get { JSONTool.parseObject(variable)?.compactMapValues { JSONTool.stringify($0) } ?? [:] }
        set { variable = JSONTool.stringify(newValue) }
    }

    var readConfigObject: [String: Any] {
        JSONTool.parseObject(readConfig) ?? [:]
    }

    var lastChapterIndex: Int { totalChapterNum - 1 }
    var displayCover: String? { (customCoverUrl?.isEmpty == false) ? customCoverUrl : coverUrl }
    var displayIntro: String? { (customIntro?.isEmpty == false) ? customIntro : intro }
    var displayName: String { name.isEmpty ? bookUrl : name }

    func getRealAuthor() -> String {
        author.replacingRegex("^\\s*作\\s*者[:：\\s]+|\\s+著", with: "")
    }

    var unreadChapterNum: Int { max(totalChapterNum - durChapterIndex - 1, 0) }

    /// 对齐 `simulatedTotalChapterNum`（音量章节等特殊类型暂按普通处理）
    func simulatedTotalChapterNum() -> Int { totalChapterNum }

    static func == (lhs: Book, rhs: Book) -> Bool { lhs.bookUrl == rhs.bookUrl }
    func hash(into hasher: inout Hasher) { hasher.combine(bookUrl) }
}

// MARK: - 章节

struct BookChapter: Codable, Identifiable, Hashable {
    var url: String = ""
    var title: String = ""
    var isVolume: Bool = false
    var tocLevel: Int = 0
    var baseUrl: String = ""
    var bookUrl: String = ""
    var index: Int = 0
    var isVip: Bool = false
    var isPay: Bool = false
    var resourceUrl: String?
    var tag: String?
    var wordCount: String?
    var start: Int64?
    var end: Int64?
    var startFragmentId: String?
    var endFragmentId: String?
    var variable: String?
    var reviewImg: String?

    var id: String { bookUrl + "|" + url }

    static let databaseTableName = "chapters"

    init() {}

    init(bookUrl: String, baseUrl: String) {
        self.bookUrl = bookUrl
        self.baseUrl = baseUrl
    }

    var variableMap: [String: String] {
        get { JSONTool.parseObject(variable)?.compactMapValues { JSONTool.stringify($0) } ?? [:] }
        set { variable = JSONTool.stringify(newValue) }
    }

    /// 对齐 `getAbsoluteURL()`：优先使用章节归属的 baseUrl
    func getAbsoluteURL() -> String {
        NetworkUtils.getAbsoluteURL(baseUrl.isEmpty ? bookUrl : baseUrl, url)
    }

    /// 用于缓存文件名的稳定标识
    func fileName() -> String {
        CryptoUtils.md5(bookUrl + "|" + url + "|" + title)
    }

    static func == (lhs: BookChapter, rhs: BookChapter) -> Bool {
        lhs.url == rhs.url && lhs.bookUrl == rhs.bookUrl
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(bookUrl)
    }
}

// MARK: - 搜索结果

struct SearchBook: Codable, Identifiable, Hashable {
    var bookUrl: String = ""
    var origin: String = ""
    var originName: String = ""
    var type: Int = BookType.text
    var name: String = ""
    var author: String = ""
    var kind: String?
    var coverUrl: String?
    var intro: String?
    var wordCount: String?
    var latestChapterTitle: String?
    var tocUrl: String = ""
    var time: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var variable: String?
    var originOrder: Int = 0
    var chapterWordCountText: String?
    var chapterWordCount: Int = -1
    var respondTime: Int = -1

    // 运行期字段（不入库，对齐上游 @Ignore）
    var infoHtml: String?
    var tocHtml: String?

    var id: String { bookUrl }
    static let databaseTableName = "searchBooks"

    init() {}

    var variableMap: [String: String] {
        get { JSONTool.parseObject(variable)?.compactMapValues { JSONTool.stringify($0) } ?? [:] }
        set { variable = JSONTool.stringify(newValue) }
    }

    func toBook() -> Book {
        var book = Book()
        book.bookUrl = bookUrl
        book.origin = origin
        book.originName = originName
        book.name = name
        book.author = author
        book.kind = kind
        book.coverUrl = coverUrl
        book.intro = intro
        book.wordCount = wordCount
        book.latestChapterTitle = latestChapterTitle
        book.tocUrl = tocUrl
        book.variable = variable
        book.originOrder = originOrder
        book.type = type
        book.listIntro = intro
        book.infoHtml = infoHtml
        book.tocHtml = tocHtml
        return book
    }

    static func == (lhs: SearchBook, rhs: SearchBook) -> Bool { lhs.bookUrl == rhs.bookUrl }
    func hash(into hasher: inout Hasher) { hasher.combine(bookUrl) }
}

// MARK: - Cookie

struct Cookie: Codable, Identifiable, Hashable {
    var url: String = ""
    var cookie: String = ""

    var id: String { url }
    static let databaseTableName = "cookies"
}

// MARK: - 分组

struct BookGroup: Codable, Identifiable, Hashable {
    var groupId: Int64 = 1
    var groupName: String = ""
    var cover: String?
    var order: Int = 0
    var enableRefresh: Bool = true
    var show: Bool = true
    /// 分组内的书籍排序方式，-1 表示沿用默认
    var bookSort: Int = -1
    var isPrivate: Bool = false

    var id: Int64 { groupId }
    static let databaseTableName = "book_groups"

    static let allGroupId: Int64 = -1
    static let localTag = "loc_book"

    /// 与上游 BookGroup.IdXxx 常量对齐
    enum BuiltinId {
        static let root: Int64 = -100
        static let all: Int64 = -1
        static let local: Int64 = -2
        static let audio: Int64 = -3
        static let netNone: Int64 = -4
        static let localNone: Int64 = -5
        static let manga: Int64 = -7
        static let text: Int64 = -8
        static let error: Int64 = -11
        static let reading: Int64 = -20
        static let unread: Int64 = -21
        static let readFinished: Int64 = -22
        static let readFinishedUpdate: Int64 = -23
        static let readFinishedComplete: Int64 = -24
    }

    func realBookSort(default defaultBookSort: Int) -> Int {
        bookSort < 0 ? defaultBookSort : bookSort
    }
}

// MARK: - 阅读记录

/// 对齐上游 `readRecord/ReadRecord.kt`：表名 `readRecord`，主键 (deviceId, bookName, bookAuthor)
struct ReadRecord: Codable, Hashable {
    var deviceId: String = ""
    var bookName: String = ""
    var bookAuthor: String = ""
    var readTime: Int64 = 0
    var lastRead: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    var id: String { "\(deviceId)|\(bookName)|\(bookAuthor)" }
    static let databaseTableName = "readRecord"
}

// MARK: - 书籍类型

enum BookType {
    static let localTag = "loc_book"
    static let text = 0
    static let audio = 1
    static let image = 2
    static let file = 3
    static let video = 4
}
