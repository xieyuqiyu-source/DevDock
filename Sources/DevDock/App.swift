import AppKit
import SwiftUI
import Combine

@MainActor
final class WindowSelection: ObservableObject {
    @Published var id: UUID?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private let selection = WindowSelection()
    private var store: ProjectStore!
    private var subscription: AnyCancellable?
    private var quitting = false
    private var quitReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let smoke = CommandLine.arguments.contains("--smoke-ui")
        let isolated = ProcessInfo.processInfo.environment["DEVDOCK_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
        store = ProjectStore(support: isolated, seed: !smoke, monitor: !smoke)
        if smoke {
            store.projects = [Project(name: "示例项目（隔离验证）", path: "/tmp", units: [LaunchUnit(name: "日志检查", command: "printf '%s\\n' '[INFO] 隔离验证进程已启动' '[INFO] 日志支持中文、搜索和复制' '[ERROR] 这是一条验证高亮的示例日志，并非业务错误'; /bin/sleep 60")])]
            store.projects += [
                Project(name: "football（布局示例）", path: "/tmp", units: [LaunchUnit(name: "API · Web · Admin", command: "./dev.sh")]),
                Project(name: "医院助手（布局示例）", path: "/tmp", units: [LaunchUnit(name: "管理 API", command: "./go-start start-bg admin")])
            ]
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "DevDock 项目启动器")
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "DevDock · 项目启动器"
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuPanel(store: store, openProject: { [weak self] id in self?.showWindow(id) }, quit: { NSApp.terminate(nil) }))
        subscription = store.$revision.sink { [weak self] _ in
            guard let self else { return }
            self.statusItem.button?.title = self.store.activeCount > 0 ? " \(self.store.activeCount)" : ""
        }
        installMenu()
        if smoke || CommandLine.arguments.contains("--show") { showWindow(nil) }
        if smoke {
            Task {
                store.launch(store.projects[0])
                for _ in 0..<150 {
                    if store.busy.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await captureSmoke()
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }

    func showWindow(_ id: UUID?) {
        popover.performClose(nil)
        if let id { selection.id = id }
        if window == nil {
            let root = WindowRoot(store: store, selection: selection)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "DevDock · 项目与日志"
            window.setContentSize(NSSize(width: 1080, height: 740))
            window.minSize = NSSize(width: 860, height: 590)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("DevDockMain")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func installMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "项目与日志…", action: #selector(showMain), keyEquivalent: "0").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "退出 DevDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        main.addItem(item)
        let edit = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = menu
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    @objc private func showMain() { showWindow(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil else { return .terminateNow }
        if quitReady { return .terminateNow }
        if quitting { return .terminateCancel }
        quitting = true
        Task {
            await store.shutdown()
            if store.activeCount > 0 {
                store.resumeAfterCancelledQuit()
                store.error = "部分服务尚未停止，请处理后再次退出。"
                quitting = false
                showWindow(nil)
            } else {
                quitReady = true
                NSApp.terminate(nil)
            }
        }
        // Cancel this request while async cleanup runs. terminateLater's nested event loop can
        // starve MainActor tasks when quitting from a dispatch callback.
        return .terminateCancel
    }

    private func captureSmoke() async {
        guard let directory = ProcessInfo.processInfo.environment["DEVDOCK_SCREENSHOT_DIR"], let view = window?.contentView else { return }
        func write(_ view: NSView, _ name: String) {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name)) }
        }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window?.appearance = appearance
            try? await Task.sleep(nanoseconds: 250_000_000)
            write(view, dark ? "window-dark.png" : "window.png")
            let panel = NSHostingView(rootView: MenuPanel(store: store, openProject: { _ in }, quit: {}).environment(\.colorScheme, dark ? .dark : .light))
            panel.frame = NSRect(x: 0, y: 0, width: 370, height: 400)
            let host = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            host.appearance = appearance
            host.contentView = panel
            panel.setFrameSize(panel.fittingSize)
            try? await Task.sleep(nanoseconds: 150_000_000)
            write(panel, dark ? "menu-dark.png" : "menu.png")
        }
        window?.appearance = NSAppearance(named: .aqua)
        window?.setContentSize(NSSize(width: 860, height: 590))
        try? await Task.sleep(nanoseconds: 200_000_000)
        write(view, "window-compact.png")
    }
}

struct WindowRoot: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var selection: WindowSelection
    var body: some View { MainView(store: store, selected: $selection.id) }
}

@main
struct DevDockApp {
    @MainActor static func main() {
        runHelperIfRequested()
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inspect" {
            let projects = Discovery.scan(URL(fileURLWithPath: CommandLine.arguments[2]))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(projects) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
