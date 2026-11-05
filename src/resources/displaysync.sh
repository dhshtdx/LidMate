#!/bin/bash
# ============================================================
#  LidMate · 显示器跟随（修复版）
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
#    · 系统里只剩一块逻辑屏 → 鼠标无处可去、键盘焦点无处可逃
#    · 完全可逆，且不切断信号链路（DDC 一直可读，还原永远有依据）
#
#  ── 为什么要「滑窗投票」而不是连续计数 ────────────────────
#  显示器切换输入源的瞬间，DDC 读数会在「本机」和「无效值」之间
#  反复横跳好几秒。朴素的"连续 N 次异常"会被中间的偶发正常值清零，
#  导致触发被拖到十几秒后。改成"最近 WINDOW 次里至少 BAD_NEEDED 次
#  异常"就能立刻触发，同时仍然忽略单次毛刺。
#
#  ── 【本次修复】镜像不能想当然，必须验证 + 模式回退 ────────
#  旧版把 displayplacer 的报错丢进 /dev/null，调用方还忽略返回值、
#  无条件把状态标成 away。于是镜像一旦失败：
#    · 日志照样写"镜像到内屏"，用户看到的是"切换了但桌面毫无变化"
#    · 状态被锁死在 away，从此再也不会重试 → 永久失灵
#
#  而失败最常见的原因就是模式不匹配：镜像对（id:内屏+外屏）只能跑
#  一个 res/hz，旧版直接拿**内屏的**分辨率去驱动外屏。笔记本内屏
#  常见的缩放分辨率（如 1496x967@120）在外接屏的模式表里往往不存在
#  （Mi Monitor: 0 个；内屏: 6 个），displayplacer 整条命令就失败了。
#
#  现在：先在日志里留下 displayplacer 的真实退出码和报错 → 再逐级
#  回退到两块屏都支持的公共模式（实时从 displayplacer list 求交集）
#  → 执行后用 origin 校验镜像是不是真的生效 → 失败不锁状态、下轮重试。
# ============================================================

set -u

# ---------------- 由 App 通过环境变量传入 ----------------
EXT_UUID="${LIDMATE_EXT_UUID:-}"
INT_UUID="${LIDMATE_INT_UUID:-}"
MAC_INPUT="${LIDMATE_MAC_INPUT:-}"

POLL="${LIDMATE_POLL:-1}"                   # 轮询间隔（秒）
WINDOW="${LIDMATE_WINDOW:-4}"               # 判断窗口：看最近几次采样
BAD_NEEDED="${LIDMATE_BAD:-2}"              # 窗口内至少几次异常才认定切走
DDC_TIMEOUT=30                              # DDC 读取最多等多少个 0.1 秒（30 = 3 秒）
HEARTBEAT=15                                # 多少轮没变化写一次心跳日志
MIRROR_RETRY="${LIDMATE_MIRROR_RETRY:-5}"   # 镜像失败后每隔几轮重试一次
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
# 额外要求两块屏都**没有被显式禁用**：屏被 enabled:false 摘掉之后，
# displayplacer 仍会打印它上一次的 Origin，只看 origin 会把
# "其中一块已经黑了" 误判成"扩展布局正常"。
layout_is_extended() {
  "$DP" list 2>/dev/null | awk -v a="$EXT_UUID" -v b="$INT_UUID" '
    /^Persistent screen id: / { cur = $4; next }
    /^Origin: / { if (cur == a) oa = $2; if (cur == b) ob = $2 }
    /^Enabled: / { if (cur == a) ea = $2; if (cur == b) eb = $2 }
    END { exit (oa != "" && ob != "" && oa != ob && ea != "false" && eb != "false") ? 0 : 1 }'
}

# 两块屏都在系统枚举里、且都没有被显式禁用 —— 存档前的最后一道闸门。
# 只有明确读到 enabled:false 才判失败，这样不会因为 displayplacer
# 版本差异（不打印 Enabled 行）而把功能整个卡死。
both_screens_enabled() {
  "$DP" list 2>/dev/null | awk -v a="$EXT_UUID" -v b="$INT_UUID" '
    /^Persistent screen id: / { cur = $4; next }
    /^Enabled: / { if (cur == a) ea = $2; if (cur == b) eb = $2 }
    END { exit (ea != "false" && eb != "false") ? 0 : 1 }'
}

# 两块屏 origin 相同 = 镜像（layout_is_extended 的反面）
mirror_active() {
  "$DP" list 2>/dev/null | awk -v a="$EXT_UUID" -v b="$INT_UUID" '
    /^Persistent screen id: / { cur = $4 }
    /^Origin: / { if (cur == a) oa = $2; if (cur == b) ob = $2 }
    END { exit (oa != "" && ob != "" && oa == ob) ? 0 : 1 }'
}

