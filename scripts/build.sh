#!/usr/bin/env bash
# 构建 iOS App。
#
# 依赖通过 SwiftPM 从 GitHub 拉取（见 project.yml 的 packages），
# 不再本地预编译 XCFramework。
#
#   ./scripts/build.sh                 # 模拟器包（直连）
#   ./scripts/build.sh --proxy         # 走本机 127.0.0.1:10808 代理
#   ./scripts/build.sh --ipa           # 额外产出未签名设备 IPA
#   LEGADO_PROXY=1 ./scripts/build.sh  # 同上
#
# 代理会同时传给 git / SwiftPM 子进程（GIT_CONFIG_* + HTTP(S)_PROXY）。
set -euo pipefail
cd "$(dirname "$0")/.."

PROXY_URL="${LEGADO_PROXY_URL:-http://127.0.0.1:10808}"
USE_PROXY="${LEGADO_PROXY:-0}"
BUILD_IPA=0

for arg in "$@"; do
  case "$arg" in
    --proxy) USE_PROXY=1 ;;
    --no-proxy) USE_PROXY=0 ;;
    --ipa) BUILD_IPA=1 ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$USE_PROXY" == "1" ]]; then
  export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
  # SwiftPM 内部调用 git，用 GIT_CONFIG_* 给这次进程树设置代理，不污染全局配置
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=http.proxy
  export GIT_CONFIG_VALUE_0="$PROXY_URL"
  echo "▶︎ 使用代理 $PROXY_URL"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 xcodegen，先执行：brew install xcodegen" >&2
  exit 1
fi

xcodegen generate

echo "▶︎ 解析 SwiftPM 依赖"
xcodebuild -resolvePackageDependencies \
  -project Legado.xcodeproj \
  -scheme Legado \
  -clonedSourcePackagesDirPath build/SourcePackages

echo "▶︎ 构建（iOS Simulator）"
xcodebuild \
  -project Legado.xcodeproj \
  -scheme Legado \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ "$BUILD_IPA" == "1" ]]; then
  echo "▶︎ 构建（iOS Device，Release，未签名）"
  xcodebuild \
    -project Legado.xcodeproj \
    -scheme Legado \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedDataDevice \
    -clonedSourcePackagesDirPath build/SourcePackages \
    CODE_SIGNING_ALLOWED=NO \
    build

  APP="build/DerivedDataDevice/Build/Products/Release-iphoneos/Legado.app"
  [[ -d "$APP" ]] || { echo "设备构建产物不存在：$APP" >&2; exit 1; }

  echo "▶︎ 打包 IPA（Payload/Legado.app）"
  rm -rf build/ipa
  mkdir -p build/ipa/Payload build/artifacts
  cp -R "$APP" build/ipa/Payload/
  ( cd build/ipa && ditto -c -k --norsrc --keepParent Payload \
      ../artifacts/Legado-unsigned.ipa )
  echo "✓ build/artifacts/Legado-unsigned.ipa"
fi
