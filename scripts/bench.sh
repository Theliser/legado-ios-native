#!/usr/bin/env bash
# 书源基准测试入口
#
#   ./scripts/bench.sh            # 离线回放（默认，秒级、不联网）
#   ./scripts/bench.sh --live     # 联网体检，发现「源腐烂」
#   ./scripts/bench.sh --record   # 重新录制语料（先跑 harvest 脚本抓候选）
#   ./scripts/bench.sh --harvest  # 抓最新候选书源到 pool/
#
# 环境变量：
#   BENCH_PROXY=http://127.0.0.1:10808   给模拟器里的请求挂代理
#   BENCH_LIMIT=8                        录制时最多收几个源
#   BENCH_ONLY=example.com               录制时只处理命中的源
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="replay"
case "${1:-}" in
  --live) MODE="live" ;;
  --record) MODE="record" ;;
  --harvest)
    exec /Users/theliser/.workbuddy/binaries/python/versions/3.13.12/bin/python3 \
      scripts/harvest-benchmark-sources.py --count "${BENCH_LIMIT:-10}"
    ;;
  "") ;;
  *) echo "未知参数：$1"; exit 2 ;;
esac

DEST="${BENCH_DEST:-platform=iOS Simulator,name=iPhone 17 Pro}"
DD="${BENCH_DERIVED:-build/DerivedData}"
LOG="build/bench-${MODE}.log"
mkdir -p build

case "$MODE" in
  replay) TEST_ID="LegadoTests/SourceBenchmarkTests/testCorpusReplay" ;;
  live)   TEST_ID="LegadoTests/SourceBenchmarkTests/testLiveDrift" ;;
  record) TEST_ID="LegadoTests/SourceBenchmarkTests/testRecordFromPool" ;;
esac

if [ "$MODE" = "live" ]; then
  export TEST_RUNNER_RUN_LIVE_TESTS=1
elif [ "$MODE" = "record" ]; then
  export TEST_RUNNER_BENCH_RECORD=1
fi
if [ -n "${BENCH_PROXY:-}" ]; then
  export TEST_RUNNER_BENCH_PROXY="$BENCH_PROXY"
fi

echo "▶︎ 书源基准（${MODE}）"
set +e
xcodebuild test -project Legado.xcodeproj -scheme Legado \
  -destination "$DEST" -derivedDataPath "$DD" \
  -only-testing:"${TEST_ID}" > "${LOG}" 2>&1
STATUS=$?
set -e

# 把结果摘出来，别让人去翻 30 万行日志
if grep -q "书源基准" "$LOG"; then
  sed -n '/书源基准/,/^=\{10,\}/p' "$LOG" | head -60
fi
if [ "$STATUS" -ne 0 ]; then
  echo
  echo "✗ 基准未通过。完整日志：${LOG}"
  grep -E "error: -\[|XCTAssert|回放基准失败" "${LOG}" | head -20 || true
  exit "$STATUS"
fi
echo
echo "✓ 基准通过（日志：${LOG}）"