# 镜像对是不是坐在 (0,0) —— 也就是主显示器、菜单栏和 Dock 所在的那块
pair_is_primary() {
  "$DP" list 2>/dev/null | awk -v a="$EXT_UUID" -v b="$INT_UUID" '
    /^Persistent screen id: / { cur = $4 }
    /^Origin: / { if (cur == a || cur == b) { gsub(/[()]/, "", $2); if ($2 == "0,0") hit = 1 } }
    END { exit hit ? 0 : 1 }'
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

# 某块屏支持的所有模式，输出 "res:WxH N"。
# displayplacer 的模式行有两种格式：
#   mode 3: res:1920x1080 hz:144 color_depth:8
#   mode 3: res:1920x1080
#    hz:144
# 两种格式都要提取刷新率，否则公共模式会被误判为空。
modes_of() {
  "$DP" list 2>/dev/null | awk -v want="$1" '
    /^Persistent screen id: / { cur = $4; mres = ""; next }
    /^  mode / && cur == want {
      mres = $3
      if (mres !~ /^res:[0-9]+x[0-9]+$/) { mres = ""; next }
      if ($4 ~ /^hz:[0-9]+$/) {
        hz = $4; sub(/^hz:/, "", hz); print mres, hz; mres = ""
      }
      next
    }
    /^[[:space:]]+hz:/ && cur == want && mres != "" {
      hz = $1; sub(/^hz:/, "", hz); print mres, hz; mres = ""
    }'
}

# 宽高比（缩放到 4 位小数），用于判断镜像模式是否会把内屏压成别家比例
aspect_of() {
  local r="${1#res:}" w h
  w="${r%%x*}"; h="${r##*x}"
  [ -n "$w" ] && [ -n "$h" ] || return 1
  awk -v w="$w" -v h="$h" 'BEGIN { if (h == 0) exit 1; printf "%.4f", w / h }'
}

# 内屏「原生比例」：从内屏支持的模式里取像素数最大的那个。
# 不直接用当前模式 —— 镜像降级后当前模式本身可能就是错的（例如 1280x800）。
native_aspect() {
  modes_of "$INT_UUID" | awk '
    {
      split($1, r, ":"); split(r[2], p, "x")
      area = p[1] * p[2]
      if (area > best) { best = area; w = p[1]; h = p[2] }
    }
    END { if (h == 0) exit 1; printf "%.4f", w / h }'
}

# 比例是否接近（容差 1.5%）。苹果 14/16 寸的实际比例约 1.547/1.539，
# 不是精确的 1.6；写死 16:10 会把它们都误判成异类。
aspect_close() {
  awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit (d <= b * 0.015) ? 0 : 1 }'
}

# 某个模式是否是内屏正常比例下的模式
mode_matches_native() {
  local mode="$1" a b
  a=$(aspect_of "$mode" 2>/dev/null || true)
  b=$(native_aspect 2>/dev/null || true)
  [ -n "$a" ] && [ -n "$b" ] || return 1
  aspect_close "$a" "$b"
}

# 两块屏列表里完全一致的模式，用作自动刷新率方案失败时的回退。
common_modes() {
  local fa fb
  fa=$(mktemp) || return 1
  fb=$(mktemp) || return 1
  modes_of "$EXT_UUID" | sort -u > "$fa"
  modes_of "$INT_UUID" | sort -u > "$fb"
  comm -12 "$fa" "$fb" | awk '
    { split($1, r, ":"); split(r[2], p, "x"); print p[1] * p[2], $0 }' \
    | sort -rn | awk '{ $1 = ""; sub(/^ /, ""); print }'
  rm -f "$fa" "$fb"
}

# internal_restore_mode / modes_of 输出的是 "res:WxH N"。
# 拼 displayplacer 命令时必须去掉 res: 前缀，否则会变成 res:res:1280x800
# —— 旧版正是因为这个 SIGSEGV。
strip_res() { local v="$1"; printf '%s' "${v#res:}"; }

