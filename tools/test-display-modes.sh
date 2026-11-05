#!/bin/bash
# 只读：用两种 displayplacer 模式格式验证诊断能找到真实的共同镜像模式。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

EXT=9D03379C-8D55-4E61-AE23-76C0009C03A0
INT=37D8832A-2D66-02CA-B9F7-8F30A301B230

cat > "$T/bin/displayplacer" <<'MOCK'
#!/bin/bash
[ "$#" -eq 1 ] && [ "$1" = list ] || exit 50
cat "$LIDMATE_FIXTURE"
MOCK
cat > "$T/bin/m1ddc" <<'MOCK'
#!/bin/bash
printf '15\n'
MOCK
chmod +x "$T/bin/displayplacer" "$T/bin/m1ddc"

cat > "$T/one-line" <<EOF
Persistent screen id: $EXT
Type: 27 inch external screen
Resolution: 1920x1080
Hertz: 144
Color Depth: 8
Scaling: on
Origin: (0,0)
Enabled: true
Resolutions for rotation 0:
  mode 0: res:1280x800 hz:60 color_depth:8
  mode 1: res:1920x1080 hz:144 color_depth:8 scaling:on
Persistent screen id: $INT
Type: MacBook built in screen
Resolution: 1496x967
Hertz: 60
Color Depth: 8
Scaling: on
Origin: (1920,369)
Enabled: true
Resolutions for rotation 0:
  mode 0: res:1280x800 hz:60 color_depth:8 scaling:on
  mode 1: res:1496x967 hz:60 color_depth:8 scaling:on
EOF

cat > "$T/two-line" <<EOF
Persistent screen id: $EXT
Type: 27 inch external screen
Resolution: 1920x1080
Hertz: 144
Color Depth: 8
Scaling: on
Origin: (0,0)
Enabled: true
Resolutions for rotation 0:
  mode 0: res:1280x800
 hz:60
  mode 1: res:1920x1080
 hz:144
Persistent screen id: $INT
Type: MacBook built in screen
Resolution: 1496x967
Hertz: 60
Color Depth: 8
Scaling: on
Origin: (1920,369)
Enabled: true
Resolutions for rotation 0:
  mode 0: res:1280x800
 hz:60
  mode 1: res:1496x967
 hz:60
EOF

for format in one-line two-line; do
  output=$(LIDMATE_BIN="$T/bin" LIDMATE_FIXTURE="$T/$format" \
    LIDMATE_EXT_UUID="$EXT" LIDMATE_INT_UUID="$INT" LIDMATE_MAC_INPUT=15 \
    LIDMATE_LOG="$T/$format.log" LIDMATE_DOCTOR=1 \
    bash "$ROOT/src/resources/displaysync.sh")
  if ! grep -Fq '1280x800 @ 60Hz' <<< "$output"; then
    echo "❌ $format: 没有找到共同模式 1280x800 @ 60Hz"
    exit 1
  fi
  if ! grep -Fq "id:$INT+$EXT res:1280x800 hz:60" <<< "$output"; then
    echo "❌ $format: 镜像命令缺少共同模式"
    exit 1
  fi
  echo "✅ $format: 共同模式和镜像预览正确"
done
