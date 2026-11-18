import SwiftUI
import AppKit

// 兼容 Command Line Tools 直接编译（不依赖 SwiftUI Macro 插件）
typealias ViewState<Value> = SwiftUI.State<Value>

/// macOS 顶部菜单栏快捷面板（Popover）
struct MenuPanel: View {
    @ObservedObject var store: ProjectStore
    var openProject: (UUID?, Bool) -> Void
    var checkUpdates: () -> Void
    var quit: () -> Void
    @ViewState private var query = ""

    private var filtered: [Project] {
        guard !query.isEmpty else { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let projects = filtered
        let rowHeight: CGFloat = 52
        let listHeight: CGFloat = projects.isEmpty
            ? 84
            : min(CGFloat(AppConfiguration.maxVisibleMenuItems) * rowHeight, CGFloat(projects.count) * rowHeight) + 12

        VStack(spacing: 0) {
            // 顶部栏
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        LinearGradient(
                            colors: [ModernTheme.primary, ModernTheme.primaryHover],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )

                Text("DevDock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ModernTheme.textPrimary)

                if store.activeCount > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(ModernTheme.success)
                            .frame(width: 5.5, height: 5.5)
                        Text("\(store.activeCount) 运行中")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(ModernTheme.success)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ModernTheme.successBg, in: Capsule())
                }

                Spacer(minLength: 4)

                IconActionButton(
                    icon: "macwindow",
                    title: "工作台",
                    size: 26,
                    helpText: "打开 DevDock 主窗口 (⌘0)"
                ) {
                    openProject(nil, false)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            if store.projects.count > AppConfiguration.compactSearchThreshold || !query.isEmpty {
                ModernSearchBar(text: $query, placeholder: "快速过滤项目…", compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Rectangle()
                .fill(ModernTheme.border)
                .frame(height: 1)

            // 项目列表
            ScrollView {
                LazyVStack(spacing: 2) {
                    if projects.isEmpty {
                        VStack(spacing: 6) {
                            Text(store.projects.isEmpty ? "尚未添加本地项目" : "没有匹配的项目")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(ModernTheme.textSecondary)
                            if store.projects.isEmpty {
                                Button("打开工作台导入项目") {
                                    openProject(nil, false)
                                }
                                .buttonStyle(ModernButtonStyle(variant: .secondary, size: .xs))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 76)
                    } else {
                        ForEach(projects) { project in
                            MenuProjectRow(
                                store: store,
                                project: project,
                                openProject: openProject
                            )
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(height: listHeight)

            Rectangle()
                .fill(ModernTheme.border)
                .frame(height: 1)

            // 底栏
            HStack {
                Button {
                    openProject(nil, false)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10.5))
                        Text("管理全部项目")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(ModernTheme.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("检查更新…", action: checkUpdates)
                    .font(.system(size: 11.5))
                    .buttonStyle(.plain)

                Spacer()

                Button(action: quit) {
                    HStack(spacing: 4) {
                        Text("退出 DevDock")
                        Text("⌘Q")
                            .foregroundStyle(ModernTheme.textTertiary)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(ModernTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("停止本次托管的服务并退出 DevDock")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(ModernTheme.surfaceSubtle.opacity(0.5))
        }
        .frame(width: AppConfiguration.menuPanelWidth)
        .background(ModernTheme.surface)
        .tint(ModernTheme.primary)
    }
}

private struct MenuProjectRow: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    let openProject: (UUID?, Bool) -> Void

    @ViewState private var hovered = false

    private var statusVisual: StatusVisual {
        StatusVisual.forProject(store.status(project))
    }

    private var endpoints: [Endpoint] {
        store.browserEndpoints(project)
    }

    private var portSummary: String? {
        let ports = endpoints.compactMap { ep -> String? in
            guard let url = URL(string: ep.url) else { return nil }
            let port = url.port ?? (url.scheme == "https" ? 443 : 80)
            return ":\(String(port))"
        }
        return ports.isEmpty ? nil : ports.joined(separator: "  ")
    }

    var body: some View {
        let busy = store.busy.contains(project.id)
        let active = store.isActive(project)

        HStack(spacing: 10) {
            // 左侧点击打开项目详情
            Button {
                openProject(project.id, false)
            } label: {
                HStack(spacing: 10) {
                    ProjectIconView(name: project.name, size: 30)

                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(project.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ModernTheme.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(statusVisual.color)
                                .frame(width: 5.5, height: 5.5)

                            Text(statusVisual.text)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(statusVisual.isRunning ? statusVisual.color : ModernTheme.textTertiary)
                                .lineLimit(1)

                            if let portSummary {
                                Text("·")
                                    .foregroundStyle(ModernTheme.textTertiary)
                                Text(portSummary)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(ModernTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.notices[project.id] ?? "\(project.name) · \(statusVisual.text)")

            // 主快捷操作（启动 / 打开 / 停止）
            if !busy && !active {
                Button("启动") {
                    store.launch(project)
                }
                .buttonStyle(ModernButtonStyle(variant: .secondary, size: .xs))
                .accessibilityLabel("启动 \(project.name)")
            } else if busy || endpoints.isEmpty {
                Button(busy ? "处理中" : "停止") {
                    store.stop(project)
                }
                .buttonStyle(ModernButtonStyle(variant: .danger, size: .xs))
                .disabled(store.phases[project.id] == "正在停止" || (!busy && !store.canStop(project)))
                .accessibilityLabel("停止 \(project.name)")
            } else if endpoints.count == 1, let url = URL(string: endpoints[0].url) {
                Link(destination: url) {
                    HStack(spacing: 3) {
                        Text("打开")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ModernTheme.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(ModernTheme.primarySoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .help(endpoints[0].url)
                .accessibilityLabel("打开 \(project.name) · \(endpoints[0].name)")
            } else {
                let endpointItems: [MenuAction] = endpoints.compactMap { endpoint in
                    guard let url = URL(string: endpoint.url) else { return nil }
                    let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                    return MenuAction(title: "\(endpoint.name) · :\(String(port))") {
                        NSWorkspace.shared.open(url)
                    }
                }
                NativeMenuButton(items: endpointItems, accessibilityTitle: "打开 \(project.name) 的服务") {
                    HStack(spacing: 3) {
                        Text("打开")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ModernTheme.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(ModernTheme.primarySoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .fixedSize()
            }

            // 更多菜单
            NativeMenuButton(
                items: rowMenuItems(active: active, busy: busy),
                accessibilityTitle: "\(project.name) 的更多操作"
            ) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ModernTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(hovered ? ModernTheme.surfaceHover : ModernTheme.surfaceSubtle.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(hovered ? ModernTheme.surfaceSubtle : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovered = $0 }
    }

    private func rowMenuItems(active: Bool, busy: Bool) -> [MenuAction] {
        var items: [MenuAction] = [
            MenuAction(title: "项目详情…") { openProject(project.id, false) },
            MenuAction(title: "查看终端日志…") { openProject(project.id, true) },
            MenuAction(title: "在 Finder 中显示") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
        ]
        if active && !busy {
            items.append(.separator)
            if !endpoints.isEmpty {
                items.append(MenuAction(title: "停止项目", isEnabled: store.canStop(project)) {
                    store.stop(project)
                })
            }
            items.append(MenuAction(title: "重启项目", isEnabled: store.canRestart(project)) {
                store.stop(project, restart: true)
            })
        }
        return items
    }
}