# 镜像可以用的模式候选（顺序即优先级），每行 "res hz"。
# 先让 macOS 用内屏正常分辨率自行选择两块屏的刷新率；本机实测此时
# 内屏 1496x967@120、外屏 1496x967@144，尽管外屏模式列表没有该分辨率。
# 失败后才回退到两块屏列表里完全一致的模式。
#
# 排序原则：**按比例接近程度排序，再按像素数排序**。
# 镜像时内屏会被切到候选模式；如果选了比例不一致的模式（例如 1.547 的
# 笔记本内屏跑 16:10 的 1280x800），macOS 会在内屏上下补黑边。黑边只应
# 出现在「桌面被镜像到错误比例」的瞬间，绝不该成为稳定状态。
# 哪怕所有公共模式都不是原生比例，也选最接近的那个，把黑边压到最小。
mirror_candidates() {
  local dump ir ih native m normal normal_res seen=" "
  dump=$(displays_dump)
  read -r ir ih _ _ <<< "$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $2" "$3" "$4" "$5}')"
  native=$(native_aspect 2>/dev/null || true)

  normal=$(internal_restore_mode 2>/dev/null || true)
  normal_res=$(strip_res "${normal%% *}")
  if [ -n "$normal_res" ] && mode_matches_native "$normal_res"; then
    printf '%s auto\n' "$normal_res"
    seen="$seen$normal_res auto "
  fi

  # 公共模式：按「与内屏原生比例的距离」升序，再按像素数降序。
  # 注意：这块用 < <(...) 而不是管道，所以内层 awk 能直接看到外层的 nat。
  # 比例完全一致的按像素数降序；比例不一致的按差值升序 —— 如果两者单纯
  # 混在一起排序，尺寸更大的 16:9 模式会压过尺寸更小的原生比例模式。
  if [ -n "$native" ]; then
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      m="${m#res:}"          # "1280x800 hz:60"
      m="${m// hz:/ }"       # "1280x800 60"
      case "$seen" in *" $m "*) continue ;; esac
      printf '%s\n' "$m"
      seen="$seen$m "
    done < <(common_modes | awk -v nat="$native" '
      {
        split($1, r, ":"); split(r[2], p, "x")
        area = p[1] * p[2]; asp = p[1] / p[2]
        d = asp - nat; if (d < 0) d = -d
        printf "%.8f %d %s\n", d, area, $0
      }' | sort -k1,1n -k2,2nr | awk '{
        $1 = ""; $2 = ""; sub(/^  /, ""); print
      }' | head -7)
  else
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      m="${m#res:}"
      m="${m// hz:/ }"
      case "$seen" in *" $m "*) continue ;; esac
      printf '%s\n' "$m"
      seen="$seen$m "
    done < <(common_modes)
  fi

  # 内屏当前模式若不在公共模式里（解析差异/刷新率不同），作为兼容兜底。
  if [ -n "$ir" ] && modes_of "$EXT_UUID" | grep -q "^res:$ir $ih$"; then
    case "$seen" in
      *" $ir $ih "*) ;;
      *) printf '%s %s\n' "$ir" "$ih" ;;
    esac
  fi
}

# 只拼不执行：打印折叠时会执行的命令（doctor 用）。
# 注意：**只有镜像对那一条规格**，绝不带第三块屏 —— 原因见 run_mirror_with_mode。
preview_mirror_command() {
  local args=() res hz
  read -r res hz _ <<< "$(mirror_candidates | head -1)"
  [ -n "${res:-}" ] || return 1

  if [ "$hz" = auto ]; then
    args=( "id:$INT_UUID+$EXT_UUID res:$res scaling:on origin:(0,0) degree:0" )
  else
    args=( "id:$INT_UUID+$EXT_UUID res:$res hz:$hz color_depth:8 scaling:on origin:(0,0) degree:0" )
  fi

  printf 'displayplacer'
  for x in "${args[@]}"; do printf ' "%s"' "$x"; done
  printf '\n'
}

# 档案必须长得像 displayplacer 的输出，且只能含内屏/外屏两块。
# 这样既挡得住被污染的档案，也让下面的 eval 不可能执行到别的东西。
profile_is_sane() {
  local c n
  c=$(cat "$1" 2>/dev/null) || return 1
  [ -n "$c" ] || return 1
  printf '%s' "$c" | grep -qE '^displayplacer( "[id:0-9A-Za-z+_.() ,-]+")+$' || return 1
  case "$c" in *id:*+*) return 1 ;; esac        # 含加号 = 镜像命令，不是扩展布局
  case "$c" in *"$INT_UUID"*) ;; *) return 1 ;; esac
  case "$c" in *"$EXT_UUID"*) ;; *) return 1 ;; esac
  # 只能有这两个 uuid。Sidecar/iPad 这类屏的 id 会随重连变化，
  # 把它的 id 写进档案 = 给"还原"埋一颗定时炸弹。
  n=$(printf '%s' "$c" | grep -o 'id:[0-9A-Fa-f-]\{36\}' | sort -u | wc -l | tr -d ' ')
  [ "$n" = "2" ] || return 1

  # ── 2026-10-15 事故补丁 ────────────────────────────────────
  # 屏幕瞬时离线（切输入源/折叠途中）时，displayplacer 的重放行会退化成裸的
  #   displayplacer "id:外屏 enabled:false" "id:内屏 enabled:false"
  # 形状、uuid 数量全部合格，于是被当成"可用档案"存了下来；还原时一执行
  # 就把两块屏同时关掉 —— 表现就是"一退出 App 立刻黑屏"。
  # 所以档案必须是把两块屏都**打开**、并且都给出模式和坐标的命令。
  case "$c" in *enabled:false*|*enabled:no*) return 1 ;; esac

  n=$(printf '%s' "$c" | grep -o 'res:[0-9]' | wc -l | tr -d ' ')
  [ "$n" = "2" ] || return 1
  n=$(printf '%s' "$c" | grep -o 'origin:(' | wc -l | tr -d ' ')
  [ "$n" = "2" ] || return 1

  return 0
}

