#!/bin/bash
# ============================================================
#  LidMate · 布局档案白名单回归测试
#
#  守的是 2026-10-15 那次「一退出 App 就黑屏」：
#  屏幕瞬时离线时 displayplacer 的重放行会退化成
#      displayplacer "id:外屏 enabled:false" "id:内屏 enabled:false"
#  它形状合格、uuid 数量合格，于是被存进档案；还原时一执行就把
#  两块屏同时关掉。现在 profile_is_sane() 必须把它挡下来。
#
#  用法：  bash tools/test-profile-guard.sh
#  只读：  不执行 displayplacer，不碰任何显示状态。
# ============================================================

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 仓库里跑用 src/resources/，被拷进 App 包后用同目录的副本
if [ -n "${LIDMATE_SYNC:-}" ]; then
  SYNC="$LIDMATE_SYNC"
elif [ -f "$ROOT/src/resources/displaysync.sh" ]; then
  SYNC="$ROOT/src/resources/displaysync.sh"
else
  SYNC="$(cd "$(dirname "$0")" && pwd)/displaysync.sh"
fi
[ -f "$SYNC" ] || { echo "❌ 找不到 $SYNC"; exit 1; }

# 默认用本机实测的两个 uuid，可用环境变量覆盖
export LIDMATE_EXT_UUID="${LIDMATE_EXT_UUID:-9D03379C-8D55-4E61-AE23-76C0009C03A0}"
export LIDMATE_INT_UUID="${LIDMATE_INT_UUID:-37D8832A-2D66-02CA-B9F7-8F30A301B230}"
export LIDMATE_MAC_INPUT="${LIDMATE_MAC_INPUT:-15}"
EXT="$LIDMATE_EXT_UUID"
INT="$LIDMATE_INT_UUID"
IPAD="E9F4DF38-2C10-44F1-8493-52291D85B15B"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0; fail=0

# check <期望 可用|不可用> <说明> <档案内容>
check() {
  local want="$1" desc="$2" content="$3" f="$T/case"
  printf '%s\n' "$content" > "$f"
  local got
  got=$(LIDMATE_TEST_PROFILE="$f" bash "$SYNC" 2>/dev/null)
  if [ "$got" = "$want" ]; then
    printf '  ✅ %-46s → %s\n' "$desc" "$got"; pass=$((pass+1))
  else
    printf '  ❌ %-46s → %s（期望 %s）\n' "$desc" "${got:-无输出}" "$want"; fail=$((fail+1))
  fi
}

echo "=============================================="
echo "  LidMate 布局档案白名单回归测试"
echo "=============================================="
echo

echo "── 必须通过（合法扩展布局）──"
check "可用" "标准双屏扩展布局" \
  "displayplacer \"id:$EXT res:2560x1440 hz:144 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0\" \"id:$INT res:1496x967 hz:120 color_depth:8 enabled:true scaling:on origin:(2560,296) degree:0\""

echo
echo "── 必须拒绝 ──"
check "不可用" "两块屏都被 enabled:false（本次事故档案）" \
  "displayplacer \"id:$EXT enabled:false\" \"id:$INT enabled:false\""
check "不可用" "只有一块屏被 enabled:false" \
  "displayplacer \"id:$EXT res:2560x1440 hz:144 color_depth:8 enabled:false scaling:on origin:(0,0) degree:0\" \"id:$INT res:1496x967 hz:120 color_depth:8 enabled:true scaling:on origin:(2560,296) degree:0\""
check "不可用" "缺 res/origin 的裸 id 规格" \
  "displayplacer \"id:$EXT enabled:false\" \"id:$INT res:1496x967 hz:120 color_depth:8 enabled:true scaling:on origin:(2560,296) degree:0\""
check "不可用" "镜像命令（含加号）" \
  "displayplacer \"id:$INT+$EXT res:1280x800 hz:60 color_depth:8 scaling:on origin:(0,0) degree:0\""
check "不可用" "混进第三块屏（iPad）" \
  "displayplacer \"id:$EXT res:2560x1440 hz:144 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0\" \"id:$INT res:1496x967 hz:120 color_depth:8 enabled:true scaling:on origin:(2560,296) degree:0\" \"id:$IPAD res:1253x985 hz:60 color_depth:4 enabled:true scaling:on origin:(2560,-689) degree:0\""
check "不可用" "空档案" ""
check "不可用" "不是 displayplacer 命令" "echo hello"

echo
echo "=============================================="
printf '  通过 %d / 失败 %d\n' "$pass" "$fail"
echo "=============================================="
[ "$fail" -eq 0 ] && exit 0 || exit 1
