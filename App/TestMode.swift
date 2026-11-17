import AnkiLearnCore
import AppKit
import ObjectiveC

/// 测试模式（环境变量 E2E=1，或启动参数 -E2E 1；判断在 Core 的 E2EMode）：App 照常跑，但不占用户的屏幕。
/// - 不进 Dock、不能被激活（激活策略一直是 .prohibited，App 里切 .regular / .accessory 也不生效），不抢焦点
/// - 每个窗口全透明（alpha 一直是 0）、鼠标穿过去；界面照常排版、画，E2E_SNAPSHOT 能把主窗口画成 PNG
/// - 菜单栏图标不挂（isVisible 一直是 false）
/// - 访达、浏览器、系统设置、打开 / 存储面板、提示框、弹出菜单、全局按键监听都不真做，只记一行（stderr 和 数据目录/e2e-screen.log）
/// - UserDefaults.standard 换成单独的一份（<bundle id>.e2e，每次启动清空），不读写正式版的偏好
/// 数据隔开在 Core 的 E2EMode 里（做过的卡片、Claude 会话、AnkiConnect），DeepSeek 的 Key 只放在内存里（Keychain）。
/// 验证脚本：scripts/e2e-hidden-check.sh
enum TestMode {
    static let isOn = E2EMode.isOn

    /// 做过的卡片、日志都在这里（E2E_DATA_DIR，没给就是系统临时目录下的 AnkiLearn-e2e-<pid>）
    static var dataDirectory: URL { E2EMode.dataDirectory }

    private static let environment = ProcessInfo.processInfo.environment
    private static let logLock = NSLock()
    nonisolated(unsafe) private static var statusItemCount = 0

    /// 记一行没真做的事
    static func skip(_ what: String) {
        note("没真的做：\(what)")
    }

