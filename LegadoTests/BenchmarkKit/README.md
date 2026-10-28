# 书源基准测试

目标：**改书源相关代码时，立刻知道有没有把真实书源改坏。**

## 为什么分两层

| 层 | 跑什么 | 什么时候跑 | 能发现什么 |
|---|---|---|---|
| 离线回放 | 录好的真实响应 | 每次改 `Legado/Source/**`（pre-commit 自动） | **引擎回归**：规则解析、选择器、编码、分页、目录排序… |
| 联网体检 | 真连站点 | 定时（每周）/ 手动 | **源腐烂**：站点改版导致规则失效 |

只做联网会很不稳定（网络抖动、CF 拦截、站点临时故障），只做回放又发现不了「站点变了」。
两层各管一段，才既能当 CI 门禁，又能当运维工具。

## 目录

```
LegadoTests/BenchmarkKit/
  BenchmarkModels.swift    夹具模型 + 回放器 + 录制器
  BenchmarkRunner.swift    搜索→详情→目录→正文，产出可比较指标
  fixtures/                语料：每个源一个 bench_<host>.json（入库）
  pool/                    候选池：抓下来还没验证的源（不入库）
LegadoTests/SourceBenchmarkTests.swift
scripts/harvest-benchmark-sources.py
scripts/bench.sh
.githooks/pre-commit
```

## 用法

```bash
# 离线回放（日常 / 提交前）
./scripts/bench.sh

# 联网体检：看哪些源已经腐烂
./scripts/bench.sh --live
BENCH_PROXY=http://127.0.0.1:10808 ./scripts/bench.sh --live   # 需要代理时

# 刷新语料：先抓最新的候选源，再真跑一遍、通过的才入库
./scripts/bench.sh --harvest
./scripts/bench.sh --record

# 只补某个站点
BENCH_ONLY=bqquge ./scripts/bench.sh --record
```

## 语料怎么维护

1. `--harvest` 从 [yckceo 书源站](https://www.yckceo.com/yuedu/shuyuan/index.html) 取**最新**数据。
   老书源的规则大多已随站点改版失效，收进来只会制造假红。
2. 过滤掉：非文本源、成人内容、需要 WebView/登录态的源、host 不合法的源。
3. `--record` 真跑「搜索→详情→目录→正文」，**只有跑通的才写夹具**，
   期望值取实际结果的 50%（够抓住「塌成 0」，又不至于因站点改标题就红）。
4. 夹具里存的是**完整响应**，所以回放不需要网络，也不需要站点还活着。

## 断言策略

- 回放：每个源都要 **搜索有结果 / 目录 ≥ 一半 / 正文 ≥ 一半字数**，且**没有未录制的请求**
  （漏录说明引擎发出的请求变了，夹具必须重录）。
- 联网：只要求「不是全军覆没」，失效清单打印出来交给定时任务跟进。
  站点会死，把单个源的失败当红会让人习惯性忽略红。

## 夹具过期

`testCorpusReplay` 会打印超过 45 天未更新的源。这不是失败项 ——
回放本来就该长期稳定；过期只说明「该刷新一遍以覆盖新站点结构」。

## 自动门禁

```bash
./scripts/install-hooks.sh    # 设置 core.hooksPath=.githooks
```

之后只要暂存区里出现 `Legado/Source/**`、`BookSource.swift`、`Book.swift`、
`Legado/Data/DB/**`、`BenchmarkKit/**` 的改动，commit 前会自动跑离线回放，
不通过就拦住。紧急绕过：`SKIP_BENCH=1 git commit ...`。