# 内屏最近一次「正常扩展布局」下的模式，写入 $PROFILE.intmode。
# 这不是布局档案，不参与还原命令的 eval，只用于外屏消失后把内屏恢复回来。
remember_int_mode() {
  local mode="$1"
  [ -n "$mode" ] || return 0
  [ "$mode" = "$(cat "$PROFILE.intmode" 2>/dev/null)" ] && return 0
  printf '%s\n' "$mode" > "$PROFILE.intmode" 2>/dev/null
}

# 当前内屏模式是不是「被镜像降级」了？
# 判据：比例与内屏原生比例不一致，且像素数明显低于内屏最大模式。
# 只靠 origin 判断不够 —— 镜像后如果 macOS 把 origin 又还原成扩展布局，
# 内屏会停在镜像用的低分辨率，表现为「切回 Mac 后上下一直有黑边」。
int_mode_is_degraded() {
  local dump ir ih w h area maxarea a b
  dump=$(displays_dump)
  read -r ir ih _ _ <<< "$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $2" "$3" "$4" "$5}')"
  [ -n "$ir" ] || return 1
  a=$(aspect_of "$ir" 2>/dev/null || true)
  b=$(native_aspect 2>/dev/null || true)
  [ -n "$a" ] && [ -n "$b" ] || return 1
  # 比例明显不一致，且面积也小一截，才判定为镜像降级。
  # 不依赖 .intmode：首次运行遇到被污染的 1280x800 档案时也能识别出来。
  aspect_close "$a" "$b" && return 1
  w="${ir%%x*}"; h="${ir##*x}"
  area=$((w * h))
  maxarea=$(modes_of "$INT_UUID" | awk '
    { split($1, r, ":"); split(r[2], p, "x"); a = p[1] * p[2]; if (a > m) m = a }
    END { print m + 0 }')
  [ "$area" -lt $((maxarea * 9 / 10)) ]
}

# 选出应恢复的内屏模式。
# 优先上次记录的正常模式；没有记录时，在「原生比例」模式里选不小于当前
# 面积的最小模式（从镜像的 1280x800 恢复时落到 1496x967，而不是更大一档），
# 刷新率尽量贴近当前值。
internal_restore_mode() {
  local cur cur_res cur_hz cur_area nat saved a b
  cur=$(displays_dump | awk -F'|' -v id="$INT_UUID" '$1==id{print $2" "$3}')
  cur_res="${cur%% *}"; cur_hz="${cur##* }"
  [ -n "$cur_hz" ] || cur_hz=60
  cur_area=0
  if [ -n "$cur_res" ]; then
    cur_area=$(( ${cur_res%%x*} * ${cur_res##*x} ))
  fi

  saved=$(cat "$PROFILE.intmode" 2>/dev/null || true)
  if [ -n "$saved" ]; then
    a=$(aspect_of "${saved%% *}" 2>/dev/null || true)
    b=$(native_aspect 2>/dev/null || true)
    if [ -n "$a" ] && [ -n "$b" ] && aspect_close "$a" "$b"; then
      printf '%s\n' "$saved"
      return 0
    fi
  fi

  nat=$(native_aspect 2>/dev/null || true)
  [ -n "$nat" ] || return 1

  # 一次 awk 完成筛选和排序，避免为每个模式启动子进程。
  modes_of "$INT_UUID" | awk -v nat="$nat" -v cur_area="$cur_area" -v cur_hz="$cur_hz" '
    function abs(x) { return x < 0 ? -x : x }
    {
      split($1, r, ":"); split(r[2], p, "x")
      w = p[1]; h = p[2]
      if (h == 0) next
      asp = w / h
      if (abs(asp - nat) > nat * 0.015) next
      area = w * h
      # 优先不小于当前面积的最小模式；没有则取最大的较小模式
      if (area >= cur_area) { key = 0; delta = area - cur_area }
      else { key = 1; delta = cur_area - area }
      dhz = abs($2 - cur_hz)
      print key, delta, dhz, area, $1, $2
    }
  ' | sort -k1,1n -k2,2n -k3,3n | awk 'NR == 1 { print $5, $6 }'
}

# 把内屏恢复到正常模式（只发内屏一条命令，不动外屏和第三块屏）。
# 必须保留内屏当前的 origin：外屏还在时把它挪到 (0,0) 会直接和外屏重叠。
restore_int_mode() {
  local mode r h dump ox oy
  mode=$(internal_restore_mode) || return 1
  # 统一去掉可能存在的 res: 前缀，避免 res:res:1496x967
  r=$(strip_res "${mode%% *}"); h="${mode##* }"
  [ -n "$r" ] && [ -n "$h" ] || return 1
  dump=$(displays_dump)
  ox=$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $6}')
  oy=$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $7}')
  [ -n "$ox" ] && [ -n "$oy" ] || { ox=0; oy=0; }
  "$DP" "id:$INT_UUID res:$r hz:$h color_depth:8 scaling:on origin:($ox,$oy) degree:0" >/dev/null 2>&1
}

# 直接把档案里内屏的 res/hz 修正为正常模式（同时修 .bak）。
# 与 restore_profile 的区别：不执行、不碰屏幕，只修文件；可在启动早期调用。
repair_profile_internal_mode() {
  local normal rr rh f fixed cur
  normal=$(internal_restore_mode 2>/dev/null || true)
  [ -n "$normal" ] || return 1
  rr=$(strip_res "${normal%% *}"); rh="${normal##* }"
  [ -n "$rr" ] && [ -n "$rh" ] || return 1
  for f in "$PROFILE" "$PROFILE.bak"; do
    [ -s "$f" ] || continue
    cur=$(cat "$f")
    # 历史坏档案可能已经带 res:res: 前缀，这里一并清掉；不必先过白名单，
    # 因为这一步正是为了修复不合法档案。
    fixed=$(printf '%s' "$cur" | sed -E "s/(id:$INT_UUID[^ ]* res:)(res:)*[0-9]+x[0-9]+ hz:[0-9]+/\1$rr hz:$rh/")
    [ "$fixed" = "$cur" ] && continue
    printf '%s\n' "$fixed" > "$TMPF" 2>/dev/null || continue
    if profile_is_sane "$TMPF"; then
      cp "$TMPF" "$f" 2>/dev/null
      log "已修正档案中的内屏模式为 $normal（$(basename "$f")）"
    fi
    rm -f "$TMPF"
  done
}

# 把当前扩展布局存成可重放的命令（displayplacer 自己的输出，可信）
# 铁律：只在「确实是扩展布局」时存档 —— 绝不把镜像状态存成档案，
#       否则还原命令会变成"再镜像一次"，从此永久损坏。
save_profile() {
  layout_is_extended || return 1
  # 存档前确认两块屏都真的在系统里、且都没有被禁用 ——
  # 否则会把"屏幕瞬时离线"的那一刻当成正常布局写进档案。
  both_screens_enabled || { log "暂不存档：内屏/外屏没有同时在线，避免把离线瞬间写进档案"; return 1; }
  local dump cur specs=() spec new int_res int_hz
  dump=$(displays_dump)
  cur=$("$DP" list 2>/dev/null | tail -1)
  case "$cur" in displayplacer\ *id:*) ;; *) return 1 ;; esac
  case "$cur" in *id:*+*) return 1 ;; esac        # 含加号 = 镜像命令，拒绝
  case "$cur" in *enabled:false*) return 1 ;; esac # 重放行里有屏被关掉 = 快照已失效

  # displayplacer 命令里一块屏 = 一个双引号规格，只留下内屏和外屏
  while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    case "$spec" in
      id:"$INT_UUID"*|id:"$EXT_UUID"*) specs+=( "$spec" ) ;;
    esac
  done < <(printf '%s' "$cur" | grep -o '"[^"]*"' | tr -d '"')

  [ "${#specs[@]}" -eq 2 ] || return 1

  int_res=$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $2}')
  int_hz=$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $3}')

  new="displayplacer"
  for spec in "${specs[@]}"; do new="$new \"$spec\""; done

  [ "$new" = "$(cat "$PROFILE" 2>/dev/null)" ] && return 0

  # 如果内屏当前是「镜像降级模式」但 origin 已被还原成扩展布局，这份档案
  # 会把低分辨率固化下来 —— 下次还原就继续带黑边。拒绝覆盖好档案。
  if int_mode_is_degraded; then
    log "拒绝存档：内屏仍停在镜像降级模式 ${int_res}x${int_hz}，保留原档案；等待正常模式"
    return 1
  fi
  remember_int_mode "$int_res $int_hz"

  # 写盘前先过白名单 —— 存档路径也必须过闸。否则坏档案要等到"还原"时才被
  # 发现，而那时屏已经被关掉了（2026-10-15 就是这么黑的）。
  printf '%s\n' "$new" > "$TMPF"
  if ! profile_is_sane "$TMPF"; then
    log "拒绝存档：生成的档案未通过校验（含 enabled:false 或缺模式/坐标），保持原档案不动"
    rm -f "$TMPF"
    return 1
  fi
  rm -f "$TMPF"

  # 覆盖之前先把当前档案滚进 .bak —— 这样"失败换备份重试"才真的有第二份
  [ -s "$PROFILE" ] && cp "$PROFILE" "$PROFILE.bak" 2>/dev/null
  printf '%s\n' "$new" > "$PROFILE"
  log "已记录扩展布局档案（仅内屏+外屏）"
  return 0
}

