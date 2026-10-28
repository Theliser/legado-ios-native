#!/usr/bin/env bash
# 拉取 SPM 依赖到本地 Vendor/，绕开 GitHub 直连。
#
# 用法：
#   ./scripts/fetch-vendor.sh          # 缺什么补什么
#   ./scripts/fetch-vendor.sh --force  # 全部重新下载
#
# 生成的 Vendor/ 目录不纳入 git（见 .gitignore），但 project.yml 以本地
# 路径依赖引用它，所以首次 clone 后需要执行本脚本一次。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VENDOR="$ROOT/Vendor"
FORCE="${1:-}"

# 镜像按顺序尝试，第一个成功的即用；直连兜底放最后。
MIRRORS=(
  "https://ghfast.top/https://github.com"
  "https://gh-proxy.com/https://github.com"
  "https://hk.gh-proxy.com/https://github.com"
  "https://github.com"
)

# CI（GitHub Actions）直连 GitHub 最快，可用 VENDOR_MIRROR 覆盖镜像列表
if [[ -n "${VENDOR_MIRROR:-}" ]]; then
  MIRRORS=("${VENDOR_MIRROR%/}")
fi

# 名称|仓库|tag|顶层目录名
DEPS=(
  "SwiftSoup|scinfu/SwiftSoup|2.14.3|SwiftSoup-2.14.3"
  "GRDB.swift|groue/GRDB.swift|v7.0.0|GRDB.swift-7.0.0"
)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

fetch_one() {
  local name="$1" repo="$2" tag="$3" top="$4"
  local dest="$VENDOR/$name"

  if [[ -d "$dest" && "$FORCE" != "--force" ]]; then
    log "$name 已存在，跳过（--force 可强制重下）"
    return 0
  fi

  mkdir -p "$VENDOR"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local ok=0
  for m in "${MIRRORS[@]}"; do
    local url="$m/$repo/archive/refs/tags/$tag.tar.gz"
    log "尝试 $name @ $tag ← ${m%%/https*}"
    if curl -fsSL --connect-timeout 10 --max-time 600 --retry 2 \
        -o "$tmp/pkg.tar.gz" "$url"; then
      if tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" 2>/dev/null && [[ -d "$tmp/$top" ]]; then
        rm -rf "$dest"
        mv "$tmp/$top" "$dest"
        # 上游自带的 .xcodeproj 会让 xcodebuild 在包目录里分不清该解析哪个工程
        # （报 "contains 2 projects"），这里只按 SwiftPM 包使用，直接清掉。
        rm -rf "$dest"/*.xcodeproj "$dest"/.swiftpm
        ok=1
        break
      fi
    fi
    log "  失败，换下一个镜像"
  done

  [[ "$ok" == 1 ]] || die "$name 全部镜像均失败，请检查网络或手动放置到 Vendor/$name"
  log "$name ✓ $(du -sh "$dest" | cut -f1)"
}

mkdir -p "$VENDOR"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name repo tag top <<< "$entry"
  fetch_one "$name" "$repo" "$tag" "$top"
done

log "依赖就绪："
ls -1 "$VENDOR"
