# LidMate

**中文** | [English](README.en.md)

一个小巧的 macOS 菜单栏应用，专为「笔记本 + 外接显示器」的场景而生：
**合盖即休眠**；当显示器切换到其他信号源（比如游戏机，或接在 HDMI/DP 上的
办公电脑）时，**自动把桌面镜像折叠到笔记本屏上**；切回来时再恢复扩展布局。

下载已编译版本 [![Download](https://img.shields.io/github/v/release/dhshtdx/LidMate?label=download&color=blue)](https://github.com/dhshtdx/LidMate/releases/latest)
---

## ⚠️ 先做兼容性自检（很重要）

**LidMate 的「显示器跟随」完全依赖一个硬件能力：你的显示器能不能通过
DDC/CI 读出「当前输入源」(VCP `0x60`)。**

很多显示器**不支持读这个寄存器**，或者无论切到哪路输入都返回同一个值 ——
这些机器上 LidMate **完全无效**。所以装之前请先自检：

```bash
bash tools/selftest.sh
```

脚本会引导你把显示器切一次输入源，然后告诉你结论。**只有显示 ✅ 才值得继续。**

---

## 它能做什么

### 1. 合盖即睡

macOS 在「接电源 + 接外接显示器」时会进入 **clamshell 模式**：合上盖子后
电脑保持唤醒、只驱动外屏，而且**系统设置里没有任何开关能关掉它**。
LidMate 每秒检查一次盖子状态，合上就执行 `pmset sleepnow`。

### 2. 显示器跟随

当外接显示器**切到别的信号源**（比如你把它切给了 Windows 主机 / 游戏机）：

- 桌面自动**镜像折叠到笔记本内屏**
- 于是**鼠标无处可去、键盘焦点无处可逃、窗口不可能被丢在看不见的屏上**
- 菜单栏、Dock 全都在笔记本上

切回本机信号源后自动还原成扩展布局。

---

## 安装

1. 下载 `LidMate.dmg`，挂载后把 `LidMate.app` 拖进「应用程序」
2. 首次打开如果提示「来自身份不明的开发者」（因为只是 ad-hoc 签名），
   右键 → 打开
3. 菜单栏会出现一个笔记本形状的图标（**没有 Dock 图标、不会打开窗口**，
   这是设计如此）
4. 首次启动会自动识别显示器并学习本机输入码
5. 点菜单栏图标 → 打开「合盖即睡」和「显示器跟随」

> 想开机自启：菜单里勾选「登录时自动启动」。

---

## 菜单说明

```
合盖即睡                        ← 开关
显示器跟随                      ← 开关
────────────────
跟随的显示器 ▸                  ← 有多块外屏时在这里选
重新学习当前显示器               ← 换线/换接口后点一下
显示器自检（兼容性）              ← 在终端里跑兼容性自检
────────────────
登录时自动启动
查看日志                        ← ~/Library/Logs/LidMate.log
────────────────
关于 LidMate
退出 LidMate
```

---

## 工作原理

```
每 1 秒读一次显示器的 VCP 0x60（当前输入源）
      │
      ├─ 等于「本机输入码」 ────────→ 保持/还原 扩展布局，外屏为主屏
      │
      └─ 不等于 ──┐
                  │  滑窗投票：最近 4 次里 ≥2 次异常
                  ↓
              镜像折叠到内屏（鼠标与焦点锁在笔记本）
```

**分辨率、刷新率、排列全部实时从 `displayplacer list` 读取并原样保留**，
不会覆盖你在系统设置里的任何偏好。扩展布局会被存成一份"档案"
（`~/Library/Logs/LidMate.log.layout`），还原时直接重放它。

---

## 踩过的坑（这部分可能是本仓库最有价值的内容）

### ① 绝对不要用 `enabled:false` 去「关掉外屏」

一开始我们的做法是切走时执行
`displayplacer "id:<外屏> enabled:false"`，把外屏从布局里摘掉。结果是：

- 外屏会**立刻从 macOS 的显示枚举里消失**
- 而显示器切回本机输入源时，**不会产生任何 HPD 变化**
- 于是 macOS 永远不把屏加回来，`enabled:true` 也找不到它
- **只能拔插信号线才能恢复**

实测复现了两次，睡眠唤醒也救不回来。详见下面第 ③ 点。

### ② 切换瞬间 DDC 读数会「反复横跳」

显示器切换输入源的那几秒里，VCP `0x60` 的读数会在「本机输入码」和一个
恒定垃圾值（我们这台是 `2809`）之间来回跳。

用朴素的「连续 N 次异常」判定会被中间偶发的正常值**不断清零**，
触发时间被拖到十几秒后，甚至永远不触发。

**解法：滑窗投票** —— 看最近 `WINDOW` 次采样，其中异常次数 ≥ `BAD_NEEDED`
就认定切走。这样既能立刻触发，又仍然忽略单次毛刺：

```bash
hist="${hist}G"          # 或 B
hist="${hist: -$WINDOW}" # 只保留最近 WINDOW 次
badn=$(printf '%s' "$hist" | tr -cd 'B' | wc -c)
```

### ③ 想靠监测 HPD 来检测切换？此路不通

很自然的想法是：既然 macOS 在禁用后不再监测 HPD，那我自己写个后台监测
`AppleATCDPAltModePort` 的 `SinkActive` / `Plug` 事件不就行了？

我们把 IORegistry 翻了个底朝天，结论是：

```
切走前:  atc1-dpphy SinkActive=1(事件=55) Plug=33
切走后:  atc1-dpphy SinkActive=1(事件=55) Plug=33   ← 一个事件都没新增
```

**原因：显示器切到别的输入源时，DP 链路始终保持训练状态**（HPD 恒高、
AUX/DDC 通道也还活着 —— 这正是还能读到那个 `2809` 的原因）。
驱动层根本没东西可记，也就没有信号可监测。

### ④ 档案污染：一次「假成功」会导致永久损坏

最初的实现里，还原失败后 `state` 仍被标成成功，于是下一次切走时
`save_profile` 把**镜像状态**存成了「扩展布局档案」。此后每一次"还原"
都只是**再镜像一次** —— 卡死在镜像状态。

**解法（三道防线）：**

1. `save_profile` 只在**确实是扩展布局**时才存档，且**拒绝任何含 `+`
   （镜像语法）的命令**
2. `restore_profile` 执行后**校验结果**，失败自动改用 `.bak` 备份，
   每份最多重试 3 次
3. **还原失败绝不把状态标成成功**（会继续重试，而不是假装完成）

---

## 已知限制

- **只支持 Apple Silicon**。`m1ddc` 不支持 Intel Mac；Intel 需要换
  `ddcctl` 或 Better Display 的 CLI（欢迎 PR）
- **只跟随一块外接显示器**（可以在菜单里选哪一块）
- **依赖显示器支持读 VCP `0x60`** —— 见开头的自检
- 镜像折叠期间，外屏会以**内屏的分辨率**被驱动。因为那时显示器正在放
  别的设备，通常看不到，切回来会立刻还原
- 切换响应约 **2–4 秒**（由 `POLL` / `WINDOW` / `BAD_NEEDED` 决定，
  脚本顶部可调）

---

## 开发 / 构建

```bash
# 1. 准备第三方二进制（见 vendor/README.md）
#    vendor/m1ddc
#    vendor/displayplacer

# 2. 构建
bash build.sh
# 产出 dist/LidMate.app 和 dist/LidMate.dmg
```

需要 Xcode Command Line Tools（`swiftc` / `iconutil` / `hdiutil` / `codesign`）。

### 项目结构

```
LidMate/
├── LICENSE
├── THIRD-PARTY-NOTICES.md      # m1ddc / displayplacer 的 MIT 声明
├── README.md                   # 中文说明（本文件）
├── README.en.md                # English
├── build.sh
├── src/
│   ├── main.swift              # 菜单栏 App（发现显示器 / 学习输入码 / 管理子进程）
│   ├── Info.plist              # LSUIElement = 无 Dock 图标
│   └── resources/
│       ├── clamshell.sh        # 合盖即睡
│       └── displaysync.sh      # 显示器跟随（核心逻辑）
├── tools/
│   ├── makeicon.swift
│   └── selftest.sh             # 兼容性自检
└── vendor/                     # 第三方二进制
```

### 调试

日志：`~/Library/Logs/LidMate.log`

```
读数变化: present=1 input=[2809] 窗口=[GGGB] want=ours state=ours
外屏切走了 (input=2809, 窗口=[BBGB]) → 镜像到内屏（鼠标/焦点锁定在笔记本）
读数变化: present=1 input=[16] 窗口=[GGGG] want=ours state=away
外屏在显示本机 (input=16) → 还原扩展布局、外屏为主屏
```

`窗口=[GGGB]` 是滑窗投票的中间状态，`G` = 读到本机输入码，`B` = 异常。

---

## 许可

MIT © 王灿（@dhshtdx）

捆绑的第三方工具同样为 MIT：
[m1ddc](https://github.com/waydabber/m1ddc)、
[displayplacer](https://github.com/jakehilborn/displayplacer)。
完整声明见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。
