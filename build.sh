#!/bin/bash
# ============================================================
#  LidMate 构建脚本
#
#  产出：dist/LidMate.dmg
#  用法：bash build.sh
#
#  依赖：Xcode Command Line Tools（swiftc / iconutil / hdiutil / codesign）
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/LidMate-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/LidMate.app"
CONTENTS="$APP/Contents"
CACHE="$STAGE/.modulecache"

echo "==> 清理"
rm -rf "$DIST"
mkdir -p "$DIST" "$CONTENTS/MacOS" "$CONTENTS/Resources/bin" "$CACHE"

echo "==> 编译主程序"
swiftc -O -swift-version 5 \
  -module-cache-path "$CACHE" \
  -target "$(uname -m)-apple-macosx13.0" \
  -o "$CONTENTS/MacOS/LidMate" \
  "$ROOT/src/main.swift" \
  -framework Cocoa

echo "==> 拷贝资源"
cp "$ROOT/src/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/src/resources/clamshell.sh"   "$CONTENTS/Resources/"
cp "$ROOT/src/resources/displaysync.sh" "$CONTENTS/Resources/"
cp "$ROOT/tools/selftest.sh"            "$CONTENTS/Resources/"
cp "$ROOT/tools/doctor.sh"              "$CONTENTS/Resources/"
cp "$ROOT/tools/test-profile-guard.sh"  "$CONTENTS/Resources/"
chmod +x "$CONTENTS/Resources/"*.sh

for bin in m1ddc displayplacer; do
  if [ ! -f "$ROOT/vendor/$bin" ]; then
    echo "❌ 缺少 vendor/$bin"
    echo "   请到 vendor/README.md 看获取方式"
    exit 1
  fi
  cp "$ROOT/vendor/$bin" "$CONTENTS/Resources/bin/$bin"
done
chmod +x "$CONTENTS/Resources/bin/"*

echo "==> 生成图标"
ICON_PNG="$STAGE/icon.png"
swiftc -O -swift-version 5 -module-cache-path "$CACHE" \
  -o "$STAGE/makeicon" "$ROOT/tools/makeicon.swift" -framework Cocoa
"$STAGE/makeicon" "$ICON_PNG" >/dev/null

ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$ICON_PNG" "$STAGE/makeicon"

echo "==> ad-hoc 签名"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 打包 DMG"
ln -s /Applications "$STAGE/Applications"
# 打包目录只保留应用和 Applications 快捷方式。
rm -rf "$CACHE"
hdiutil create -volname "LidMate" -srcfolder "$STAGE" -fs HFS+ -ov -format UDZO "$DIST/LidMate.dmg" >/dev/null

echo
echo "✅ 构建完成"
echo "   DMG : $DIST/LidMate.dmg"
du -sh "$DIST/LidMate.dmg" | awk '{print "   体积: "$1}'
