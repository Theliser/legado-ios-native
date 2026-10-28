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

### P2 规则引擎（核心）✅
- 已实现：`RuleAnalyzer`（平衡组 `splitRule` / `innerRule`）、`AnalyzeRule` + `SourceRule`
  （模式分发、`@put/@get/{{}}/##`、变量表）、`AnalyzeByJSoup`（含索引语法）、`AnalyzeByXPath`
  （libxml2）、`AnalyzeByJSONPath`、`AnalyzeByRegex`。
- 书源解析链路：搜索/发现 → 详情 → 目录 → 正文，全部可用固定 HTML 脱网跑通（端到端用例）。
- 单测覆盖：模式前缀识别、`<js>` 块、CSS 索引 `[1:2]/.-1/!0`、`&&`/`||`、
  JSONPath 通配与过滤、XPath、`##` 替换、`@put/@get`、URL 分页与 `url,{json}` 选项、
  目录去重排序、正文替换与全角缩进、空内容抛错。
- 已修缺陷：`##` 替换被截断、`<js>` 捕获组越界崩溃、括号索引错位、JSONPath 多结果未合并。
- **关联书籍 `relatedBooks`**：按 `key/title/url` 定义逐个请求发现页，过滤当前书籍，
  单模块失败不影响其他模块（`RelatedBooks.swift`）。
- **正文扩展**：`imageStyle` 落入书籍配置（阅读时生效）；`imageDecode` / `coverDecodeJs`
  走字节级 JS 解密（`fetchImageData` 已接入）；`callBackJs` 支持 `event/result/book/chapter`
  上下文，并接入加书架/移出书架/开始阅读事件。
- **`@put` 非规范 JSON**：键、值都不带引号（`{name:.title@text}`）也能解析，对齐 GSON 宽松模式。
- 验收：134 个单测全绿（含 6 个真实源离线回放基准）。

### P3 网络与 Cookie ✅（代码与单测完成，待真实站点验证）
- `AnalyzeUrl` 全量：编码、`<1,2,3>` 分页、option（method/headers/body/type/charset/retry/
  webView/webJs/bodyJs/dnsIp/js/webViewDelayTime）、`url,{json}` 容错。
- `HTTPClient`：字符集探测（响应头 → 页面 meta → UTF-8）、XML 补声明、`Set-Cookie`
  合并串拆分（保住 `Expires` 里的逗号）、重定向标记、重试、自签证书放行。
- `CookieStore`：二级域名 key、持久 + 会话两级、合并语义、超 4096 随机裁剪、
  WebView cookie 全量落库（`cf_clearance` 即在其中）。
- `WebViewFetcher`：隐藏 WKWebView、UA 与请求一致（否则 `cf_clearance` 失效）、
  载入前注入已存 cookie、加载后落库、`sourceRegex` 嗅探、delay、重定向标记。
- 已修缺陷：URL 整串 `addingPercentEncoding` 会把已编码的 `%E5` 变成 `%25E5`（书源带中文参数的地址必然 404）。
- 待做：代理、`dnsIp` 强制解析、真实 CF 站点端到端验证（需要 403 类站点，本机网络下多数不可达）。

### P4 业务链路 ✅（主链路与 JS 桥完成）
- `WebBook` + `BookList/BookInfo/BookChapterList/BookContent`，含规则回退、
  文件型书源走下载、目录去重排序、正文分页（单页串行 / 多页并发 4 路）。
- `ConcurrentRateLimiter`：`n/ms` 与单数字两种写法，按书源 key 全局共享计数，
  超限等待而不是直接失败；参数更新保留已有计数。
- 错误分类：超时 / 域名 / 连接 / SSL / 其它，用负数 callTime 编码供调试页展示。
- **JS 桥补全**（`java.*` 常用面）：
  - 网络：`ajax/ajaxAll/ajaxTestAll/get/post/head/connect`，含 headers、body、timeout；
  - 响应：`body/url/code/statusCode/statusMessage/header/headers/cookies/toString`；
  - 编码：base64（含 charset）、hex、md5、`encodeURI(charset)`、`timeFormatUTC`、
    `strToBytes/bytesToStr`（JS 字节数组与 Swift Data 互转）；
  - 规则与变量：`getString/getStringList/getElement/getElements`（Element 支持
    `text/ownText/html/outerHtml/attr/select`）、`put/getFromCache`、`cookie.*`、`cache.*`；
  - `source.*`：`get/put/getVariable/getLoginInfo/getHeaderMap` 等；
  - 文件：`importScript/cacheFile/downloadFile/readTxtFile/readFile/deleteFile`；
  - WebView：`webView/webViewGetSource/webViewGetOverrideUrl`（隐藏 WKWebView）；
  - 仍不支持：`Packages.java.*` 原生类、TTF 字体替换、zip/rar/7z 解压，
    `startBrowser*` 手动过验证（iOS 端只记日志）。