# 从档案还原：跳过不可用档案、执行后校验、失败换备份、每份最多试 3 次
restore_profile() {
  local src cmd i
  for src in "$PROFILE" "$PROFILE.bak"; do
    [ -s "$src" ] || continue
    profile_is_sane "$src" || { log "跳过不可用档案: $src（含 enabled:false / 缺模式坐标 / 被污染）"; continue; }
    # 双保险：任何"关屏"命令都不许执行 —— 这是唯一能把桌面直接搞黑的路径
    grep -q 'enabled:false' "$src" && { log "拒绝还原（含 enabled:false，会关屏）: $src"; continue; }
    cmd=$(sed "s|^displayplacer|'$DP'|" "$src")

    # 档案里的内屏模式可能是镜像期间被误存的低分辨率（例如 1280x800）。
    # 还原前统一改写成正常模式；否则「还原扩展布局」会把黑边一起还原。
    local normal rr rh repaired=0
    normal=$(internal_restore_mode 2>/dev/null || true)
    if [ -n "$normal" ] && printf '%s' "$cmd" | grep -q "id:$INT_UUID"; then
      rr=$(strip_res "${normal%% *}"); rh="${normal##* }"
      local fixed
      # 同时吃掉历史上已经写坏的 res:res: 前缀
      fixed=$(printf '%s' "$cmd" | sed -E "s/(id:$INT_UUID[^ ]* res:)(res:)*[0-9]+x[0-9]+ hz:[0-9]+/\1$rr hz:$rh/")
      if [ "$fixed" != "$cmd" ]; then
        cmd="$fixed"; repaired=1
        # 改写过内存里的命令后，同时把档案本身修好，避免下次还原又踩同一个坑。
        fixed_plain=$(printf '%s' "$fixed" | sed "s|^'$DP'|displayplacer|")
        printf '%s\n' "$fixed_plain" > "$TMPF" 2>/dev/null || true
        if [ -s "$TMPF" ] && profile_is_sane "$TMPF"; then
          cp "$TMPF" "$src" 2>/dev/null
        fi
        rm -f "$TMPF"
      fi
    fi

    for i in 1 2 3; do
      eval "$cmd" >/dev/null 2>&1
      sleep 1
      if layout_is_extended; then
        [ "$repaired" = "1" ] && log "还原时已修正档案中的内屏模式为 $normal"
        [ "$src" != "$PROFILE" ] && cp "$src" "$PROFILE" 2>/dev/null
        return 0
      fi
    done
  done
  return 1
}

