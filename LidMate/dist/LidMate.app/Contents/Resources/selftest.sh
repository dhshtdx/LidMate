#!/bin/bash
# ============================================================
#  LidMate · 显示器兼容性自检
#
#  LidMate 的「显示器跟随」完全依赖一个能力：
#     你的显示器能不能通过 DDC/CI 读出「当前输入源」(VCP 0x60)？
#
#  很多显示器不支持读这个寄存器，或者返回恒定值 —— 那些机器上
#  LidMate 无法工作。**装之前请先跑这个脚本。**
#
#  用法：  bash tools/selftest.sh
# ============================================================

set -u
BINDIR="${LIDMATE_BIN:-$(cd "$(dirname "$0")/.." && pwd)/vendor}"
M1DDC="$BINDIR/m1ddc"
DP="$BINDIR/displayplacer"

echo "=============================================="
echo "  LidMate 显示器兼容性自检"
echo "=============================================="
echo

# ---- 0. 环境 ----
ARCH=$(uname -m)
echo "架构: $ARCH"
if [ "$ARCH" != "arm64" ]; then
  echo "❌ 本工具依赖的 m1ddc 只支持 Apple Silicon。"
  echo "   Intel Mac 请改用 ddcctl 或 Better Display 的 CLI 版本。"
  exit 1
fi
if [ ! -x "$M1DDC" ]; then echo "❌ 找不到 m1ddc: $M1DDC"; exit 1; fi
if [ ! -x "$DP" ];    then echo "❌ 找不到 displayplacer: $DP"; exit 1; fi
echo "依赖: ✅ m1ddc / displayplacer"
echo

# ---- 1. 显示器清单 ----
echo "---- ① 当前接的显示器 ----"
"$DP" list 2>/dev/null | awk '
  /^Persistent screen id: / { u = $4 }
  /^Type: / { t = substr($0, 7) }
  /^Resolution: / { r = $2 }
  /^Origin: / { o = $2; printf "  %-38s %-28s %-12s %s\n", u, t, r, o }'
echo

INT_UUID=$("$DP" list 2>/dev/null | awk '/^Persistent screen id: /{u=$4} /^Type: /{ if ($0 ~ /built in|built-in/) print u }' | head -1)
if [ -z "$INT_UUID" ]; then
  echo "❌ 没识别出内置屏（Type 里应含 'built in'）。本自检只针对笔记本。"
  exit 1
fi
echo "内置屏: $INT_UUID"

EXTS=()
while IFS= read -r _line; do
  [ -n "$_line" ] && EXTS+=("$_line")
done < <("$DP" list 2>/dev/null | awk -v i="$INT_UUID" '
  /^Persistent screen id: /{u=$4} /^Type: /{ if (u != i && $0 !~ /built in|built-in/) print u }')
if [ "${#EXTS[@]}" -eq 0 ]; then
  echo "❌ 没检测到外接显示器。请接好外屏再跑一次。"
  exit 1
fi
echo "外接屏候选: ${EXTS[*]}"
echo

# ---- 2. 逐个测 VCP 0x60 能不能读 ----
for EXT in "${EXTS[@]}"; do
  echo "---- ② 测试显示器 $EXT ----"
  V1=$("$M1DDC" display uuid="$EXT" get input 2>&1 | tr -d '\n ')
  case "$V1" in
    ''|*[!0-9]*)
      echo "  读取结果: [$V1]"
      echo "  ❌ 读不到数字 → 这块显示器不支持通过 DDC 读取输入源。"
      echo "     → LidMate 无法在这块屏上工作。"
      echo
      continue
      ;;
  esac
  echo "  当前输入源读数: $V1"
  echo "  ✅ 能读到数字，说明这个寄存器是可读的"
  echo
  echo "  ---- ③ 现在请把显示器的输入源切到另一个设备 ----"
  echo "       （切走后停 5 秒）"
  printf "       切好后按回车继续… "
  read -r _

  V2=$("$M1DDC" display uuid="$EXT" get input 2>&1 | tr -d '\n ')
  echo "  切换后读数: $V2"
  echo

  # 恢复提示
  echo "  （现在请把显示器切回本机，然后按回车）"
  printf "  > "
  read -r _

  if [ "$V2" != "$V1" ]; then
    echo "  ✅✅ 结论：切换输入源时读数会变（$V1 → $V2）"
    echo "        → **LidMate 完全支持这块显示器**"
    echo "        → 本机输入码应填: $V1"
  else
    echo "  ⚠️  结论：切换后读数没变（仍是 $V2）"
    echo "       可能原因："
    echo "         · 显示器在非激活输入上返回的是缓存/无效值"
    echo "         · 你切得不够久，或切回来太快"
    echo "       建议再试一次，并且切走后多停一会儿（10 秒以上）"
  fi
  echo
done

echo "=============================================="
echo "  自检结束"
echo "=============================================="
echo
echo "如果显示 ✅，就可以装 LidMate 了。"
echo "装好后首次启动会自动学习本机输入码；换线/换口后"
echo "在菜单栏点「重新学习当前显示器」即可。"
