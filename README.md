# Legado iOS

`HapeLee/legado-with-MD3`（Android / Kotlin）的 iOS 原生复刻版。
**书源规则语义与数据表结构一比一**，UI 按 iOS 习惯重做（SwiftUI + 液态玻璃）。

- 复刻原则、必须保留的细节、阶段计划见 [PLAN.md](PLAN.md)
- 上游源码放在 `upstream/`，仅作对照，不入版本库

## 环境

| 项 | 版本 |
| --- | --- |
| Xcode | 26 及以上（工程部署目标 iOS 26.0） |
| XcodeGen | `brew install xcodegen` |
| 依赖 | SwiftSoup 2.14.3、GRDB 7.0.0（预编译为 XCFramework） |

## 首次构建

```bash
# 1. 拉依赖源码（走镜像，约 15 秒）
./scripts/fetch-vendor.sh

# 2. 编译成 XCFramework（约 3~4 分钟，只有依赖变更时才需要重跑）
./scripts/build-vendor-frameworks.sh

# 3. 生成工程并构建
xcodegen generate
xcodebuild -project Legado.xcodeproj -scheme Legado \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

`Vendor/` 与 `build/` 都不入版本库，换机器首次需要跑前两步。

## 为什么不用 SwiftPM 直接拉 GitHub

两件事叠在一起：

1. **GitHub 直连太慢。** 本机实测 `git clone` 拉 GRDB 十几分钟都下不完（约 30KB/s），
   而走镜像下 tarball 只有 1.1MB，几秒就完。
2. **这台机器上 SPM 解析依赖会失败。** `xcodebuild` / `swift package` 编译
   `Package.swift` 清单时要 fork 一个 `sandbox-exec`，返回
   `sandbox_apply: Operation not permitted`（外层已有沙箱，不允许嵌套）。
   相比之下 `swift build --disable-sandbox` 正常。

所以流程改成：**镜像下 tarball → 本地交叉编译 → 手工组装 XCFramework → 主工程链接二进制**。
主工程完全不参与依赖解析，构建也就顺带离线可用了。

### 换镜像

`scripts/fetch-vendor.sh` 顶部的 `MIRRORS` 数组按顺序尝试，第一个成功的即用：

```bash
MIRRORS=(
  "https://ghfast.top/https://github.com"     # 实测可用，本机首选
  "https://gh-proxy.com/https://github.com"
  "https://hk.gh-proxy.com/https://github.com"
  "https://github.com"                        # 直连兜底
)
```

某个镜像挂了、或者想换更快的，直接改这个数组即可；也可以在命令前临时指定
（脚本读取的是数组，改文件是最直接的方式）。

升级依赖版本：改 `DEPS` 里的 tag 和 `build-vendor-frameworks.sh` 里的 `PKGS`，
然后 `./scripts/fetch-vendor.sh --force && ./scripts/build-vendor-frameworks.sh --force`。

## 关于 `-Xfrontend -disable-sandbox`

工程里全局带了这个 Swift 编译参数。原因同上：编译器展开宏（`@Observable`、
`@State` 这些）要拉起 `swift-plugin-server`，同样被 `sandbox-exec` 挡住，
报 `external macro implementation type ... could not be found`。
关掉编译器子进程沙箱后即可正常展开，对产物没有影响。

换到没有该限制的机器上，这一行可以去掉。

## 真实书源验证

单测全部用固定 HTML 跑，不依赖网络。另外有一组**联网**用例用来验证引擎在真实站点上的表现：

```bash
TEST_RUNNER_RUN_LIVE_TESTS=1 xcodebuild test -project Legado.xcodeproj -scheme Legado \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:LegadoTests/LiveSourceTests
```

默认跳过（不设 `RUN_LIVE_TESTS=1` 就是 skip），避免日常跑测试被网络拖慢。

夹具在 `LegadoTests/LiveSourceFixtures.swift`，来自公开合集 `aoaostar/legado`，
外加一条**按站点当前结构手工校准**的规则。硬断言只压在校准过的那条上——
公开书源会随站点改版失效，不能拿它当引擎正确性的判据。

> 实测记录（2026-10）：合集里 22 个书源有 6 个站点可直连（其余 403/超时），
> 而这 3 个可直连的书源规则**全部已过期**（例如速读谷把列表从 `class.bookbox`
> 改成了 `div.item.clear`）。按新结构重写规则后，搜索→详情→目录（263 章）→正文
> （含分页）全链路跑通。结论：引擎没问题，公开源需要定期维护。

## 目录

```
Legado/
├── App/        入口、AppContainer(DI)、根导航
├── Core/       扩展、日志、编码、HTML 工具、XML(libxml2)、MVI 基座
├── Data/       Models / DB(GRDB) / Repos
├── Source/     Rule 规则引擎、Net 网络与 Cookie、JS 桥、WebBook 业务链路
├── Features/   书架 / 搜索 / 书源 / 阅读 / 设置（各含 Intent+State+VM+View）
└── UI/         液态玻璃组件、主题
scripts/        依赖拉取与预编译脚本
```
