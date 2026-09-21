#!/bin/bash
# ============================================================
#  LidMate 构建脚本
#
#  产出：dist/LidMate.app  和  dist/LidMate.dmg
#  用法：bash build.sh
#
#  依赖：Xcode Command Line Tools（swiftc / iconutil / hdiutil / codesign）
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/LidMate.app"
CONTENTS="$APP/Contents"
CACHE="$ROOT/.modulecache"

echo "==> 清理"
rm -rf "$DIST"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/bin" "$CACHE"

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
ICON_PNG="$DIST/icon.png"
swiftc -O -swift-version 5 -module-cache-path "$CACHE" \
  -o "$DIST/makeicon" "$ROOT/tools/makeicon.swift" -framework Cocoa
"$DIST/makeicon" "$ICON_PNG" >/dev/null

ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$ICON_PNG" "$DIST/makeicon"

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (签名跳过，不影响本机使用)"

echo "==> 打包 DMG"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "LidMate" -srcfolder "$STAGE" -ov -format UDZO "$DIST/LidMate.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "✅ 构建完成"
echo "   App : $APP"
echo "   DMG : $DIST/LidMate.dmg"
du -sh "$DIST/LidMate.dmg" | awk '{print "   体积: "$1}'
