#!/usr/bin/env bash
# 把 Vendor/ 下的源码包预编译成 XCFramework（device + simulator）。
#
# 为什么要这么绕：本机环境下 xcodebuild / SwiftPM 编译 Package.swift 清单时
# 会调用 sandbox-exec，返回 "sandbox_apply: Operation not permitted"，导致
# xcodebuild 无法解析任何 SPM 依赖。`swift build --disable-sandbox` 不受影响，
# 因此这里用 SwiftPM 命令行交叉编译出静态库 + .swiftmodule，再手工组装成
# XCFramework，主工程直接链接二进制，完全不碰依赖解析。
#
# 用法：
#   ./scripts/build-vendor-frameworks.sh          # 缺什么编译什么
#   ./scripts/build-vendor-frameworks.sh --force  # 全部重编
#
# 前置：先跑 ./scripts/fetch-vendor.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VENDOR="$ROOT/Vendor"
OUT="$VENDOR/Frameworks"
STAGE="$ROOT/build/VendorStage"
FORCE="${1:-}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-26.0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# 目录名|模块名（也是 lib<模块名>.a 的名字）
PKGS=("SwiftSoup|SwiftSoup" "GRDB.swift|GRDB")

# 编译单个 target 切片，产物拷到 stage 目录
build_slice() {
  local dir="$1" module="$2" triple="$3" sdk="$4" stage="$5"
  local sdkpath
  sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  mkdir -p "$stage"

  ( cd "$VENDOR/$dir" && swift build -c release --disable-sandbox \
      --triple "$triple" --sdk "$sdkpath" \
      -Xswiftc -enable-library-evolution ) > "$stage/build.log" 2>&1 \
    || { tail -40 "$stage/build.log"; die "$module ($triple) 编译失败"; }

  local binpath
  binpath="$(cd "$VENDOR/$dir" && swift build -c release --disable-sandbox \
      --triple "$triple" --sdk "$sdkpath" --show-bin-path 2>/dev/null | tail -1)"
  log "  bin: $binpath"

  # 不同 SwiftPM 版本的产物目录不一致，直接找「本次刚构建出来」的静态库：
  # 当前 slice 的产物 mtime 最新，之前的 slice 不会抢占。
  local lib
  lib="$(find "$VENDOR/$dir/.build" -type f -name "lib$module.a" -print0 2>/dev/null \
      | xargs -0 ls -t 2>/dev/null | head -1)"
  [[ -n "$lib" ]] || lib="$(find "$binpath" -type f -name "lib$module.a" 2>/dev/null | head -1)"

  local prod
  if [[ -n "$lib" ]]; then
    prod="$(dirname "$lib")"
    cp "$lib" "$stage/"
  else
    # 新版 SwiftPM（Xcode 26.6+）只留 .o，不再自动产出 .a，这里手工归档。
    # 产物目录里的所有 .o 都属于当前 module / package 的 library target。
    prod="$binpath"
    local objs=()
    while IFS= read -r -d '' obj; do
      objs+=("$obj")
    done < <(find "$prod" -type f -name '*.o' -print0 2>/dev/null)
    [[ ${#objs[@]} -gt 0 ]] || {
      find "$VENDOR/$dir/.build" -maxdepth 5 -type f | head -40 || true
      die "$module ($triple) 未找到 .a 或 .o"
    }
    libtool -static -o "$stage/lib$module.a" "${objs[@]}"
  fi

  rm -rf "$stage/$module.swiftmodule"
  local modsrc="$prod/Modules/$module.swiftmodule"
  if [[ ! -e "$modsrc" ]]; then
    modsrc="$prod/$module.swiftmodule"
  fi
  if [[ ! -e "$modsrc" ]]; then
    modsrc="$(find "$VENDOR/$dir/.build" \( -type d -o -type f \) \
        -name "$module.swiftmodule" -print0 2>/dev/null \
        | xargs -0 ls -td 2>/dev/null | head -1)"
  fi
  if [[ -d "$modsrc" ]]; then
    cp -R "$modsrc" "$stage/$module.swiftmodule"
  else
    # 某些 SwiftPM 版本把 .swiftmodule 输出成单文件
    mkdir -p "$stage/$module.swiftmodule"
    cp "$modsrc" "$stage/$module.swiftmodule/" 2>/dev/null || true
  fi
  # swiftdoc / abi.json 可能和 .swiftmodule 同级，也可能在目录内
  cp "$prod/$module.swiftdoc" "$stage/$module.swiftmodule/" 2>/dev/null || true
  cp "$prod/$module.abi.json" "$stage/$module.swiftmodule/" 2>/dev/null || true
  cp "$prod/Modules/$module.swiftdoc" "$stage/$module.swiftmodule/" 2>/dev/null || true
  cp "$prod/Modules/$module.abi.json" "$stage/$module.swiftmodule/" 2>/dev/null || true
  cp "$(dirname "$modsrc")/$module.swiftdoc" "$stage/$module.swiftmodule/" 2>/dev/null || true
  cp "$(dirname "$modsrc")/$module.abi.json" "$stage/$module.swiftmodule/" 2>/dev/null || true
}

# 生成 <Name>.framework 目录（静态库 + Swift 模块）
make_framework() {
  local module="$1" fatlib="$2" modules_from="$3" dest="$4"
  rm -rf "$dest"
  mkdir -p "$dest/Modules/$module.swiftmodule"
  cp "$fatlib" "$dest/$module"
  cp "$modules_from"/*.swiftmodule "$dest/Modules/$module.swiftmodule/" 2>/dev/null || true
  cp "$modules_from"/*.swiftdoc    "$dest/Modules/$module.swiftmodule/" 2>/dev/null || true
  cp "$modules_from"/*.abi.json    "$dest/Modules/$module.swiftmodule/" 2>/dev/null || true

  cat > "$dest/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$module</string>
  <key>CFBundleIdentifier</key><string>org.swift.$module</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$module</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$DEPLOYMENT_TARGET</string>
</dict>
</plist>
PLIST
}

make_xcframework() {
  local module="$1" dest="$2" dev_fw="$3" sim_fw="$4"
  rm -rf "$dest"
  mkdir -p "$dest/ios-arm64" "$dest/ios-arm64_x86_64-simulator"
  cp -R "$dev_fw" "$dest/ios-arm64/$module.framework"
  cp -R "$sim_fw" "$dest/ios-arm64_x86_64-simulator/$module.framework"

  cat > "$dest/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>LibraryIdentifier</key><string>ios-arm64</string>
      <key>LibraryPath</key><string>$module.framework</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
    </dict>
    <dict>
      <key>LibraryIdentifier</key><string>ios-arm64_x86_64-simulator</string>
      <key>LibraryPath</key><string>$module.framework</string>
      <key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
      <key>SupportedPlatformVariant</key><string>simulator</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST
}

mkdir -p "$OUT"
for entry in "${PKGS[@]}"; do
  IFS='|' read -r dir module <<< "$entry"
  [[ -d "$VENDOR/$dir" ]] || die "缺少 $VENDOR/$dir ，先执行 ./scripts/fetch-vendor.sh"

  xcf="$OUT/$module.xcframework"
  if [[ -d "$xcf" && "$FORCE" != "--force" ]]; then
    log "$module.xcframework 已存在，跳过（--force 可强制重编）"
    continue
  fi

  st="$STAGE/$module"
  rm -rf "$st"

  log "编译 $module · device arm64"
  build_slice "$dir" "$module" "arm64-apple-ios$DEPLOYMENT_TARGET" iphoneos "$st/dev"

  log "编译 $module · simulator arm64"
  build_slice "$dir" "$module" "arm64-apple-ios$DEPLOYMENT_TARGET-simulator" iphonesimulator "$st/sim-arm64"

  log "编译 $module · simulator x86_64"
  build_slice "$dir" "$module" "x86_64-apple-ios$DEPLOYMENT_TARGET-simulator" iphonesimulator "$st/sim-x86_64"

  # 两个模拟器切片合成胖库
  lipo -create "$st/sim-arm64/lib$module.a" "$st/sim-x86_64/lib$module.a" \
    -output "$st/lib$module-sim.a" > /dev/null

  # 模拟器模块目录合并两个架构的 .swiftmodule
  mkdir -p "$st/sim-modules"
  cp "$st/sim-arm64/$module.swiftmodule/"*.swiftmodule "$st/sim-modules/" 2>/dev/null || true
  cp "$st/sim-x86_64/$module.swiftmodule/"*.swiftmodule "$st/sim-modules/" 2>/dev/null || true
  cp "$st/sim-arm64/$module.swiftmodule/"*.swiftdoc "$st/sim-modules/" 2>/dev/null || true
  cp "$st/sim-arm64/$module.swiftmodule/"*.abi.json "$st/sim-modules/" 2>/dev/null || true

  make_framework "$module" "$st/dev/lib$module.a" "$st/dev/$module.swiftmodule" "$st/$module-device.framework"
  make_framework "$module" "$st/lib$module-sim.a" "$st/sim-modules" "$st/$module-sim.framework"
  make_xcframework "$module" "$xcf" "$st/$module-device.framework" "$st/$module-sim.framework"

  log "$module.xcframework ✓ $(du -sh "$xcf" | cut -f1)"
done

log "二进制依赖就绪："
ls -1 "$OUT"
