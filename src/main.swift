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

    private func runTool(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
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

    /// 自动识别内屏 / 外屏，并学习本机在显示器上占用的输入码
    @discardableResult
    private func learnDisplays(verbose: Bool) -> Bool {
        let entries = displayList()
        guard !entries.isEmpty else {
            if verbose { info("读不到显示器列表", "请确认 displayplacer 能正常工作。") }
            return false
        }
        guard let internalDisplay = entries.first(where: { $0.isInternal }) else {
            if verbose { info("没找到内置屏", "LidMate 只适用于带内置屏的 Mac 笔记本。") }
            return false
        }
        // 外屏：优先沿用用户已选的；否则取第一块非内置屏
        let candidates = entries.filter { $0.uuid != internalDisplay.uuid }
        guard !candidates.isEmpty else {
            if verbose { info("没检测到外接显示器", "请接好外屏后再试。") }
            return false
        }
        let saved = defaults.string(forKey: KEY_EXT_UUID) ?? ""
        let external = candidates.first(where: { $0.uuid == saved }) ?? candidates[0]

        defaults.set(internalDisplay.uuid, forKey: KEY_INT_UUID)
        defaults.set(external.uuid, forKey: KEY_EXT_UUID)

        guard let code = ddcInput(uuid: external.uuid) else {
            if verbose {
                info("读不到显示器的输入源",
                     "这块显示器可能不支持通过 DDC 读取当前输入源（VCP 0x60），LidMate 无法在它上面工作。\n\n请先跑一下「显示器自检」。")
            }
            return false
        }
        defaults.set(code, forKey: KEY_MAC_INPUT)
        log("学习完成 内屏=\(internalDisplay.uuid) 外屏=\(external.uuid) 本机输入码=\(code)")
        if verbose {
            info("学习完成",
                 "内屏：\(internalDisplay.resolution)\n外屏：\(external.type) \(external.resolution)\n本机输入码：\(code)\n\n现在可以打开「显示器跟随」了。")
        }
        return true
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
        if !configReady { learnDisplays(verbose: false) }
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
        do { try task.run(); return task } catch {
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

    /// 关闭「显示器跟随」时还原扩展布局（重放脚本记录的档案）
    private func restoreLayout() {
        let profilePath = logURL.appendingPathExtension("layout").path
        guard FileManager.default.fileExists(atPath: profilePath) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "eval \"$(sed 's|^displayplacer|DPPATH|' 'PROFILEPATH')\""]
            .map { $0.replacingOccurrences(of: "DPPATH", with: displayplacerPath)
                     .replacingOccurrences(of: "PROFILEPATH", with: profilePath) }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        log("已请求还原扩展双屏布局")
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
        defaults.set(uuid, forKey: KEY_EXT_UUID)
        _ = learnDisplays(verbose: true)
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
        let script = resourcesURL.appendingPathComponent("selftest.sh")
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: script.path) {
            NSWorkspace.shared.open([script], withApplicationAt: term,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            info("找不到自检脚本", "selftest.sh 没有被打包进来。")
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
