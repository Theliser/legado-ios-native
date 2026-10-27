# Legado iOS —— 复刻计划

上游：`HapeLee/legado-with-MD3`（Android / Kotlin，约 2175 个 `.kt`）
目标：iOS 原生 App（SwiftUI + iOS 26 液态玻璃），**数据层与解析层与上游一比一**，UI 按 iOS 习惯重做。

---

## 0. 复刻原则

| 原则 | 说明 |
| --- | --- |
| 规则语义一致 | 书源 JSON 字段名、规则语法、优先级、边界行为必须与上游逐条对齐，否则老书源不可用 |
| 数据可互换 | 表名/字段名沿用上游（`book_sources` / `books` / `chapters` / `cookies` …），便于导入上游备份与书源 JSON |
| 平台差异显式化 | Rhino→JavaScriptCore、OkHttp→URLSession、WebView(Android)→WKWebView、Room→GRDB，差异点集中封装，不污染业务层 |
| 先引擎后界面 | 书源可用性 > UI 完成度；每步都能跑测试或真机验证 |

### 平台替换对照

| 上游 | iOS 实现 | 风险 |
| --- | --- | --- |
| Jsoup（CSS/HTML） | SwiftSoup（API 近乎同名：`select`/`text`/`ownText`/`attr`/`outerHtml`） | 低 |
| JXDocument（XPath） | 直接调用系统 libxml2（XPath 1.0 全量）+ C 桥接 | 中（需 modulemap / bridging header） |
| Jayway JsonPath | 自研 JSONPath 引擎（`$` `.key` `['k']` `[n]` `[*]` `..` 切片/并集/过滤） | 中 |
| Rhino + Java 互操作 | JavaScriptCore + `JSExport` 桥（`java` / `cookie` / `cache` / `source` / `book`） | 中高 |
| OkHttp + CookieJar | URLSession + 自定义 Cookie 存储（不走 HTTPCookieStorage 作为唯一真源） | 中 |
| Android WebView | WKWebView（隐藏视图，支持 `useWebView` / `webJs` / `sourceRegex`） | 高（Cloudflare 相关细节） |
| Room | GRDB（SQLite），表结构手写迁移 | 低 |
| 协程 Flow | Swift Concurrency（async/await + AsyncStream） | 低 |

---

## 1. 必须一比一保留的细节（已核对源码）

1. **规则切分**（`AnalyzeRule.splitSourceRule`）
   - `@js:` / `<js></js>` 先切成 `Mode.Js`；`@webjs:` 切 `Mode.WebJs`。
   - `SourceRule` 内再处理：`@CSS:` → Default、`@@` 去前缀 → Default、`@XPath:`、`@Json:`、以 `$./$[` 开头 → Json、以 `/` 开头 → XPath、含 `##` 或 `{{}}`/`@get:` → Regex。
   - `@put:{...}` 先剥离并立即求值写入变量表；`{{expr}}`、`@get:{key}`、`$1..$99` 逆序回填；`##replace##replacement##first` 拆成替换规则。
   - `isJSON`（内容整体是 JSON）时默认走 Json 模式。
2. **取值语义**（`getString` / `getStringList`）
   - 字符串结果按 `\n` 拆列表；`isUrl` 时逐项 `absoluteURL` 去重，空串回退 `baseUrl`。
   - `getString` 默认 `unescapeHtml4`（`&amp;` 等），`getStringList` 不做反转义。
   - Jsoup 取文本：`text` 用 `element.text()`（含子节点），`ownText` 仅自身文本，`textNodes` 仅直接文本节点，`html` 去 script/style 后 `outerHtml`，`all` 原样 `outerHtml`，其他按属性名取值并去重。
3. **CSS 扩展语法**（`AnalyzeByJSoup.ElementsSingle`）
   - 支持 `tag.div.0`、`class.xx`、`id.xx`、`children`、`text.xx`；
   - 索引写法 `[-1, 3:-2:-10, 2]`、`!` 排除、`:` 多索引、负索引、区间步长（负步长跨列表反向）。
   - `&&`（并集）、`||`（短路取首个非空）、`%%`（交叉合并）三种组合。
4. **URL 规则**（`AnalyzeUrl`）
   - `url,{json}` 以 **首个 `,` 后紧跟 `{`** 分割，JSON 容错解析（严格失败后宽松）。
   - `<1,2,3>` 分页占位；`{{js}}` 与 `@js:` 在 URL 中先执行。
   - `charset`（含 `escape` 走 `escape()` 编码）；query 已编码则不重复编码；form 同理。
   - option 支持 `method/headers/body/type/charset/retry/webView/webJs/dnsIp/js/bodyJs/webViewDelayTime`。
