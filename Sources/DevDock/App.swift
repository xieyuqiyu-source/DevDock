import AppKit
import SwiftUI
import Combine

@MainActor
final class WindowSelection: ObservableObject {
    @Published var id: UUID?
    @Published var logProject: UUID?
    @Published var showUpdates = false
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
        NSApp.setActivationPolicy(.regular)
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
        popover.contentViewController = NSHostingController(rootView: MenuPanel(store: store, openProject: { [weak self] id, logs in self?.showWindow(id, logs: logs) }, checkUpdates: { [weak self] in self?.checkForUpdates() }, quit: { NSApp.terminate(nil) }))
        subscription = store.$revision.sink { [weak self] _ in
            guard let self else { return }
            self.statusItem.button?.title = self.store.activeCount > 0 ? " \(self.store.activeCount)" : ""
        }
        installMenu()
        showWindow(nil)
        if smoke {
            Task {
                store.launch(store.projects[0])
                for _ in 0..<150 {
                    if store.busy.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await captureSmoke()
                precondition(NSApp.activationPolicy() == .regular)
                let managed = store.hasManagedServices
                let close = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.keyEquivalent == "w" }
                precondition(close?.action == #selector(NSWindow.performClose(_:)))
                window?.makeKeyAndOrderFront(nil)
                precondition(NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: window, from: close))
                precondition(window?.isVisible == false)
                precondition(store.hasManagedServices == managed)
                _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                precondition(window?.isVisible == true)
                print("PASS regular app activation, window close, service retention and reopen")
                let appMenu = NSApp.mainMenu!.items[0].submenu!
                let updateItem = appMenu.indexOfItem(withTarget: self, andAction: #selector(checkForUpdates))
                precondition(updateItem >= 0)
                appMenu.performActionForItem(at: updateItem)
                for _ in 0..<50 where window?.attachedSheet == nil {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                precondition(selection.showUpdates && window?.attachedSheet != nil)
                selection.showUpdates = false
                print("PASS check-for-updates menu opens the update sheet")
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }

    func showWindow(_ id: UUID?, logs: Bool = false) {
        popover.performClose(nil)
        if let id {
            selection.id = id
            if logs { selection.logProject = id }
        }
        let created = window == nil
        if created {
            let root = WindowRoot(store: store, selection: selection)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "DevDock · 项目与日志"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 1120, height: 720))
            window.minSize = NSSize(width: 900, height: 600)
            window.isReleasedWhenClosed = false
            window.center()
            if !CommandLine.arguments.contains("--smoke-ui") { window.setFrameAutosaveName("DevDockMain") }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        if created { window?.makeFirstResponder(nil) }
    }

    private func installMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "项目与日志…", action: #selector(showMain), keyEquivalent: "0").target = self
        app.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "退出 DevDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        main.addItem(item)
        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu
        main.addItem(file)
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

    @objc private func checkForUpdates() {
        showWindow(nil)
        selection.showUpdates = true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil else { return .terminateNow }
        if quitReady { return .terminateNow }
        if quitting { return .terminateCancel }
        quitting = true
        Task {
            await store.shutdown()
            if store.hasManagedServices {
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
        // Presentation-only fixtures; smoke mode never opens these URLs.
        let links = [Endpoint(name: "Vite 页面（布局示例）", url: "http://localhost:15175", healthURL: "http://localhost:15175"),
                     Endpoint(name: "Go API（布局示例）", url: "http://localhost:15176", healthURL: "http://localhost:15176")]
        store.discoveredEndpoints[store.projects[0].units[0].id] = links
        for link in links { store.endpointStates[link.id] = .listening }
        store.endpointActivity[links[0].id] = EndpointActivity(pids: [31001], inferredRole: .frontend)
        store.endpointActivity[links[1].id] = EndpointActivity(pids: [31002], inferredRole: .backend)
        func write(_ view: NSView, _ name: String) {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name)) }
        }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window?.appearance = appearance
            selection.id = nil
            try? await Task.sleep(nanoseconds: 250_000_000)
            write(view, dark ? "dashboard-dark.png" : "dashboard.png")
            selection.id = store.projects[0].id
            try? await Task.sleep(nanoseconds: 250_000_000)
            write(view, dark ? "window-dark.png" : "window.png")
            let panel = NSHostingView(rootView: MenuPanel(store: store, openProject: { _, _ in }, checkUpdates: {}, quit: {}).environment(\.colorScheme, dark ? .dark : .light))
            panel.frame = NSRect(x: 0, y: 0, width: AppConfiguration.menuPanelWidth, height: 400)
            let host = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            host.appearance = appearance
            host.contentView = panel
            panel.setFrameSize(panel.fittingSize)
            try? await Task.sleep(nanoseconds: 150_000_000)
            write(panel, dark ? "menu-dark.png" : "menu.png")
        }
        window?.appearance = NSAppearance(named: .aqua)
        window?.setContentSize(NSSize(width: 900, height: 600))
        try? await Task.sleep(nanoseconds: 200_000_000)
        write(view, "window-compact.png")
        selection.logProject = store.projects[0].id
        try? await Task.sleep(nanoseconds: 300_000_000)
        write(view, "window-logs.png")
    }
}

struct WindowRoot: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var selection: WindowSelection
    var body: some View {
        ModernMainView(store: store, selected: $selection.id, logProject: $selection.logProject)
            .sheet(isPresented: $selection.showUpdates) { SoftwareUpdateView() }
    }
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