- **`mainJs` 纯 JS 单文件书源**（`JsSource.swift`）：`search/explore/getBookInfo/getChapters/getContent`
  全部打通；每次调用独立 JS 作用域，函数内可用 `java.ajax` 等桥接能力。
- **章节缓存**：阅读先查 `ChapterCache`，命中直接渲染；下载流程同步落盘、可整本清除。
- **整本下载**：`BookDownloader` 并发抓取、失败章节隔离、进度回调、默认跳过已有缓存、
  `force` 强制重抓；详情页已接入「缓存全本」按钮。
- **真实站点验证已做**：只收最近批次的书源（老源规则基本随站点改版失效）。
  笔趣阁（bqquge，规则 2025-11 版）跑通 搜索 2 条 → 详情「剑来完整版」→ 目录 1278 章 →
  正文 522 字；另一条 2025-11 的趣书吧走 `bodyJs` + `java.post` 取 token，搜索无结果
  （当时 JS 桥未实现 `java.post`，现已补齐，可用 `JSBridgeTests` 回放验证）。
  联网用例默认 skip（`TEST_RUNNER_RUN_LIVE_TESTS=1` 才跑），硬断言只要求「至少一个最近源全通」。
- **阅读源仓库（yckceo）最近批次体检**：抓 1 小时内～5 天前的新源做全链路。
  最近 12 个里 2 个完整通过（错层网、笔趣阁），其余多为站点改版/搜索接口失效。
  顺带修了真实源暴露的 4 个兼容问题：
  1. jsLib 里 Rhino 允许的 `let` 参数重声明会让 JSC 整个脚本语法失败 → 失败后按宽松模式重试；
  2. `loginCheckJs` 的 `result` 必须是响应对象（`result.body()`），之前传的是 Swift 结构体；
  3. `body` 写成对象且声明 `application/x-www-form-urlencoded` 时要发 form，不能发 JSON；
  4. 含中文的 URL 先百分号编码再交给 URLSession，并关闭 HTTP/3（模拟器 QUIC 上会卡到超时）。
- **阶段追踪**：`SourceTrace`（URL / 状态码 / 耗时 / 原始响应 / 错误）在搜索、详情、目录、正文
  四个阶段完成时回调；"详情页即目录页"这类复用响应的路径也会发 trace（标注「复用详情页响应」）。

### P5 UI（液态玻璃 + MVI）🚧 书源侧已成体系
- 已做：书架（封面网格、分组）、搜索（多源并发聚合）、书源管理（导入/分组/启用）、
  阅读器（分页/滚动、字号字体、进度）、设置。
- **书源调试页**：关键字 + 一键全链路；四个阶段可单独重跑；每阶段展开可看 URL、
  状态码、耗时、失败原因与原始响应（可复制）；目录列出章节，点一条即填入正文调试；
  底部解析日志按 `┌/└/◇/≡` 协议展示并可整段复制。
- **书源巡检页**：可配关键字 / 超时 / 校验项 / 并发；结果按 通过 / 失败 / 无法校验 筛，
  展开看各阶段耗时；结论写回书源（`respondTime` + 失效分组，通过时清空旧分组）。
- 所有页面：`Intent → ViewModel → State → View`，副作用单向。

### P6 打磨
- 离线缓存、TTS 朗读、换源、备份恢复、iCloud 同步、iPad 适配、无障碍、性能（大目录虚拟化）。

---

## 4. 构建与依赖

依赖用 SwiftPM 从 GitHub 以 git 协议拉取，版本在 `project.yml` 里锁死：

```bash
./scripts/build.sh            # 模拟器构建（直连）
./scripts/build.sh --proxy    # 走 127.0.0.1:10808 代理
./scripts/build.sh --ipa      # 额外产出未签名设备 IPA
```

脚本内部是 `xcodegen generate` → `xcodebuild -resolvePackageDependencies` → 构建，
包缓存放在 `build/SourcePackages`。CI（GitHub Actions、macos-26）跑同一脚本。

两条硬约束：

- 代理只影响 SwiftPM/git 拉依赖：`LEGADO_PROXY_URL` 可改端口；
- 工程全局带 `-Xfrontend -disable-sandbox`，否则宏插件（`@Observable` / `@State`）无法展开。

## 5. 风险与对策

| 风险 | 对策 |
| --- | --- |
| Cloudflare/JS 挑战页 | WKWebView 兜底 + 真实 UA + cookie 持久化；必要时注入 `webJs` 等待挑战完成；保留「手动过验证」入口复用同一 WKWebsiteDataStore |
| 规则里的 Rhino 特性（Java 类调用） | 先覆盖 `java.*` 常用方法；无法映射的调用记日志并在调试页高亮，逐步补齐 |
| JSONPath 方言差异 | 以 jayway 行为为基准补测试用例；仅实现书源常见子集并显式报错 |
| 单测无法覆盖长尾书源 | 建立「书源可用性巡检」：批量对 Top N 书源跑搜索+首章，统计成功率 |
