#!/bin/bash
# ============================================================
#  LidMate · 合盖即睡
#
#  只要合上盖子就立即休眠 —— 即使接着电源和外接显示器。
#
#  背景：macOS 在「接电源 + 接外接显示器」时会进入 clamshell
#  模式，合盖后保持唤醒（系统设置里没有开关可以关掉）。
#  这里每秒检查一次盖子状态，合上就执行 pmset sleepnow。
# ============================================================

LOG="${LIDMATE_LOG:-$HOME/Library/Logs/LidMate.log}"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

OWNER_PID=$PPID
log "=== 合盖即睡：启动 (pid=$$ 父进程=$OWNER_PID) ==="

closed=0
while true; do
  # 父进程（App）退出后自动结束，避免变成孤儿进程
  if ! kill -0 "$OWNER_PID" 2>/dev/null; then
    log "父进程已退出 → 合盖即睡结束"
    exit 0
  fi

  if ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; then
    if [ "$closed" = "0" ]; then
      log "检测到合盖 → 立即休眠"
      closed=1
    fi
    pmset sleepnow 2>/dev/null
  else
    closed=0
  fi
  sleep 1
done
