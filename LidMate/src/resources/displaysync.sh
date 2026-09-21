#!/bin/bash
# ============================================================
#  LidMate · 显示器跟随
#
#  盯着外接显示器的「当前输入源」(DDC VCP 0x60)：
#    - 显示器在放本机   → 外屏为主屏（扩展布局）
#    - 显示器切到别的设备 → 镜像折叠到内屏（见下）
#    - 切回本机         → 自动还原扩展布局
#
#  ── 为什么用「镜像」而不是「禁用外屏」─────────────────────
#  实测：displayplacer "id:<外屏> enabled:false" 会把外屏从
#  macOS 的显示枚举里彻底摘掉；而显示器切回本机输入源时**不会**
#  产生任何 HPD 变化（DP 链路全程保持），驱动层一个事件都不记，
#  于是 macOS 永远不会把屏加回来 —— 只能拔插线才能恢复。
#
#  镜像则完全不同：
#    · 系统里只剩一块逻辑屏 → 鼠标无处可去、键盘焦点无处可逃、
#      窗口不可能被丢到看不见的地方
#    · 完全可逆，且不切断信号链路（DDC 一直可读，还原永远有依据）
#
#  ── 为什么要「滑窗投票」而不是连续计数 ────────────────────
#  显示器切换输入源的瞬间，DDC 读数会在「本机」和「无效值」之间
#  反复横跳好几秒。朴素的"连续 N 次异常"会被中间的偶发正常值清零，
#  导致触发被拖到十几秒后。改成"最近 WINDOW 次里至少 BAD_NEEDED 次
#  异常"就能立刻触发，同时仍然忽略单次毛刺。
# ============================================================

set -u

# ---------------- 由 App 通过环境变量传入 ----------------
EXT_UUID="${LIDMATE_EXT_UUID:-}"
INT_UUID="${LIDMATE_INT_UUID:-}"
MAC_INPUT="${LIDMATE_MAC_INPUT:-}"

POLL="${LIDMATE_POLL:-1}"          # 轮询间隔（秒）
WINDOW="${LIDMATE_WINDOW:-4}"      # 判断窗口：看最近几次采样
BAD_NEEDED="${LIDMATE_BAD:-2}"     # 窗口内至少几次异常才认定切走
DDC_TIMEOUT=30                     # DDC 读取最多等多少个 0.1 秒（30 = 3 秒）
HEARTBEAT=15                       # 多少轮没变化写一次心跳日志
# ---------------------------------------------------------

BINDIR="${LIDMATE_BIN:-$HOME/.local/bin}"
M1DDC="$BINDIR/m1ddc"
DP="$BINDIR/displayplacer"
LOG="${LIDMATE_LOG:-$HOME/Library/Logs/LidMate.log}"
TMPF="$LOG.tmp.$$"
PROFILE="$LOG.layout"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec 2>> "$LOG"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
cleanup() { rm -f "$TMPF"; }
trap cleanup EXIT

if [ -z "$EXT_UUID" ] || [ -z "$INT_UUID" ] || [ -z "$MAC_INPUT" ]; then
  log "缺少配置（外屏/内屏 UUID 或本机输入码），请先在菜单里点「重新学习当前显示器」"
  exit 1
fi

ext_present() { "$DP" list 2>/dev/null | grep -q "$EXT_UUID"; }

# 外屏和内屏的 origin 不同 = 扩展布局（反之是镜像）
layout_is_extended() {
  "$DP" list 2>/dev/null | awk -v a="$EXT_UUID" -v b="$INT_UUID" '
    /^Persistent screen id: / { cur = $4 }
    /^Origin: / { if (cur == a) oa = $2; if (cur == b) ob = $2 }
    END { exit (oa != "" && ob != "" && oa != ob) ? 0 : 1 }'
}

# 把所有屏导出成 uuid|res|hz|depth|scaling|originX|originY 一行一块
displays_dump() {
  "$DP" list 2>/dev/null | awk '
    function flush() { if (u != "") print u "|" r "|" h "|" d "|" s "|" ox "|" oy }
    /^Persistent screen id: / { flush(); u = $4; r=""; h=""; d=""; s=""; ox=""; oy=""; next }
    /^Resolution:/  { r = $2 }
    /^Hertz:/       { h = $2 }
    /^Color Depth:/ { d = $3 }
    /^Scaling:/     { s = $2 }
    /^Origin: /     { gsub(/[()]/, "", $2); split($2, a, ","); ox = a[1]; oy = a[2] }
    END { flush() }'
}

# 把当前扩展布局存成可重放的命令（displayplacer 自己的输出，可信）
# 铁律：只在「确实是扩展布局」时存档 —— 绝不把镜像状态存成档案，
#       否则还原命令会变成"再镜像一次"，从此永久损坏。
save_profile() {
  layout_is_extended || return 1
  local cur
  cur=$("$DP" list 2>/dev/null | tail -1)
  case "$cur" in displayplacer\ *id:*) ;; *) return 1 ;; esac
  case "$cur" in *id:*+*) return 1 ;; esac        # 含加号 = 镜像命令，拒绝
  local changed=0
  [ "$cur" = "$(cat "$PROFILE" 2>/dev/null)" ] || { printf '%s\n' "$cur" > "$PROFILE"; changed=1; }
  [ "$cur" = "$(cat "$PROFILE.bak" 2>/dev/null)" ] || printf '%s\n' "$cur" > "$PROFILE.bak"
  [ "$changed" = "1" ] && log "已记录扩展布局档案"
  return 0
}