5. **Cookie**（`CookieStore` + `CookieManager`）
   - 以 **二级域名**（eTLD+1，IP 直用）为 key，两级存储：持久 cookie 入 DB，会话 cookie 入内存；读取时 DB 覆盖合并会话。
   - `Cookie` 长度 > 4096 时随机剔除键直到合规。
   - 请求头合并优先级：`urlOption` 临时 cookie **低于** 已存 cookie（已存覆盖请求头）。
   - 书源 `enabledCookieJar=true` 时请求带 `CookieJar: 1`，响应 cookie 由网络层自动回写；访问结束立刻落库（`saveCookie`）。
   - WebView 侧：页面加载后把 WebView cookie 落库；发请求前把库里的 cookie 注入 WebView，**UA 与请求 UA 必须一致**（`cf_clearance` 绑定 UA）。
6. **WebBook 链路**
   - 搜索/发现：详情页正则命中则直接按详情页解析单个结果；列表为空且无 `bookUrlPattern` 时同样按详情页兜底。
   - 目录：`nextTocUrl` 单个串行翻页、多个并发；章节先去重再按 `reverse/` 与书籍 `reverseToc` 双重反转；`formatJs` 逐章重命名（`index`/`chapter`/`title`）。
   - 正文：`nextContentUrl` 单串行/多并发；`nextChapterUrl` 相同则停止；`subContent`；`replaceRegex` 全文替换后每行补两个全角空格；`imageDecode`/`sourceRegex`/`webJs`。
   - 每步都有 `loginCheckJs` 钩子（命中后结果需为 `StrResponse`）。
7. **重定向检测**：WebView 被重定向时构造 302 priorResponse，`searchBook` 里据此判断 `bookUrl` 用重定向后地址。

---

## 2. 目录结构（iOS）

```
legado/
├── project.yml                  # XcodeGen
├── PLAN.md / README.md
├── Legado/
│   ├── App/                     # 入口、AppContainer(DI)、根导航
│   ├── Core/                    # 扩展、日志、编码、HTML 工具、XML(libxml2)、MVI 基座
│   ├── Data/
│   │   ├── Models/              # BookSource(+5 类规则)、Book、BookChapter、SearchBook、Cookie…
│   │   ├── DB/                  # Database、Migrations、DAO
│   │   └── Repos/               # BookSourceRepo、BookRepo、CookieRepo
│   ├── Source/
│   │   ├── Rule/                # RuleAnalyzer、SourceRule、AnalyzeRule、JSoup/XPath/JsonPath/Regex
│   │   ├── Net/                 # AnalyzeUrl、HTTPClient、CookieStore、WebViewFetcher、StrResponse
│   │   ├── JS/                  # JSRuntime、java/cookie/cache 桥
│   │   └── WebBook/             # WebBook、BookList、BookInfo、BookChapterList、BookContent
│   ├── Features/                # Bookshelf / Search / Source / Reader / Debug（各自 Intent+State+VM+View）
│   └── UI/                      # 液态玻璃组件、主题
└── LegadoTests/                 # 规则引擎单测 + 抓取的 HTML 固定样本
```

---

## 3. 阶段计划

### P0 工程地基 ✅
- `git init`，XcodeGen 工程，SwiftSoup / GRDB，libxml2 桥接；iOS 26 + 液态玻璃可运行空壳。
- 依赖改为「镜像下源码 → 本地编译 → XCFramework → 主工程静态链接」，构建不再依赖网络，也不走 SPM 依赖解析。细节见 README。
- 验收：`xcodebuild ... -sdk iphonesimulator build` 通过，模拟器可启动并渲染书架页。

### P1 数据层 ✅
- 实体：`BookSource` + 六个规则结构体，与上游 Kotlin `data class` **逐字段**比对通过（脚本化 diff，含顺序）。
  `Book`/`BookChapter`/`SearchBook` 的 35/18/18 列与上游 Room 实体全等。
- DAO 覆盖：书源（搜索/分组整词/无分组/启停/排序）、书籍（notShelf 位/分组/类型位/私密）、
  章节（按 index 批量、整表替换）、搜索结果（换源候选/过期清理）、阅读记录（复合主键/时长累加）、分组（删除清位）。