# 用指定模式执行一次镜像折叠，把 displayplacer 的真实报错写进日志。
#
# ⚠️ 只发「镜像对」那一条规格，**绝不把第三块屏（Sidecar/iPad）写进同一条命令**。
#    实测（2026-09-27，本机三屏）：一旦带上第三块屏，macOS 会重排整个桌面，
#    把 iPad 摆到 (0,0) —— 主显示器（菜单栏 / Dock）就跑到 iPad 上去了，
#    而且它的位置会随每次折叠/还原一路漂移。只发镜像对时，主显示器稳稳留在
#    镜像对上（笔记本屏），iPad 原地不动、由 macOS 自己贴着排。
run_mirror_with_mode() {
  local res="$1" hz="$2" depth="$3" scaling="$4"
  local args
  if [ "$hz" = auto ]; then
    args=( "id:$INT_UUID+$EXT_UUID res:$res scaling:${scaling:-on} origin:(0,0) degree:0" )
  else
    args=( "id:$INT_UUID+$EXT_UUID res:$res hz:$hz color_depth:${depth:-8} scaling:${scaling:-on} origin:(0,0) degree:0" )
  fi
  local err rc sig

  err=$("$DP" "${args[@]}" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" != "0" ]; then
    sig=""
    if [ "$rc" -gt 128 ]; then
      sig=" 被信号 $((rc - 128)) 终止"
      if [ $((rc - 128)) -eq 11 ]; then sig="$sig（SIGSEGV，displayplacer 崩了）"; fi
    fi
    log "  ↳ displayplacer 退出码=$rc$sig res=$res hz=$hz"
    [ -n "$err" ] && log "  ↳ stderr: $err"
    log "  ↳ 实际命令: ${args[*]}"     # 崩了的时候这行最关键
    return 1
  fi
  return 0
}

# 切走时把外屏折叠进内屏做镜像。
# 关键：每一步都验证「镜像是不是真的生效了」，全失败就返回 1，
#       让主循环下轮重试，而不是假装成功。
apply_mirror() {
  local dump ir ih idp isc
  dump=$(displays_dump)
  [ -z "$dump" ] && { log "镜像失败：读不到显示列表"; return 1; }

  read -r ir ih idp isc <<< "$(printf '%s\n' "$dump" | awk -F'|' -v id="$INT_UUID" '$1==id{print $2" "$3" "$4" "$5}')"
  if [ -z "$ir" ]; then
    log "镜像失败：读不到内屏参数"
    return 1
  fi
  INT_MODE_BEFORE="$ir $ih"

  local candidates=() m
  while IFS= read -r m; do
    [ -n "$m" ] && candidates+=( "$m" )
  done < <(mirror_candidates)

  if [ "${#candidates[@]}" -eq 0 ]; then
    log "镜像失败：没有可用候选模式"
    return 1
  fi

  local c res hz n=0
  for c in "${candidates[@]}"; do
    res="${c%% *}"
    hz="${c##* }"
    if [ -z "$res" ] || [ -z "$hz" ]; then continue; fi
    n=$((n + 1))
    # 黑边通常来自比例不一致；日志里直接写出比例，方便事后定位
    log "镜像尝试 #$n: res=$res hz=$hz aspect=$(aspect_of "$res" 2>/dev/null || echo '?') 内屏原生比例=$(native_aspect 2>/dev/null || echo '?')"
    if run_mirror_with_mode "$res" "$hz" "$idp" "$isc"; then
      sleep 1
      if mirror_active; then
        # 镜像后内屏被切到了 res 模式；如果它和原生比例差异明显，上下黑边
        # 就会出现。这里只记日志，不阻断折叠（否则鼠标/焦点会留在看不见的屏上）。
        local after aspect_now aspect_native
        after=$("$DP" list 2>/dev/null | awk -v id="$INT_UUID" '
          /^Persistent screen id: / { cur = $4 }
          /^Resolution: / { if (cur == id) r = $2 }
          END { print r }')
        aspect_now=$(aspect_of "$after" 2>/dev/null || true)
        aspect_native=$(native_aspect 2>/dev/null || true)
        if [ -n "$aspect_now" ] && [ -n "$aspect_native" ]; then
          if ! awk -v a="$aspect_now" -v b="$aspect_native" 'BEGIN { d = a - b; if (d < 0) d = -d; exit (d <= b * 0.015) ? 0 : 1 }'; then
            log "  ↳ 注意：镜像模式 $after 与内屏原生比例 $aspect_native 不一致（${aspect_now}），内屏可能出现黑边"
          fi
        fi
        if pair_is_primary; then
          return 0
        fi
        # 镜像成了，但 (0,0) 不在镜像对上 → 菜单栏/Dock 跑到了别的屏
        log "  ↳ 已镜像，但主显示器不在镜像对上（菜单栏可能跑到别的屏）"
        return 0
      fi
      log "  ↳ 命令成功但布局没变成镜像（疑似模式不被接受），换下一个"
    fi
  done

  log "镜像折叠失败：试过 ${#candidates[@]} 个模式"
  return 1
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

# ---------------- 档案校验自测 ----------------
# LIDMATE_TEST_PROFILE=<文件> bash displaysync.sh
# 只对指定文件跑档案白名单校验并打印结果，不碰任何显示状态。
# 用途：回归测试「退出即黑屏」那个 bug（见 tools/test-profile-guard.sh）。
if [ -n "${LIDMATE_TEST_PROFILE:-}" ]; then
  if profile_is_sane "$LIDMATE_TEST_PROFILE"; then echo "可用"; exit 0
  else echo "不可用"; exit 1; fi
fi

# ---------------- 只读自检 ----------------
# LIDMATE_DOCTOR=1 bash displaysync.sh
# 只打印诊断信息并退出，绝不改动任何显示状态。
# 出问题时先跑这个，它能直接告诉你是"模式不支持"还是"读数/档案"的问题。
if [ "${LIDMATE_DOCTOR:-0}" = "1" ]; then
  echo "外屏 uuid   : $EXT_UUID"
  echo "内屏 uuid   : $INT_UUID"
  echo "本机输入码  : $MAC_INPUT"
  echo
  echo "── 当前接的屏 ──"
  "$DP" list 2>/dev/null | awk '
    /^Persistent screen id: / { u = $4 }
    /^Type: /        { t = substr($0, 7) }
    /^Resolution: /  { r = $2 }
    /^Hertz: /       { h = $2 }
    /^Origin: /      { printf "  %s…  %-26s %-11s %4s  %s\n", substr(u,1,8), t, r, h, $2 }'
  echo
  if ext_present; then
    echo "外屏在系统枚举里    : 是"
    echo "外屏 VCP 0x60 读数  : $(read_input)"
  else
    echo "外屏在系统枚举里    : 否（已从 macOS 消失 —— 可能是被 enabled:false 摘掉了）"
  fi
  if layout_is_extended; then echo "当前布局            : 扩展"; else echo "当前布局            : 镜像"; fi
  echo
  echo "── 镜像折叠能不能成功 ──"
  d=$(displays_dump)
  irec=$(printf '%s\n' "$d" | awk -F'|' -v id="$INT_UUID" '$1==id{print $2" " $3" "$4" "$5}')
  echo "内屏当前模式        : ${irec:-读不到}"
  inres="${irec%% *}"
  if [ -n "$inres" ]; then
    if modes_of "$EXT_UUID" | grep -q "^res:$inres "; then
      echo "外屏支持这个模式    : 是 ✅（镜像直接用内屏分辨率，笔记本桌面不变形）"
    else
      echo "外屏支持这个模式    : 未列出（先试内屏模式的自动刷新率，再试共同模式）"
    fi
  fi
  echo "镜像实际会用的模式（按优先级）:"
  if mirror_candidates | grep -q .; then
    while IFS=' ' read -r r h; do
      if [ "$h" = auto ]; then echo "  ${r} @ 自动刷新率"; else echo "  ${r} @ ${h}Hz"; fi
    done < <(mirror_candidates)
  else
    echo "  （一个都没有 → 这两块屏无法镜像折叠）"
  fi
  echo "折叠时会执行的命令（只预览，不执行）:"
  if ! preview_mirror_command | sed 's/^/  /'; then
    echo "  （生成失败）"
  fi
  echo
  echo "── 布局档案 ──"
  for f in "$PROFILE" "$PROFILE.bak"; do
    if [ ! -s "$f" ]; then
      echo "  $(basename "$f"): 不存在"
    elif profile_is_sane "$f"; then
      echo "  $(basename "$f"): 可用 ✅"
    else
      reason="被污染"
      case "$(cat "$f" 2>/dev/null)" in
        *enabled:false*|*enabled:no*) reason="含 enabled:false —— 重放它会把屏关掉（2026-10-15 黑屏元凶）" ;;
        *id:*+*)                      reason="含加号 = 镜像命令，不是扩展布局" ;;
      esac
      echo "  $(basename "$f"): 不可用 ❌（$reason）"
    fi
  done
  exit 0
fi

# ---------------- 启动：记录现状，必要时补一次档案 ----------------
# 先修档案文件：即使这次外屏不在，也要把上次镜像期间误存的低分辨率纠正掉。
repair_profile_internal_mode 2>/dev/null || true

if ext_present; then
  if layout_is_extended; then
    state="ours"
    # 上次运行可能在外屏消失/崩溃前把内屏留在了镜像模式；先在扩展布局里
    # 把内屏纠正回来，再记录档案，避免把低分辨率固化成正常档案。
    if int_mode_is_degraded; then
      if restore_int_mode; then
        log "启动时发现内屏停在降级模式，已恢复为 $(internal_restore_mode)"
        sleep 1
      fi
    fi
    save_profile
  else
    state="away"
  fi
else
  state="absent"
  # App 崩溃 / 外屏拔掉后重启：内屏可能还停在镜像用的低分辨率，先恢复。
  if int_mode_is_degraded; then
    if restore_int_mode; then log "启动时外屏不在，已把内屏从降级模式恢复到 $(internal_restore_mode)"; fi
  fi
fi
OWNER_PID=$PPID
log "=== 显示器跟随：启动 state=$state mac_input=$MAC_INPUT pid=$$ 父进程=$OWNER_PID ==="

loops=0
last_v="<none>"
quiet=0
hist=""
restore_warned=0
mirror_warned=0

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
        # 稳态不必每轮整理档案（那要额外跑两次 displayplacer list），
        # 每 15 轮兜一次用户手工改分辨率/排列的情况
        if [ $((loops % 15)) -eq 0 ] && layout_is_extended; then
          save_profile
        fi
      fi
      ;;
    away)
      if [ "$state" != "away" ]; then
        # 失败过就退避到下一个重试窗口，避免每轮都狂敲 displayplacer
        if [ "$mirror_warned" = "1" ] && [ $((loops % MIRROR_RETRY)) -ne 0 ]; then
          :
        else
          save_profile
          if apply_mirror; then
            log "外屏切走了 (input=$v, 窗口=[$hist]) → 镜像到内屏（鼠标/焦点锁定在笔记本）"
            state="away"
            mirror_warned=0
          elif [ "$mirror_warned" = "0" ]; then
            log "外屏切走了，但镜像折叠失败 → 保持原状、继续重试（上方有 displayplacer 报错）"
            mirror_warned=1
          fi
        fi
      fi
      ;;
    absent)
      if [ "$state" != "absent" ]; then
        log "外屏已从系统消失 (macOS 自行处理)，等它回来"
        state="absent"
        # 如果消失时桌面还在镜像状态，内屏会停在镜像模式（常见是 1280x800）。
        # 外屏既然不在了，就没有镜像的必要，立即把内屏恢复成正常模式。
        if int_mode_is_degraded; then
          if restore_int_mode; then
            log "外屏消失后已恢复内屏模式为 $(internal_restore_mode)"
          else
            log "外屏消失后恢复内屏模式失败（找不到可用模式）"
          fi
        fi
      fi
      ;;
  esac

  if [ "$present" = "0" ]; then sleep 1; else sleep "$POLL"; fi
done
