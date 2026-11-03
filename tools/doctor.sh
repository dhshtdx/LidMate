#!/bin/bash
# ============================================================
#  LidMate · 只读诊断（doctor）
#
#  用法：  bash tools/doctor.sh
#
#  它会：
#    · 列出当前所有屏、内屏当前模式
#    · 读出外屏的 VCP 0x60
#    · 算出镜像折叠**实际会用**的模式
#    · 检查布局档案是否被污染（含 Sidecar/iPad 的 id）
#
#  ⚠️ 全程只读：不执行任何 displayplacer 改布局的命令。
#     出问题时先跑这个，它能直接区分「模式不支持」和「读数/档案」问题。
# ============================================================

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# 这个脚本有两种摆放方式，路径都得认：
#   仓库里  : tools/doctor.sh          → 二进制在 ../vendor，逻辑在 ../src/resources
#   App 包内: Contents/Resources/doctor.sh → 二进制在 ./bin，逻辑在 ./displaysync.sh
pick() { for p in "$@"; do [ -e "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

LIDMATE_BIN="${LIDMATE_BIN:-$(pick "$HERE/vendor" "$HERE/bin" "$HERE/../vendor" || true)}"
if [ -z "$LIDMATE_BIN" ] || [ ! -x "$LIDMATE_BIN/displayplacer" ]; then
  echo "❌ 找不到 displayplacer（找过 vendor/ 和 bin/）"
  exit 1
fi
export LIDMATE_BIN

SYNC=$(pick "$HERE/displaysync.sh" "$HERE/../src/resources/displaysync.sh") || {
  echo "❌ 找不到 displaysync.sh"
  exit 1
}

# 诊断用的临时日志：绝不碰 ~/Library/Logs 里正在用的那个
export LIDMATE_LOG="${LIDMATE_LOG:-${TMPDIR:-/tmp}/lidmate-doctor.log}"

DP="$LIDMATE_BIN/displayplacer"
M1DDC="$LIDMATE_BIN/m1ddc"
for b in "$DP" "$M1DDC"; do
  [ -f "$b" ] || { echo "❌ 找不到 $b"; exit 1; }
  [ -x "$b" ] || chmod +x "$b" 2>/dev/null
done

echo "=============================================="
echo "  LidMate 只读诊断（不改变任何显示状态）"
echo "=============================================="
echo

INT=$("$DP" list 2>/dev/null | awk '
  /^Persistent screen id: / { u = $4 }
  /^Type: / { if ($0 ~ /built in|built-in/) print u }' | head -1)
if [ -z "$INT" ]; then
  echo "❌ 没识别出内置屏（Type 里应含 'built in'）。"
  exit 1
fi

# 外屏候选：取第一块 VCP 0x60 读得出数字的 —— 这正是 App 的挑选逻辑
EXT=""
CODE=""
CANDIDATES=()
while IFS= read -r u; do
  [ -n "$u" ] && CANDIDATES+=("$u")
done < <("$DP" list 2>/dev/null | awk -v i="$INT" '
  /^Persistent screen id: / { u = $4 }
  /^Type: / { if (u != i && $0 !~ /built in|built-in/) print u }')

for u in "${CANDIDATES[@]:-}"; do
  [ -z "$u" ] && continue
  v=$("$M1DDC" display uuid="$u" get input 2>/dev/null | tr -d '\n ')
  case "$v" in
    ''|*[!0-9]*) continue ;;
  esac
  EXT="$u"
  CODE="$v"
  break
done

if [ -z "$EXT" ]; then
  echo "⚠️  没找到能读 DDC VCP 0x60 的外接显示器（候选 ${#CANDIDATES[@]} 块）。"
  echo "    请把显示器切回本机输入源再试，或先跑 tools/selftest.sh。"
  exit 1
fi

export LIDMATE_EXT_UUID="$EXT"
export LIDMATE_INT_UUID="$INT"
export LIDMATE_MAC_INPUT="$CODE"
export LIDMATE_DOCTOR=1
exec bash "$SYNC"
