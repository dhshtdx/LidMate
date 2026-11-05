// ============================================================
//  LidMate — macOS 菜单栏小工具
//
//  两个功能：
//    1) 合盖即睡   —— 即使接电源 + 接外接显示器，合盖也立即休眠
//    2) 显示器跟随 —— 外接显示器切到别的信号源时，把桌面镜像折叠
//                     到内屏（鼠标/焦点都锁在笔记本上）；切回来自动还原
//
//  本程序是 LSUIElement 应用：只在菜单栏出现，没有 Dock 图标，
//  也不会打开任何窗口。两个功能各由一个后台脚本子进程实现，
//  退出程序时会一并结束它们。
//
//  依赖的第三方二进制（均为 MIT）：
//    · m1ddc        https://github.com/waydabber/m1ddc
//    · displayplacer https://github.com/jakehilborn/displayplacer
// ============================================================

import Cocoa

let APP_NAME = "LidMate"

private let KEY_CLAMSHELL = "clamshellEnabled"
private let KEY_DISPLAY   = "displayFollowEnabled"
private let KEY_EXT_UUID  = "externalDisplayUUID"
private let KEY_INT_UUID  = "internalDisplayUUID"
private let KEY_MAC_INPUT = "macInputCode"
private let KEY_ONBOARDED = "hasOnboarded"
private let LOGIN_LABEL   = "app.lidmate"

/// displayplacer list 里的一块屏
struct DisplayEntry {
    let uuid: String
    let type: String
    let resolution: String
    var isInternal: Bool {
        let t = type.lowercased()
        return t.contains("built in") || t.contains("built-in")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var clamshellTask: Process?
    private var displayTask: Process?

    private let defaults = UserDefaults.standard

    // MARK: - 日志

    private let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("LidMate.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }()

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp)  [App:\(getpid())] \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    // MARK: - 路径

    private var resourcesURL: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }
    private var bundledBinDir: String { resourcesURL.appendingPathComponent("bin").path }