# 从档案还原：跳过镜像档案、执行后校验、失败换备份、每份最多试 3 次
restore_profile() {
  local src cmd i
  for src in "$PROFILE" "$PROFILE.bak"; do
    [ -s "$src" ] || continue
    case "$(cat "$src")" in *id:*+*) continue ;; esac
    cmd=$(sed "s|^displayplacer|'$DP'|" "$src")
    for i in 1 2 3; do
      eval "$cmd" >/dev/null 2>&1
      sleep 1
      if layout_is_extended; then
        [ "$src" != "$PROFILE" ] && cp "$src" "$PROFILE" 2>/dev/null
        return 0
      fi
    done
  done
  return 1
}

# 切走时：把外屏折叠进内屏做镜像；其余屏（如 Sidecar）保留参数、
# 按"相对内屏的偏移"重新落位，保证整块桌面结构不乱。
apply_mirror() {
  local dump ir ih idp isc iox ioy
  dump=$(displays_dump)
  [ -z "$dump" ] && { log "镜像失败：读不到显示列表"; return 1; }

  read -r ir ih idp isc <<< "$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $2" "$3" "$4" "$5}')"
  iox=$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $6}')
  ioy=$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $7}')
  if [ -z "$ir" ] || [ -z "$iox" ]; then
    log "镜像失败：读不到内屏参数"
    return 1
  fi

  local args=()
  args+=( "id:$INT_UUID+$EXT_UUID res:$ir hz:$ih color_depth:${idp:-8} scaling:${isc:-on} origin:(0,0) degree:0" )

  local u r h d s ox oy
  while IFS='|' read -r u r h d s ox oy; do
    [ -z "$u" ] && continue
    [ "$u" = "$INT_UUID" ] && continue
    [ "$u" = "$EXT_UUID" ] && continue
    args+=( "id:$u res:$r hz:$h color_depth:${d:-8} enabled:true scaling:${s:-on} origin:($((ox - iox)),$((oy - ioy))) degree:0" )
  done <<< "$dump"

  "$DP" "${args[@]}" >/dev/null 2>&1
}

# 带超时的 DDC 读取；非数字应答归一成 INVALID
# （部分显示器在非激活输入上会返回一个恒定的垃圾值，例如 2809）
read_input() {
  local pid i out
  : > "$TMPF"
  "$M1DDC" display uuid="$EXT_UUID" get input > "$TMPF" 2>/dev/null &
  pid=$!
  i=0
  while [ "$i" -lt "$DDC_TIMEOUT" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    printf 'TIMEOUT'
    return
  fi
  wait "$pid" 2>/dev/null
  out=$(tr -d '\n ' < "$TMPF")
  case "$out" in
    '')       printf 'INVALID' ;;
    *[!0-9]*) printf 'INVALID' ;;
    *)        printf '%s' "$out" ;;
  esac
}

# ---------------- 启动：记录现状，必要时补一次档案 ----------------
if ext_present; then
  if layout_is_extended; then state="ours"; save_profile; else state="away"; fi
else
  state="absent"
fi
OWNER_PID=$PPID
log "=== 显示器跟随：启动 state=$state mac_input=$MAC_INPUT pid=$$ 父进程=$OWNER_PID ==="

loops=0
last_v="<none>"
quiet=0
hist=""
restore_warned=0

while true; do
  if ! kill -0 "$OWNER_PID" 2>/dev/null; then
    log "父进程已退出 → 显示器跟随结束"
    exit 0
  fi

  loops=$((loops + 1))
  present=0
  v=""

  if ext_present; then present=1; fi

  if [ "$present" = "1" ]; then
    v=$(read_input)
    if [ "$v" = "$MAC_INPUT" ]; then hist="${hist}G"; else hist="${hist}B"; fi
    [ "${#hist}" -gt "$WINDOW" ] && hist="${hist: -$WINDOW}"
    badn=$(printf '%s' "$hist" | tr -cd 'B' | wc -c | tr -d ' ')
    goodn=$(printf '%s' "$hist" | tr -cd 'G' | wc -c | tr -d ' ')
    if [ "$badn" -ge "$BAD_NEEDED" ]; then
      want="away"
    elif [ "$goodn" -ge "$WINDOW" ]; then
      want="ours"
    else
      want="$state"     # 摇摆期：维持现状，绝不乱改布局
    fi
  else
    hist=""
    want="absent"
  fi

  if [ "$v" != "$last_v" ]; then
    log "读数变化: present=$present input=[$v] 窗口=[$hist] want=$want state=$state"
    last_v="$v"
    quiet=0
  else
    quiet=$((quiet + 1))
    if [ "$quiet" -ge "$HEARTBEAT" ]; then
      log "心跳: present=$present input=[$v] 窗口=[$hist] want=$want state=$state"
      quiet=0
    fi
  fi

  case "$want" in
    ours)
      if [ "$state" != "ours" ]; then
        if restore_profile; then
          log "外屏在显示本机 (input=$v) → 还原扩展布局、外屏为主屏"
          state="ours"
          save_profile
          restore_warned=0
        elif [ "$restore_warned" = "0" ]; then
          log "外屏在显示本机，但还原失败（档案缺失或无效），继续重试"
          restore_warned=1
        fi
      else
        layout_is_extended && save_profile
      fi
      ;;
    away)
      if [ "$state" != "away" ]; then
        save_profile
        apply_mirror
        log "外屏切走了 (input=$v, 窗口=[$hist]) → 镜像到内屏（鼠标/焦点锁定在笔记本）"
        state="away"
      fi
      ;;
    absent)
      if [ "$state" != "absent" ]; then
        log "外屏已从系统消失 (macOS 自行处理)，等它回来"
        state="absent"
      fi
      ;;
  esac

  if [ "$present" = "0" ]; then sleep 1; else sleep "$POLL"; fi
done