- `Book.type` 已按上游还原为**位掩码**（text=8、audio=32、image=64、webFile=128、local=256…）。
- 导入导出：单条 / 数组 / 字符串化规则 / 冲突更新 / 非法载荷。
- 验收：55 个测试全绿，覆盖 DAO 行为与导入导出往返。

### P2 规则引擎（核心）🚧 主链路通，边界待补
- 已实现：`RuleAnalyzer`（平衡组 `splitRule` / `innerRule`）、`AnalyzeRule` + `SourceRule`
  （模式分发、`@put/@get/{{}}/##`、变量表）、`AnalyzeByJSoup`（含索引语法）、`AnalyzeByXPath`
  （libxml2）、`AnalyzeByJSONPath`、`AnalyzeByRegex`。
- 书源解析链路：搜索/发现 → 详情 → 目录 → 正文，全部可用固定 HTML 脱网跑通（端到端用例）。
- 单测覆盖：模式前缀识别、`<js>` 块、CSS 索引 `[1:2]/.-1/!0`、`&&`/`||`、
  JSONPath 通配与过滤、XPath、`##` 替换、`@put/@get`、URL 分页与 `url,{json}` 选项、
  目录去重排序、正文替换与全角缩进、空内容抛错。
- 已修缺陷：`##` 替换被截断、`<js>` 捕获组越界崩溃、括号索引错位、JSONPath 多结果未合并。
- 待补：`%%` 交叉合并的用例、`@webjs`、`$1..$99` 回填、`@put` 非规范 JSON 兜底、
  `relatedBooks`、`imageStyle`/`imageDecode`/`callBackJs`。

### P3 网络与 Cookie
- `AnalyzeUrl` 全量（编码、分页、option、`bodyJs`、重试）。
- `HTTPClient`（URLSession，压缩、字符集探测、超时、代理字段忽略策略）。
- `CookieStore/CookieManager` 两级持久化；`WebViewFetcher`（WKWebView 隐藏实例、JS 求值、`sourceRegex` 嗅探、cookie 双向同步、UA 对齐、Cloudflare 通过后 `cf_clearance` 落库复用）。
- 验收：过 CF 的站点首次用 WebView，二次纯 HTTP 直接 200；杀掉 App 冷启动仍 200。

### P4 业务链路
- `WebBook` + `BookList/BookInfo/BookChapterList/BookContent`；JS 桥（`java.ajax`、`java.base64*`、`cookie.getCookie`、`cache`、`source.*`、`book.*`）。
- 并发限速（`concurrentRate`）、重试、错误分类（超时/空目录/空正文）。
- 验收：对 3~5 个真实书源跑通「搜索→详情→目录→正文」。

### P5 UI（液态玻璃 + MVI）
- 书架（封面网格、分组）、搜索（多源并发聚合）、书源管理（导入/分组/启用/校验）、阅读器（分页/滚动、字号字体、进度）、书源调试（规则逐项回显 + 原文/解析对比）。
- 所有页面：`Intent → ViewModel → State → View`，副作用单向。

### P6 打磨
- 离线缓存、TTS 朗读、换源、备份恢复、iCloud 同步、iPad 适配、无障碍、性能（大目录虚拟化）。

---

## 4. 构建与依赖

依赖不走 SwiftPM 远程解析，改为本地预编译：

```bash
./scripts/fetch-vendor.sh              # 镜像拉源码到 Vendor/
./scripts/build-vendor-frameworks.sh   # 交叉编译成 XCFramework
xcodegen generate && xcodebuild ...    # 构建
```

原因与镜像列表见 [README.md](README.md)。两条硬约束要记住：

- 镜像地址在 `fetch-vendor.sh` 的 `MIRRORS` 数组里改；
- 工程全局带 `-Xfrontend -disable-sandbox`，否则宏插件（`@Observable` / `@State`）无法展开。

## 5. 风险与对策

| 风险 | 对策 |
| --- | --- |
| Cloudflare/JS 挑战页 | WKWebView 兜底 + 真实 UA + cookie 持久化；必要时注入 `webJs` 等待挑战完成；保留「手动过验证」入口复用同一 WKWebsiteDataStore |
| 规则里的 Rhino 特性（Java 类调用） | 先覆盖 `java.*` 常用方法；无法映射的调用记日志并在调试页高亮，逐步补齐 |
| JSONPath 方言差异 | 以 jayway 行为为基准补测试用例；仅实现书源常见子集并显式报错 |
| 单测无法覆盖长尾书源 | 建立「书源可用性巡检」：批量对 Top N 书源跑搜索+首章，统计成功率 |