    static func note(_ text: String) {
        let line = "[测试模式] \(text)\n"
        FileHandle.standardError.write(Data(line.utf8))
        logLock.lock(); defer { logLock.unlock() }
        let url = dataDirectory.appendingPathComponent("e2e-screen.log")
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// AnkiLearnApp.init 里、读偏好和开窗口之前调：在 NSApplication 建好、任何窗口和偏好用到之前换掉
    @MainActor static func install() {
        guard isOn else { return }
        isolateDefaults()
        hookWindows()
        hookApplication()
        hookStatusItems()
        hookMenus()
        hookPanels()
        hookWorkspace()
        hookEventMonitors()
        NSApplication.shared.setActivationPolicy(.prohibited)
        // 兜底：不走 orderFront 这几条路出来的窗口（弹出框、系统建的小窗）在下一次事件循环里藏起来
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideAllWindows() }
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in MainActor.assumeIsolated { hideAllWindows() } }
        RunLoop.main.add(timer, forMode: .common)
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if let path = environment["E2E_SNAPSHOT"], !path.isEmpty {
                    try? await Task.sleep(for: .seconds(Double(environment["E2E_SNAPSHOT_DELAY"] ?? "") ?? 3))
                    writeSnapshot(to: path)
                }
            }
            if environment["E2E_PROBE"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Double(environment["E2E_PROBE_DELAY"] ?? "") ?? 4))
                    probe()
                }
            }
        }
        note("开着（pid \(ProcessInfo.processInfo.processIdentifier)）：窗口不出现在屏幕上，数据目录 \(dataDirectory.path)")
    }

    // MARK: 窗口

    @MainActor static func hide(_ window: NSWindow) {
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
    }

    @MainActor private static func hideAllWindows() {
        for window in NSApp.windows { hide(window) }
    }

    private static func hookWindows() {
        typealias SetFloat = @convention(c) (NSWindow, Selector, CGFloat) -> Void
        hook(NSWindow.self, "setAlphaValue:") { orig, sel in
            let f = unsafeBitCast(orig, to: SetFloat.self)
            let block: @convention(block) (NSWindow, CGFloat) -> Void = { w, _ in f(w, sel, 0) }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        typealias SetBool = @convention(c) (NSWindow, Selector, ObjCBool) -> Void
        hook(NSWindow.self, "setIgnoresMouseEvents:") { orig, sel in
            let f = unsafeBitCast(orig, to: SetBool.self)
            let block: @convention(block) (NSWindow, ObjCBool) -> Void = { w, _ in f(w, sel, true) }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        typealias WithSender = @convention(c) (NSWindow, Selector, AnyObject?) -> Void
        for name in ["makeKeyAndOrderFront:", "orderFront:"] {
            hook(NSWindow.self, name) { orig, sel in
                let f = unsafeBitCast(orig, to: WithSender.self)
                let block: @convention(block) (NSWindow, AnyObject?) -> Void = { w, sender in
                    MainActor.assumeIsolated { hide(w) }
                    f(w, sel, sender)
                }
                return unsafeBitCast(block, to: AnyObject.self)
            }
        }
        typealias Plain = @convention(c) (NSWindow, Selector) -> Void
        hook(NSWindow.self, "orderFrontRegardless") { orig, sel in
            let f = unsafeBitCast(orig, to: Plain.self)
            let block: @convention(block) (NSWindow) -> Void = { w in
                MainActor.assumeIsolated { hide(w) }
                f(w, sel)
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        typealias Order = @convention(c) (NSWindow, Selector, Int, Int) -> Void
        hook(NSWindow.self, "orderWindow:relativeTo:") { orig, sel in
            let f = unsafeBitCast(orig, to: Order.self)
            let block: @convention(block) (NSWindow, Int, Int) -> Void = { w, place, other in
                MainActor.assumeIsolated { hide(w) }
                f(w, sel, place, other)
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: 激活、Dock

    private static func hookApplication() {
        typealias SetPolicy = @convention(c) (NSApplication, Selector, Int) -> ObjCBool
        hook(NSApplication.self, "setActivationPolicy:") { orig, sel in
            let f = unsafeBitCast(orig, to: SetPolicy.self)
            let block: @convention(block) (NSApplication, Int) -> ObjCBool = { app, _ in
                f(app, sel, NSApplication.ActivationPolicy.prohibited.rawValue)
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hook(NSApplication.self, "activateIgnoringOtherApps:") { _, _ in
            let block: @convention(block) (NSApplication, ObjCBool) -> Void = { _, _ in skip("激活 App") }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        if NSApplication.instancesRespond(to: NSSelectorFromString("activate")) {
            hook(NSApplication.self, "activate") { _, _ in
                let block: @convention(block) (NSApplication) -> Void = { _ in skip("激活 App") }
                return unsafeBitCast(block, to: AnyObject.self)
            }
        }
    }

    // MARK: 菜单栏图标

    private static func hookStatusItems() {
        typealias Make = @convention(c) (NSStatusBar, Selector, CGFloat) -> NSStatusItem
        hook(NSStatusBar.self, "statusItemWithLength:") { orig, sel in
            let f = unsafeBitCast(orig, to: Make.self)
            let block: @convention(block) (NSStatusBar, CGFloat) -> NSStatusItem = { bar, length in
                nonisolated(unsafe) let item = f(bar, sel, length)
                statusItemCount += 1
                // 显示与否按 autosaveName 记在偏好里：换个名字，就算偏好没隔开也不改正式版那个图标的记录
                let name = "e2e-hidden-\(statusItemCount)"
                MainActor.assumeIsolated {
                    item.autosaveName = name
                    item.isVisible = false
                }
                return item
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        typealias SetBool = @convention(c) (NSStatusItem, Selector, ObjCBool) -> Void
        hook(NSStatusItem.self, "setVisible:") { orig, sel in
            let f = unsafeBitCast(orig, to: SetBool.self)
            let block: @convention(block) (NSStatusItem, ObjCBool) -> Void = { item, _ in f(item, sel, false) }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: 弹出菜单（不带坐标的菜单弹在鼠标处，窗口藏起来也挡不住）

    private static func hookMenus() {
        hook(NSMenu.self, "popUpMenuPositioningItem:atLocation:inView:") { _, _ in
            let block: @convention(block) (NSMenu, NSMenuItem?, NSPoint, NSView?) -> ObjCBool = { menu, _, _, _ in
                skip("弹出菜单（\(titles(of: menu))）")
                return false
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hookClass(NSMenu.self, "popUpContextMenu:withEvent:forView:") { _, _ in
            let block: @convention(block) (AnyObject, NSMenu, NSEvent, NSView?) -> Void = { _, menu, _, _ in
                skip("右键菜单（\(titles(of: menu))）")
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hookClass(NSMenu.self, "popUpContextMenu:withEvent:forView:withFont:") { _, _ in
            let block: @convention(block) (AnyObject, NSMenu, NSEvent, NSView?, NSFont?) -> Void = { _, menu, _, _, _ in
                skip("右键菜单（\(titles(of: menu))）")
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    private static func titles(of menu: NSMenu) -> String {
        nonisolated(unsafe) let menu = menu
        return MainActor.assumeIsolated { menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: "、") }
    }

    // MARK: 提示框、打开 / 存储面板

    private static func text(of alert: NSAlert) -> String {
        MainActor.assumeIsolated { alert.messageText }
    }

    private static func hookPanels() {
        typealias Handler = @convention(block) (Int) -> Void
        hook(NSAlert.self, "runModal") { _, _ in
            let block: @convention(block) (NSAlert) -> Int = { alert in
                skip("提示框「\(text(of: alert))」，当作点了第一个按钮")
                return NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hook(NSAlert.self, "beginSheetModalForWindow:completionHandler:") { _, _ in
            let block: @convention(block) (NSAlert, NSWindow, Handler?) -> Void = { alert, _, handler in
                skip("提示框「\(text(of: alert))」，当作点了第一个按钮")
                later { handler?(NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        for cls in [NSSavePanel.self, NSOpenPanel.self] as [AnyClass] {
            let what = cls == NSOpenPanel.self ? "打开面板" : "存储面板"
            hook(cls, "runModal") { _, _ in
                let block: @convention(block) (NSSavePanel) -> Int = { _ in
                    skip("\(what)，当作取消")
                    return NSApplication.ModalResponse.cancel.rawValue
                }
                return unsafeBitCast(block, to: AnyObject.self)
            }
            hook(cls, "beginWithCompletionHandler:") { _, _ in
                let block: @convention(block) (NSSavePanel, Handler?) -> Void = { _, handler in
                    skip("\(what)，当作取消")
                    later { handler?(NSApplication.ModalResponse.cancel.rawValue) }
                }
                return unsafeBitCast(block, to: AnyObject.self)
            }
            hook(cls, "beginSheetModalForWindow:completionHandler:") { _, _ in
                let block: @convention(block) (NSSavePanel, NSWindow, Handler?) -> Void = { _, _, handler in
                    skip("\(what)，当作取消")
                    later { handler?(NSApplication.ModalResponse.cancel.rawValue) }
                }
                return unsafeBitCast(block, to: AnyObject.self)
            }
        }
    }

    /// 回调留到下一轮主循环再调（和真的面板一样，不在调用方法里同步回来）
    private static func later(_ work: @escaping () -> Void) {
        nonisolated(unsafe) let work = work
        DispatchQueue.main.async { work() }
    }

    // MARK: 访达、浏览器、系统设置

    private static func hookWorkspace() {
        typealias Opened = @convention(block) (NSRunningApplication?, NSError?) -> Void
        hook(NSWorkspace.self, "openURL:") { _, _ in
            let block: @convention(block) (NSWorkspace, NSURL) -> ObjCBool = { _, url in
                skip("打开 \(url.absoluteString ?? "")")
                return true
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hook(NSWorkspace.self, "openURL:configuration:completionHandler:") { _, _ in
            let block: @convention(block) (NSWorkspace, NSURL, AnyObject, Opened?) -> Void = { _, url, _, handler in
                skip("打开 \(url.absoluteString ?? "")")
                later { handler?(nil, nil) }
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hook(NSWorkspace.self, "openURLs:withApplicationAtURL:configuration:completionHandler:") { _, _ in
            let block: @convention(block) (NSWorkspace, NSArray, NSURL, AnyObject, Opened?) -> Void = { _, urls, app, _, handler in
                skip("用 \(app.path ?? "") 打开 \(urls.count) 个文件")
                later { handler?(nil, nil) }
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hook(NSWorkspace.self, "openApplicationAtURL:configuration:completionHandler:") { _, _ in
            let block: @convention(block) (NSWorkspace, NSURL, AnyObject, Opened?) -> Void = { _, app, _, handler in
                skip("打开应用 \(app.path ?? "")")
                later { handler?(nil, nil) }
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hook(NSWorkspace.self, "activateFileViewerSelectingURLs:") { _, _ in
            let block: @convention(block) (NSWorkspace, NSArray) -> Void = { _, urls in
                skip("在访达中显示 \(urls.compactMap { ($0 as? NSURL)?.path }.joined(separator: "、"))")
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hook(NSWorkspace.self, "selectFile:inFileViewerRootedAtPath:") { _, _ in
            let block: @convention(block) (NSWorkspace, NSString?, NSString) -> ObjCBool = { _, path, root in
                skip("在访达中显示 \((path ?? root) as String)")
                return true
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
        hook(NSWorkspace.self, "openFile:") { _, _ in
            let block: @convention(block) (NSWorkspace, NSString) -> ObjCBool = { _, path in
                skip("打开 \(path)")
                return true
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: 全局按键 / 鼠标监听（看着用户在别的 App 里按什么，按键还会要输入监控权限）

    private static func hookEventMonitors() {
        hookClass(NSEvent.self, "addGlobalMonitorForEventsMatchingMask:handler:") { _, _ in
            let block: @convention(block) (AnyObject, UInt64, AnyObject?) -> AnyObject? = { _, _, _ in
                skip("全局按键 / 鼠标监听")
                return nil
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: 偏好

    private static func isolateDefaults() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let name = id + ".e2e"
        guard let made = UserDefaults(suiteName: name) else { return }
        nonisolated(unsafe) let suite = made
        suite.removePersistentDomain(forName: name)
        hookClass(UserDefaults.self, "standardUserDefaults") { _, _ in
            let block: @convention(block) (AnyObject) -> UserDefaults = { _ in suite }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: 截图（E2E_SNAPSHOT=<png 路径>，启动 E2E_SNAPSHOT_DELAY 秒后画，默认 3）

    @MainActor private static func writeSnapshot(to path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let title = try snapshot(to: url)
            note("截图：\(url.path)（窗口「\(title)」）")
        } catch {
            note("截图失败：\(error)")
        }
    }

    enum SnapshotError: Error { case noWindow, render }

    /// 不截屏：把最大的那个窗口（标题栏在内）自己画成 PNG，窗口透明也画得出来
    @discardableResult
    @MainActor static func snapshot(to url: URL) throws -> String {
        let windows = NSApp.windows.filter {
            $0.contentView != nil && $0.frame.width > 120 && $0.frame.height > 80
                && !NSStringFromClass(type(of: $0)).contains("StatusBar")
        }
        let area: (NSWindow) -> CGFloat = { $0.frame.width * $0.frame.height }
        guard let window = windows.filter(\.isVisible).max(by: { area($0) < area($1) }) ?? windows.max(by: { area($0) < area($1) }),
              let view = window.contentView?.superview ?? window.contentView else { throw SnapshotError.noWindow }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SnapshotError.render }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.render }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        return window.title
    }

    // MARK: 探针（E2E_PROBE=1）：把会占屏幕的事各真做一遍，看拦没拦住

    /// 启动 E2E_PROBE_DELAY 秒（默认 4）后：开一个新窗口、改大小挪到屏幕中间、alpha 设 1，App 里每个窗口也改一次大小；
    /// 切成 .regular 再激活；开网址、在访达中显示、弹菜单、挂菜单栏图标、加全局监听、弹提示框、打开面板、存储面板。
    /// 都拦住了记一行「探针：通过」，scripts/e2e-hidden-check.sh 看这一行，再查一次屏幕上没有窗口
    @MainActor static func probe() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "E2E probe"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.setFrame(NSRect(x: 200, y: 200, width: 640, height: 480), display: true)
        window.center()
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        for other in NSApp.windows where other !== window && other.isVisible && other.styleMask.contains(.resizable) {
            other.setContentSize(NSSize(width: other.frame.width + 40, height: other.frame.height + 40))
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(URL(string: "https://example.com/e2e-probe")!)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: NSTemporaryDirectory())])
        let menu = NSMenu()
        menu.addItem(withTitle: "E2E probe", action: nil, keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "E2E"
        item.isVisible = true
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }
        let alert = NSAlert()
        alert.messageText = "E2E probe"
        let alertResult = alert.runModal()
        let openResult = NSOpenPanel().runModal()
        NSSavePanel().begin { _ in }

        var failures: [String] = []
        if NSApp.activationPolicy() != .prohibited { failures.append("激活策略是 \(NSApp.activationPolicy().rawValue)") }
        if NSApp.isActive { failures.append("App 被激活了") }
        if window.alphaValue != 0 || !window.ignoresMouseEvents { failures.append("探针窗口 alpha \(window.alphaValue)") }
        if NSApp.windows.contains(where: { $0.isVisible && $0.alphaValue != 0 }) { failures.append("有窗口 alpha 不是 0") }
        if item.isVisible { failures.append("菜单栏图标挂上了") }
        if monitor != nil { failures.append("全局监听加上了") }
        if alertResult != .alertFirstButtonReturn { failures.append("提示框返回 \(alertResult.rawValue)") }
        if openResult != .cancel { failures.append("打开面板返回 \(openResult.rawValue)") }
        note(failures.isEmpty ? "探针：通过" : "探针：没拦住 \(failures.joined(separator: "；"))")
    }

    // MARK: 换方法

    /// 把 cls 的实例方法 name 换成 make 给的 block（block 的第一个参数是 self，后面接方法参数）。
    /// 方法是从父类继承来的：只在 cls 上加一个，父类不动
    private static func hook(_ cls: AnyClass, _ name: String, _ make: (IMP, Selector) -> AnyObject) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel) else {
            note("找不到 \(NSStringFromClass(cls)).\(name)，这一项没换")
            return
        }
        let imp = imp_implementationWithBlock(make(method_getImplementation(method), sel))
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }

    private static func hookClass(_ cls: AnyClass, _ name: String, _ make: (IMP, Selector) -> AnyObject) {
        guard let meta = object_getClass(cls) else { return }
        hook(meta, name, make)
    }
}
