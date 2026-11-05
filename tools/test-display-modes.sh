#!/bin/bash
# 只读：用两种 displayplacer 模式格式验证先试内屏正常比例，再回退共同模式。
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
  if ! grep -Fq '1496x967 @ 自动刷新率' <<< "$output"; then
    echo "❌ $format: 没有优先尝试内屏正常模式 1496x967"
    exit 1
  fi
  if ! grep -Fq "id:$INT+$EXT res:1496x967 scaling:on" <<< "$output"; then
    echo "❌ $format: 镜像命令没有使用内屏正常模式和自动刷新率"
    exit 1
  fi
  if ! grep -Fq '1280x800 @ 60Hz' <<< "$output"; then
    echo "❌ $format: 没有保留共同模式 1280x800 @ 60Hz 作为回退"
    exit 1
  fi
  echo "✅ $format: 内屏正常模式优先、共同模式回退正确"
done

# 镜像成功后的黑边提示也必须能在 set -u 下执行。
warning_line=$(rg 'log "  ↳ 注意：镜像模式' "$ROOT/src/resources/displaysync.sh")
warning_output=$(bash -u -c '
  after=1280x800
  aspect_native=1.5470
  aspect_now=1.6000
  log() { printf "%s\n" "$*"; }
  eval "$1"
' _ "$warning_line")
grep -Fq '1280x800' <<< "$warning_output"
echo '✅ 镜像成功后的黑边提示没有触发未定义变量'