    /// 跑一个外部工具并取回 stdout。
    /// 必须带超时：DDC 读取在显示器断电 / 切到别的输入源时会一直不返回，
    /// 而这些调用发生在主线程上，没有超时就是一次无法取消的转菊花。
    private func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 3) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try task.run() } catch { done.signal(); return }
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(task.processIdentifier, SIGKILL)
            log("外部工具超时(\(Int(timeout))s): \((path as NSString).lastPathComponent) \(args.joined(separator: " "))")
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private var displayplacerPath: String {
        URL(fileURLWithPath: bundledBinDir).appendingPathComponent("displayplacer").path
    }
    private var m1ddcPath: String {
        URL(fileURLWithPath: bundledBinDir).appendingPathComponent("m1ddc").path
    }

    // MARK: - 显示器发现 / 学习

    /// 解析 displayplacer list，拿到所有屏
    private func displayList() -> [DisplayEntry] {
        let out = runTool(displayplacerPath, ["list"])
        var result: [DisplayEntry] = []
        var uuid = "", type = "", res = ""
        func flush() {
            if !uuid.isEmpty {
                result.append(DisplayEntry(uuid: uuid, type: type, resolution: res))
            }
            uuid = ""; type = ""; res = ""
        }
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Persistent screen id: ") {
                flush()
                uuid = String(line.dropFirst("Persistent screen id: ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Type: ") {
                type = String(line.dropFirst("Type: ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Resolution: ") {
                res = String(line.dropFirst("Resolution: ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return result
    }

    /// 读某块屏的 DDC 当前输入源；读不到返回 nil
    private func ddcInput(uuid: String) -> String? {
        let out = runTool(m1ddcPath, ["display", "uuid=\(uuid)", "get", "input"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil else {
            return nil
        }
        return out
    }

    /// 学习「本机输入码」：连读 3 次，读数一致才接受。
    ///
    /// 只读一次是不够的 —— 显示器切换输入源的那几秒里，VCP 0x60 会在
    /// 本机码和一个恒定垃圾值（这台机器上是 2809）之间横跳。单次采样
    /// 正好落在垃圾值上，就会把它当成「本机输入码」存下来，跟随逻辑
    /// 从此整体反向，而且完全静默。
    private func learnMacInput(uuid: String) -> String? {
        var samples: [String] = []
        for _ in 0..<3 {
            guard let v = ddcInput(uuid: uuid) else { return nil }
            samples.append(v)
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard Set(samples).count == 1 else {
            log("学习 \(uuid.prefix(8)) 时读数不稳定: \(samples.joined(separator: ",")) → 放弃，避免学到垃圾值")
            return nil
        }
        return samples[0]
    }
    /// 自动识别内屏 / 外屏，并学习本机在显示器上占用的输入码
    /// - Parameter preferred: 用户在菜单里明确点选的外屏 uuid
    @discardableResult
    private func learnDisplays(verbose: Bool, preferred: String? = nil) -> Bool {
        let entries = displayList()
        guard !entries.isEmpty else {
            if verbose { info("读不到显示器列表", "请确认 displayplacer 能正常工作。") }
            return false
        }
        guard let internalDisplay = entries.first(where: { $0.isInternal }) else {
            if verbose { info("没找到内置屏", "LidMate 只适用于带内置屏的 Mac 笔记本。") }
            return false
        }
        let candidates = entries.filter { $0.uuid != internalDisplay.uuid }
        guard !candidates.isEmpty else {
            if verbose { info("没检测到外接显示器", "请接好外屏后再试。") }
            return false
        }

        // 用户主动触发时先确认：显示器此刻必须正显示这台 Mac。
        // 否则学到的是"别的设备"的输入码，跟随功能会整个反过来。
        if verbose && !confirmMonitorShowsThisMac() { return false }

        // 候选顺序：用户点选的 → 上次存的 → 其余。
        // 关键在于「逐块探测」：只有 VCP 0x60 真的读得出来的屏才能当外屏。
        // Sidecar / 虚拟屏读不出来，会被自动跳过 —— 否则它一旦被学成外屏，
        // 每轮读数都是 INVALID，工具会永久停在"切走"状态（就是这样"失灵"的）。
        let saved = preferred ?? defaults.string(forKey: KEY_EXT_UUID) ?? ""
        let ordered = candidates.filter { $0.uuid == saved } + candidates.filter { $0.uuid != saved }

        var picked: (DisplayEntry, String)?
        var tried: [String] = []
        for d in ordered {
            tried.append("· \(d.type) \(d.resolution)")
            if let code = learnMacInput(uuid: d.uuid) {
                picked = (d, code)
                break
            }
        }
        guard let (external, code) = picked else {
            if verbose {
                info("没有可用的外接显示器",
                     """
                     检测到的外接屏都读不到输入源（DDC VCP 0x60）：

                     \(tried.joined(separator: "\n"))

                     Sidecar / 虚拟屏不支持这个寄存器，会被自动跳过；
                     真正的显示器请先跑一次「显示器自检」。
                     """)
            }
            return false
        }

        // 验证通过之后才落盘。旧版先把 uuid 写进去再去验证，
        // 一旦选中读不到 DDC 的屏（比如 iPad），配置就被永久写脏了。
        defaults.set(internalDisplay.uuid, forKey: KEY_INT_UUID)
        defaults.set(external.uuid, forKey: KEY_EXT_UUID)
        defaults.set(code, forKey: KEY_MAC_INPUT)
        log("学习完成 内屏=\(internalDisplay.uuid) 外屏=\(external.uuid) 本机输入码=\(code)")
        if verbose {
            info("学习完成",
                 "内屏：\(internalDisplay.resolution)\n外屏：\(external.type) \(external.resolution)\n本机输入码：\(code)\n\n现在可以打开「显示器跟随」了。")
        }
        return true
    }

    /// 学错输入码是唯一一个「功能静默反向」的故障，值得多问一句
    private func confirmMonitorShowsThisMac() -> Bool {
        let alert = NSAlert()
        alert.messageText = "学习前请确认"
        alert.informativeText = """
        请让「跟随的显示器」此刻正显示这台 Mac（在显示器上切回本机输入源）再继续。

        如果它正显示别的设备（游戏机 / 另一台电脑），LidMate 会把那个设备的输入码
        误学成「本机」，跟随功能会整个反过来，而且不会有任何报错。
        """
        alert.addButton(withTitle: "现在显示的是本机，继续")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var configReady: Bool {
        let e = defaults.string(forKey: KEY_EXT_UUID) ?? ""
        let i = defaults.string(forKey: KEY_INT_UUID) ?? ""
        let m = defaults.string(forKey: KEY_MAC_INPUT) ?? ""
        return !e.isEmpty && !i.isEmpty && !m.isEmpty
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 单实例：已经有另一份在跑就明确告知，而不是默默退出
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "app.lidmate")
            .filter { $0.processIdentifier != me }
        if !others.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(APP_NAME) 已经在运行了"
            alert.informativeText = "它就在屏幕右上角的菜单栏里，点那个笔记本形状的图标即可开关功能。\n\n本程序没有 Dock 图标、也不会打开窗口，所以「看不到」是正常的。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: APP_NAME) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = " \(APP_NAME) "   // 图标取不到就退化文字，保证可见
            }
            button.toolTip = APP_NAME
        }

        killStaleWatchers()
        // 这里原本是「配置不全就静默学一次」。去掉它：
        // 静默学习无法确认显示器此刻显示的是不是本机，一旦正好撞上"切走"
        // 状态，就会把垃圾值学成输入码。配置不全时交给首次启动的对话框，
        // 或菜单里的「重新学习当前显示器」—— 两者都会先确认。
        rebuildMenu()

        if defaults.bool(forKey: KEY_CLAMSHELL) { startClamshell() }
        if defaults.bool(forKey: KEY_DISPLAY)   { startDisplayFollow() }

        log("启动完成 clamshell=\(defaults.bool(forKey: KEY_CLAMSHELL)) display=\(defaults.bool(forKey: KEY_DISPLAY)) configReady=\(configReady)")

        if !defaults.bool(forKey: KEY_ONBOARDED) {
            defaults.set(true, forKey: KEY_ONBOARDED)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                if self.configReady {
                    self.info("\(APP_NAME) 已启动",
                              "它常驻在屏幕右上角的菜单栏。点图标即可开关「合盖即睡」和「显示器跟随」。\n\n本程序没有 Dock 图标，也不会打开窗口。")
                } else {
                    _ = self.learnDisplays(verbose: true)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopClamshell()
        // 退出前一定要把扩展布局放回去：如果退出时外屏正切在别的设备上，
        // 桌面就停在镜像状态，而进程一走就再没人还原它了。
        if displayTask != nil { restoreLayout() }
        stopDisplayFollow()
        log("退出")
    }

    // MARK: - 子进程

    private func makeTask(script: String) -> Process? {
        let scriptURL = resourcesURL.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            log("找不到脚本 \(scriptURL.path)")
            return nil
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        env["LIDMATE_BIN"] = bundledBinDir
        env["LIDMATE_LOG"] = logURL.path
        env["LIDMATE_EXT_UUID"] = defaults.string(forKey: KEY_EXT_UUID) ?? ""
        env["LIDMATE_INT_UUID"] = defaults.string(forKey: KEY_INT_UUID) ?? ""
        env["LIDMATE_MAC_INPUT"] = defaults.string(forKey: KEY_MAC_INPUT) ?? ""
        task.environment = env

        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            task.standardOutput = handle
            task.standardError = handle
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.log("\(script) 子进程退出 code=\(finished.terminationStatus) reason=\(finished.terminationReason)")
                guard script == "displaysync.sh",
                      self.displayTask === finished,
                      self.defaults.bool(forKey: KEY_DISPLAY),
                      self.configReady else { return }
                self.displayTask = nil
                self.log("显示器跟随意外退出，3 秒后重启")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.displayTask == nil,
                          self.defaults.bool(forKey: KEY_DISPLAY),
                          self.configReady else { return }
                    self.startDisplayFollow()
                }
            }
        }
        do {
            try task.run()
            log("\(script) 子进程 pid=\(task.processIdentifier)")
            return task
        } catch {
            log("启动 \(script) 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func startClamshell() {
        guard clamshellTask == nil else { return }
        clamshellTask = makeTask(script: "clamshell.sh")
        log("合盖即睡 → 启动")
    }
    private func stopClamshell() { clamshellTask?.terminate(); clamshellTask = nil }

    private func startDisplayFollow() {
        guard displayTask == nil else { return }
        displayTask = makeTask(script: "displaysync.sh")
        log("显示器跟随 → 启动")
    }
    private func stopDisplayFollow() { displayTask?.terminate(); displayTask = nil }

    /// 还原扩展布局（重放脚本记录的档案），并等它跑完（有上限，别拖住退出）。
    /// 关闭跟随和退出 App 都走这里，两条路径行为一致。
    ///
    /// ⚠️ 2026-10-15 事故复盘：这里曾经**无条件 eval 档案**，既不校验内容、
    ///    也不看退出码，最后还无条件写一句"已还原扩展双屏布局"。
    ///    而屏幕瞬时离线时 `displayplacer list` 的重放行会退化成
    ///    `displayplacer "id:外屏 enabled:false" "id:内屏 enabled:false"`——
    ///    这个快照被存进档案后，退出 App 就等于把两块屏一起关掉：
    ///    用户看到"一退出 LidMate 就黑屏"，日志里却写着还原成功。
    ///    现在改为：先校验 → 再执行 → 按真实退出码报话。
    private func restoreLayout() {
        let profilePath = logURL.appendingPathExtension("layout").path
        guard FileManager.default.fileExists(atPath: profilePath) else { return }
        guard let raw = try? String(contentsOfFile: profilePath, encoding: .utf8) else { return }

        let profile = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.hasPrefix("displayplacer "), !profile.contains("\n") else {
            log("还原跳过：档案格式非法（不是单行 displayplacer 命令）")
            return
        }
        // 唯一能"一键把桌面搞黑"的路径就是重放一条关屏命令 —— 直接拒绝
        guard !profile.contains("enabled:false") else {
            log("还原跳过：档案含 enabled:false（会把屏关掉），已忽略；请让跟随功能重新记录一次")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "eval \"$(sed 's|^displayplacer|DPPATH|' 'PROFILEPATH')\""]
            .map { $0.replacingOccurrences(of: "DPPATH", with: displayplacerPath)
                     .replacingOccurrences(of: "PROFILEPATH", with: profilePath) }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return }
        let deadline = Date().addingTimeInterval(3)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let timedOut = task.isRunning
        if timedOut { task.terminate() }
        if !timedOut && task.terminationStatus == 0 {
            log("已还原扩展双屏布局")
        } else {
            log("还原扩展布局失败（displayplacer 退出码=\(task.terminationStatus)\(timedOut ? "，超时被终止" : "")），桌面可能仍是折叠状态")
        }
    }

    /// 清掉上一次运行残留的守护脚本（App 被强杀时子进程会变成孤儿）
    private func killStaleWatchers() {
        for script in ["displaysync.sh", "clamshell.sh"] {
            let full = resourcesURL.appendingPathComponent(script).path
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            // -x 要求整条命令行完全一致，避免误杀命令行里恰好含该路径的其它进程
            task.arguments = ["-f", "-x", "/bin/bash \(full)"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    private func launchctl(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - 登录项

    private var loginPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(LOGIN_LABEL).plist")
    }
    private var loginItemInstalled: Bool {
        FileManager.default.fileExists(atPath: loginPlistURL.path)
    }

    private func installLoginItem() {
        let exe = Bundle.main.executableURL?.path ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(LOGIN_LABEL)</string>
          <key>ProgramArguments</key>
          <array><string>\(exe)</string></array>
          <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(at: loginPlistURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? plist.write(to: loginPlistURL, atomically: true, encoding: .utf8)
        launchctl(["bootout", "gui/\(getuid())/\(LOGIN_LABEL)"])
        launchctl(["bootstrap", "gui/\(getuid())", loginPlistURL.path])
        log("已开启登录时自动启动")
    }

    private func removeLoginItem() {
        launchctl(["bootout", "gui/\(getuid())/\(LOGIN_LABEL)"])
        try? FileManager.default.removeItem(at: loginPlistURL)
        log("已关闭登录时自动启动")
    }

    // MARK: - 菜单

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "\(APP_NAME)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let clamshell = NSMenuItem(title: "合盖即睡",
                                   action: #selector(toggleClamshell), keyEquivalent: "")
        clamshell.target = self
        clamshell.state = defaults.bool(forKey: KEY_CLAMSHELL) ? .on : .off
        menu.addItem(clamshell)

        let display = NSMenuItem(title: "显示器跟随",
                                 action: #selector(toggleDisplayFollow), keyEquivalent: "")
        display.target = self
        display.state = defaults.bool(forKey: KEY_DISPLAY) ? .on : .off
        menu.addItem(display)
        if !configReady {
            display.isEnabled = false
            display.toolTip = "先点「重新学习当前显示器」"
        }

        menu.addItem(.separator())

        // 跟随哪一块外屏
        let picker = NSMenuItem(title: "跟随的显示器", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let savedExt = defaults.string(forKey: KEY_EXT_UUID) ?? ""
        let externals = displayList().filter { !$0.isInternal }
        if externals.isEmpty {
            let none = NSMenuItem(title: "（未检测到外接显示器）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for d in externals {
                let item = NSMenuItem(title: "\(d.type) · \(d.resolution)",
                                      action: #selector(pickExternal(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = d.uuid
                item.state = (d.uuid == savedExt) ? .on : .off
                sub.addItem(item)
            }
        }
        picker.submenu = sub
        menu.addItem(picker)

        let relearn = NSMenuItem(title: "重新学习当前显示器",
                                 action: #selector(relearnDisplays), keyEquivalent: "")
        relearn.target = self
        menu.addItem(relearn)

        let selftest = NSMenuItem(title: "显示器自检（兼容性）",
                                  action: #selector(runSelftest), keyEquivalent: "")
        selftest.target = self
        menu.addItem(selftest)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "登录时自动启动",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemInstalled ? .on : .off
        menu.addItem(login)

        let openLog = NSMenuItem(title: "查看日志", action: #selector(openLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        let doctor = NSMenuItem(title: "只读诊断（不改布局）",
                                action: #selector(runDoctor), keyEquivalent: "")
        doctor.target = self
        menu.addItem(doctor)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 \(APP_NAME)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出 \(APP_NAME)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - 菜单动作

    @objc private func toggleClamshell() {
        let now = !defaults.bool(forKey: KEY_CLAMSHELL)
        defaults.set(now, forKey: KEY_CLAMSHELL)
        if now { startClamshell() } else { stopClamshell() }
        rebuildMenu()
    }

    @objc private func toggleDisplayFollow() {
        let now = !defaults.bool(forKey: KEY_DISPLAY)
        if now && !configReady && !learnDisplays(verbose: true) { return }
        defaults.set(now, forKey: KEY_DISPLAY)
        if now {
            startDisplayFollow()
        } else {
            stopDisplayFollow()
            restoreLayout()
        }
        rebuildMenu()
    }

    @objc private func pickExternal(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        // 不要先写 KEY_EXT_UUID：这块屏可能就是读不到 DDC 的（Sidecar/iPad），
        // 先写再验证失败，配置就被永久写脏了。交给 learnDisplays 验证后落盘。
        guard learnDisplays(verbose: true, preferred: uuid) else {
            rebuildMenu()
            return
        }
        if displayTask != nil { stopDisplayFollow(); startDisplayFollow() }
        rebuildMenu()
    }

    @objc private func relearnDisplays() {
        if learnDisplays(verbose: true), displayTask != nil {
            stopDisplayFollow()
            startDisplayFollow()
        }
        rebuildMenu()
    }

    @objc private func runSelftest() {
        openInTerminal("selftest.sh")
    }

    /// 只读诊断：把它跑在终端里，输出可以直接贴出来看
    @objc private func runDoctor() {
        openInTerminal("doctor.sh")
    }

    private func openInTerminal(_ scriptName: String) {
        let script = resourcesURL.appendingPathComponent(scriptName)
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: script.path) {
            NSWorkspace.shared.open([script], withApplicationAt: term,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            info("找不到脚本 \(scriptName)", "\(scriptName) 没有被打包进来。")
        }
    }

    @objc private func toggleLoginItem() {
        if loginItemInstalled { removeLoginItem() } else { installLoginItem() }
        rebuildMenu()
    }

    @objc private func openLog() { NSWorkspace.shared.open(logURL) }

    @objc private func showAbout() {
        let ext = defaults.string(forKey: KEY_EXT_UUID) ?? "未设置"
        let code = defaults.string(forKey: KEY_MAC_INPUT) ?? "未设置"
        let alert = NSAlert()
        alert.messageText = "\(APP_NAME)"
        alert.informativeText = """
        合盖即睡：\(defaults.bool(forKey: KEY_CLAMSHELL) ? "已开启" : "已关闭")
        显示器跟随：\(defaults.bool(forKey: KEY_DISPLAY) ? "已开启" : "已关闭")
        跟随的外屏：\(ext.prefix(8))…
        本机输入码：\(code)
        登录时启动：\(loginItemInstalled ? "已开启" : "已关闭")

        日志：~/Library/Logs/LidMate.log

        依赖：m1ddc 与 displayplacer（均为 MIT 许可）
        """
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func info(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
