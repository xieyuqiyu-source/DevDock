import SwiftUI
import AppKit

/// 主窗口根视图 - 单侧栏导航 + 统一顶栏 + 工作台详情与停靠式终端抽屉
struct ModernMainView: View {
    @ObservedObject var store: ProjectStore
    @Binding var selected: UUID?
    @Binding var logProject: UUID?
    @ViewState private var editing: Project?
    @ViewState private var searchText = ""
    @ViewState private var searchFocused = false

    private var selectedProject: Project? {
        store.projects.first { $0.id == selected }
    }

    private var filteredProjects: [Project] {
        guard !searchText.isEmpty else { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: AppConfiguration.sidebarWidth)
                .background {
                    ZStack {
                        ModernTheme.sidebar
                        VisualEffectSurface(material: .sidebar, blendingMode: .behindWindow)
                            .opacity(0.6)
                    }
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(ModernTheme.border)
                        .frame(width: 1)
                }

            VStack(spacing: 0) {
                topToolbar
                    .frame(height: AppConfiguration.headerHeight)
                    .background(ModernTheme.surface)

                Rectangle()
                    .fill(ModernTheme.border)
                    .frame(height: 1)

                if let project = selectedProject {
                    ModernProjectDetail(
                        store: store,
                        project: project,
                        showingLogs: Binding(
                            get: { logProject == project.id },
                            set: { logProject = $0 ? project.id : nil }
                        ),
                        onEdit: { editing = project }
                    )
                    .id(project.id)
                } else {
                    DashboardView(
                        store: store,
                        searchQuery: searchText,
                        onSelectProject: { projectID, openLogs in
                            selected = projectID
                            if openLogs { logProject = projectID }
                        },
                        onManualAdd: manualAddProject
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ModernTheme.background)
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(ModernTheme.primary)
        .sheet(item: $editing) { project in
            ModernProjectEditor(project: project) { updated in
                try store.update(updated)
                selected = updated.id
            }
        }
        .alert("DevDock", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .onChange(of: store.projects.map(\.id)) { ids in
            if let selected, !ids.contains(selected) {
                self.selected = nil
            }
        }
        .background {
            HStack {
                Button("添加项目") { store.importFolder() }.keyboardShortcut("n")
                Button("搜索项目") { searchFocused = true }.keyboardShortcut("f")
                Button("总览") { selected = nil }.keyboardShortcut("d")
            }
            .hidden()
            .frame(width: 0, height: 0)
        }
    }

    // MARK: - 侧边栏
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题区：预留 78pt 避开 macOS 左上角红黄绿窗口控制按钮
            HStack(spacing: 7) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12, weight: .bold))
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
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ModernTheme.textPrimary)

                Spacer(minLength: 4)

                if store.activeCount > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(ModernTheme.success)
                            .frame(width: 5.5, height: 5.5)
                        Text("\(store.activeCount)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(ModernTheme.success)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(ModernTheme.successBg, in: Capsule())
                }
            }
            .padding(.leading, 78)
            .padding(.trailing, 12)
            .frame(height: AppConfiguration.headerHeight)

            Rectangle()
                .fill(ModernTheme.border)
                .frame(height: 1)

            // 唯一全局搜索栏
            ModernSearchBar(
                text: $searchText,
                placeholder: "搜索项目…",
                shortcutHint: "⌘F",
                requestedFocus: $searchFocused
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // 置顶「总览」导航项
            SidebarOverviewRow(
                isSelected: selected == nil,
                totalCount: store.projects.count,
                action: { selected = nil }
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            // 项目分组头
            HStack {
                Text("项目")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ModernTheme.textTertiary)
                Spacer()
                if !searchText.isEmpty {
                    Text("\(filteredProjects.count) 项")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(ModernTheme.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            // 项目列表（不使用 List(selection:) 以消除系统原生灰色选中框叠加，同时完整保留 onMove 拖拽排序）
            List {
                ForEach(filteredProjects) { project in
                    SidebarProjectRow(
                        project: project,
                        isSelected: selected == project.id,
                        visual: StatusVisual.forProject(store.status(project)),
                        activePortCount: store.browserEndpoints(project).count,
                        onTap: { selected = project.id }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 1.5, leading: 10, bottom: 1.5, trailing: 10))
                    .contextMenu {
                        sidebarContextMenu(for: project)
                    }
                    .moveDisabled(!searchText.isEmpty)
                }
                .onMove { offsets, destination in
                    if searchText.isEmpty {
                        store.moveProjects(from: offsets, to: destination)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Rectangle()
                .fill(ModernTheme.border)
                .frame(height: 1)

            // 底部添加项目栏（自定义 SwiftUI 按钮 + 原生 NSMenu）
            HStack(spacing: 8) {
                NativeMenuButton(
                    items: [
                        MenuAction(title: "扫描项目目录…") { store.importFolder() },
                        MenuAction(title: "手动添加项目…") { manualAddProject() }
                    ],
                    style: ModernButtonStyle(variant: .secondary, size: .small, fullWidth: true),
                    accessibilityTitle: "添加项目"
                ) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ModernTheme.primary)
                        Text("添加项目")
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ModernTheme.textTertiary)
                    }
                }

                if store.scanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
    }

    @ViewBuilder
    private func sidebarContextMenu(for project: Project) -> some View {
        let busy = store.busy.contains(project.id)
        let active = store.isActive(project)

        if !busy && !active {
            Button("启动项目") { store.launch(project) }
        } else {
            Button("停止项目") { store.stop(project) }
                .disabled(store.phases[project.id] == "正在停止" || (!busy && !store.canStop(project)))
            if active && !busy {
                Button("重启项目") { store.stop(project, restart: true) }
                    .disabled(!store.canRestart(project))
            }
        }
        Divider()
        Button("查看终端日志") {
            selected = project.id
            logProject = project.id
        }
        Button("编辑启动配置…") { editing = project }
            .disabled(active || busy)
        Button("在 Finder 中显示") {
            NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
        }
        if let index = store.projects.firstIndex(where: { $0.id == project.id }) {
            Divider()
            Button("上移") { store.moveProjects(from: IndexSet(integer: index), to: index - 1) }
                .disabled(index == 0 || !searchText.isEmpty)
            Button("下移") { store.moveProjects(from: IndexSet(integer: index), to: index + 2) }
                .disabled(index == store.projects.count - 1 || !searchText.isEmpty)
        }
        Divider()
        Button("移除项目", role: .destructive) { store.remove(project) }
            .disabled(active || busy)
    }

    // MARK: - 顶部工作区工具栏
    private var topToolbar: some View {
        HStack(spacing: 10) {
            if let project = selectedProject {
                BreadcrumbOverviewButton {
                    selected = nil
                }
                .fixedSize(horizontal: true, vertical: false)

                Text("/")
                    .font(.system(size: 12))
                    .foregroundStyle(ModernTheme.textTertiary)

                Text(project.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ModernTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)

                StatusBadge(visual: StatusVisual.forProject(store.status(project)), compact: true)

                Spacer(minLength: 8)

                projectToolbarActions(for: project)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("工作台总览")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ModernTheme.textPrimary)

                Text("·")
                    .foregroundStyle(ModernTheme.textTertiary)

                Text("\(store.projects.count) 个项目，\(store.activeCount) 个运行中")
                    .font(.system(size: 12))
                    .foregroundStyle(ModernTheme.textTertiary)
                    .monospacedDigit()

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    let stoppable = store.projects.filter { store.isActive($0) && store.canStop($0) && !store.busy.contains($0.id) }
                    if !stoppable.isEmpty {
                        Button("全部停止") {
                            for item in stoppable { store.stop(item) }
                        }
                        .buttonStyle(ModernButtonStyle(variant: .secondary, size: .xs))
                    }

                    Button {
                        store.importFolder()
                    } label: {
                        Label("扫描目录", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(ModernButtonStyle(variant: .secondary, size: .xs))
                }
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func projectToolbarActions(for project: Project) -> some View {
        let busy = store.busy.contains(project.id)
        let active = store.isActive(project)
        let endpoints = store.browserEndpoints(project)
        let logsVisible = logProject == project.id

        HStack(spacing: 6) {
            // 快捷打开本机服务端口
            if endpoints.count == 1, let url = URL(string: endpoints[0].url) {
                let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(verbatim: "打开 :\(port)")
                            .fontDesign(.monospaced)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ModernTheme.primary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(ModernTheme.primarySoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(ModernTheme.primary.opacity(0.22), lineWidth: 1)
                    }
                }
                .help(endpoints[0].url)
            } else if endpoints.count > 1 {
                let endpointItems: [MenuAction] = endpoints.compactMap { endpoint in
                    guard let url = URL(string: endpoint.url) else { return nil }
                    let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                    return MenuAction(title: "\(endpoint.name) · :\(String(port))") {
                        NSWorkspace.shared.open(url)
                    }
                }
                NativeMenuButton(items: endpointItems, accessibilityTitle: "打开服务") {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                            .font(.system(size: 11, weight: .medium))
                        Text("打开 (\(endpoints.count))")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ModernTheme.primary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(ModernTheme.primarySoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(ModernTheme.primary.opacity(0.22), lineWidth: 1)
                    }
                }
            }

            // 日志抽屉开关
            IconActionButton(
                icon: "terminal",
                title: "日志",
                isActive: logsVisible,
                size: 28,
                helpText: logsVisible ? "收起终端日志" : "展开终端日志"
            ) {
                logProject = logsVisible ? nil : project.id
            }

            // 重启
            if active && !busy && store.canRestart(project) {
                IconActionButton(
                    icon: "arrow.clockwise",
                    size: 28,
                    helpText: "重启 \(project.name)"
                ) {
                    store.stop(project, restart: true)
                }
            }

            // 主启停按钮
            if !busy && !active {
                Button {
                    store.launch(project)
                } label: {
                    Label("启动", systemImage: "play.fill")
                }
                .buttonStyle(ModernButtonStyle(variant: .primary, size: .small))
                .keyboardShortcut(.return, modifiers: [])
            } else {
                Button {
                    store.stop(project)
                } label: {
                    Label(store.phases[project.id] == "正在停止" ? "停止中" : "停止", systemImage: "stop.fill")
                }
                .buttonStyle(ModernButtonStyle(variant: .danger, size: .small))
                .disabled(store.phases[project.id] == "正在停止" || (!busy && !store.canStop(project)))
                .help(active && !store.canStop(project) ? "外部服务请使用原启动方式停止" : "停止项目")
            }

            // 更多菜单
            NativeMenuButton(
                items: projectMoreMenuItems(for: project, active: active, busy: busy),
                style: ModernButtonStyle(variant: .secondary, size: .small),
                accessibilityTitle: "项目更多操作"
            ) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }

    private func projectMoreMenuItems(for project: Project, active: Bool, busy: Bool) -> [MenuAction] {
        var list: [MenuAction] = []
        if active {
            list.append(MenuAction(title: "重启项目", isEnabled: !busy && store.canRestart(project)) {
                store.stop(project, restart: true)
            })
            list.append(.separator)
        }
        list.append(MenuAction(title: "编辑启动配置…", isEnabled: !active && !busy) {
            editing = project
        })
        list.append(MenuAction(title: "在 Finder 中显示") {
            NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
        })
        list.append(MenuAction(title: "在终端中打开目录") {
            openInTerminal(path: project.path)
        })
        list.append(MenuAction(title: "打开日志归档目录") {
            NSWorkspace.shared.open(store.logsURL)
        })
        list.append(.separator)
        list.append(MenuAction(title: "移除项目", role: .destructive, isEnabled: !active && !busy) {
            store.remove(project)
        })
        return list
    }

    private func manualAddProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "选择项目目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editing = Discovery.project(at: url) ?? Project(
            name: url.lastPathComponent,
            path: url.path,
            units: [LaunchUnit(name: "项目", command: "./dev")]
        )
    }

    private func openInTerminal(path: String) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - 侧边栏导航行组件
private struct BreadcrumbOverviewButton: View {
    let action: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("总览")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(hovered ? ModernTheme.textPrimary : ModernTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(hovered ? ModernTheme.surfaceSubtle : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct SidebarOverviewRow: View {
    let isSelected: Bool
    let totalCount: Int
    let action: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "square.grid.2x2.fill" : "square.grid.2x2")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? ModernTheme.primary : ModernTheme.textSecondary)
                    .frame(width: 22)

                Text("总览")
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? ModernTheme.textPrimary : ModernTheme.textSecondary)

                Spacer(minLength: 4)

                Text("\(totalCount)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? ModernTheme.primary : ModernTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(isSelected ? ModernTheme.primary.opacity(0.14) : ModernTheme.surfaceSubtle, in: Capsule())
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                isSelected ? ModernTheme.surface : (hovered ? ModernTheme.surfaceHover.opacity(0.75) : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(ModernTheme.border, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct SidebarProjectRow: View {
    let project: Project
    let isSelected: Bool
    let visual: StatusVisual
    let activePortCount: Int
    let onTap: () -> Void

    @ViewState private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                ProjectIconView(name: project.name, size: 22)

                Text(project.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? ModernTheme.textPrimary : ModernTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if visual.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.72)
                } else if visual.isRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(visual.color)
                            .frame(width: 6, height: 6)
                        if activePortCount > 0 {
                            Text("\(activePortCount)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(visual.color)
                        }
                    }
                    .padding(.horizontal, activePortCount > 0 ? 5.5 : 0)
                    .padding(.vertical, activePortCount > 0 ? 1.5 : 0)
                    .background(activePortCount > 0 ? visual.background : Color.clear, in: Capsule())
                } else if visual.color == ModernTheme.danger || visual.color == ModernTheme.warning {
                    Circle()
                        .fill(visual.color)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                isSelected ? ModernTheme.surface : (hovered ? ModernTheme.surfaceHover.opacity(0.7) : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(ModernTheme.border, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(project.name) · \(visual.text)")
        .onHover { hovered = $0 }
    }
}

// MARK: - 项目详情工作区（上方服务面板 + 下方停靠式可拖拽终端日志抽屉）
struct ModernProjectDetail: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    @Binding var showingLogs: Bool
    let onEdit: () -> Void

    @ViewState private var logDrawerHeight: CGFloat = AppConfiguration.defaultLogDrawerHeight
    @ViewState private var dragStartHeight: CGFloat? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 上部：项目信息与服务端口映射列表
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ProjectOverviewCard(store: store, project: project, onEdit: onEdit, onShowLogs: { showingLogs = true })

                    if !project.enabledUnits.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("服务与监听拓扑")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(ModernTheme.textSecondary)
                                Spacer()
                                Text("自动核验进程树与本地端口归属")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ModernTheme.textTertiary)
                            }
                            .padding(.horizontal, 2)

                            ForEach(project.enabledUnits) { unit in
                                ServiceCard(store: store, project: project, unit: unit)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 下部：IDE 风格停靠式终端日志抽屉
            if showingLogs {
                LogDrawerSplitter(
                    height: $logDrawerHeight,
                    dragStartHeight: $dragStartHeight
                )

                EnhancedLogViewer(
                    store: store,
                    project: project,
                    onClose: { showingLogs = false }
                )
                .frame(height: logDrawerHeight)
            } else {
                collapsedLogBar
            }
        }
        .background(ModernTheme.background)
    }

    private var collapsedLogBar: some View {
        Button {
            showingLogs = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ModernTheme.primary)
                Text("终端日志")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ModernTheme.textPrimary)
                if let firstSource = store.logSources(project).first {
                    Text("· \(firstSource.name)")
                        .font(.system(size: 11))
                        .foregroundStyle(ModernTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text("· 点击展开实时标准输出、过滤与书签")
                        .font(.system(size: 11))
                        .foregroundStyle(ModernTheme.textTertiary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("展开")
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ModernTheme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(ModernTheme.terminalHeader)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(ModernTheme.border)
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LogDrawerSplitter: View {
    @Binding var height: CGFloat
    @Binding var dragStartHeight: CGFloat?
    @ViewState private var hovered = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(hovered ? ModernTheme.primary.opacity(0.18) : ModernTheme.border)
                .frame(height: 1)
            Capsule()
                .fill(hovered ? ModernTheme.primary : ModernTheme.borderStrong)
                .frame(width: 36, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 7)
        .background(ModernTheme.terminalHeader)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.resizeUpDown.push() }
            else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = dragStartHeight ?? height
                    if dragStartHeight == nil { dragStartHeight = height }
                    let proposed = base - value.translation.height
                    height = min(max(proposed, AppConfiguration.minLogDrawerHeight), AppConfiguration.maxLogDrawerHeight)
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
    }
}

// MARK: - 项目概览头部卡片
struct ProjectOverviewCard: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    let onEdit: () -> Void
    let onShowLogs: () -> Void

    @ViewState private var copiedPath = false

    var body: some View {
        let active = store.isActive(project)
        let busy = store.busy.contains(project.id)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ProjectIconView(name: project.name, size: 44)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(project.name)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(ModernTheme.textPrimary)

                        if !project.note.isEmpty {
                            Text(project.note)
                                .font(.system(size: 11.5))
                                .foregroundStyle(ModernTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    // 路径与启动元数据标签行
                    HStack(spacing: 8) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(project.path, forType: .string)
                            copiedPath = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                copiedPath = false
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: copiedPath ? "checkmark" : "folder")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(copiedPath ? ModernTheme.success : ModernTheme.textTertiary)
                                Text(ModernTheme.abbreviatedPath(project.path))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(ModernTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(ModernTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("点击复制完整目录：\(project.path)")

                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                        } label: {
                            HStack(spacing: 3) {
                                Text("Finder")
                                Image(systemName: "arrow.up.forward.square")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(ModernTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中打开目录")

                        if let started = store.startedAt(project) {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 10.5))
                                Text("启动于 \(started.formatted(date: .omitted, time: .shortened))")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(ModernTheme.textTertiary)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    onEdit()
                } label: {
                    Label("配置", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(ModernButtonStyle(variant: .secondary, size: .xs))
                .disabled(active || busy)
                .help(active || busy ? "停止项目后可编辑启动配置" : "编辑项目路径、命令与健康检查")
            }

            if let notice = store.notices[project.id] {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ModernTheme.warning)

                    Text(notice)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ModernTheme.textPrimary)
                        .textSelection(.enabled)

                    Spacer(minLength: 8)

                    Button("查看日志") {
                        onShowLogs()
                    }
                    .buttonStyle(ModernButtonStyle(variant: .secondary, size: .xs))
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ModernTheme.warningBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(ModernTheme.warning.opacity(0.25), lineWidth: 1)
                }
            }
        }
        .padding(16)
        .background(ModernTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(ModernTheme.border, lineWidth: 1)
        }
    }
}

// MARK: - 服务单元卡片（结构化端口映射表）
struct ServiceCard: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    let unit: LaunchUnit

    private var services: [ServiceGroup] {
        store.displayedServices(unit)
    }

    private var orderedEndpointItems: [(role: ServiceRole, pids: [Int32], endpoint: Endpoint)] {
        var list: [(ServiceRole, [Int32], Endpoint)] = []
        for role in ServiceRole.allCases {
            for service in services where service.role == role {
                for (idx, endpoint) in service.endpoints.enumerated() {
                    list.append((role, idx == 0 ? service.pids : [], endpoint))
                }
            }
        }
        return list
    }

    var body: some View {
        let active = store.isActive(unit)
        let pid = store.processID(unit)
        let items = orderedEndpointItems

        VStack(alignment: .leading, spacing: 0) {
            // 单元顶栏
            HStack(spacing: 10) {
                Circle()
                    .fill(active ? ModernTheme.success : ModernTheme.textTertiary.opacity(0.55))
                    .frame(width: 7.5, height: 7.5)

                Text(unit.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ModernTheme.textPrimary)

                // 内联命令标签
                HStack(spacing: 4) {
                    Text("$")
                        .foregroundStyle(ModernTheme.textTertiary)
                    Text(unit.command)
                        .foregroundStyle(ModernTheme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ModernTheme.codeBg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(maxWidth: 320, alignment: .leading)
                .help(unit.command)

                Spacer(minLength: 8)

                if let pid {
                    Text(verbatim: "PID \(pid)")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(ModernTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(ModernTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                Text(active ? (store.canStop(unit) ? "运行中" : "外部监听") : "已停止")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(active ? ModernTheme.success : ModernTheme.textTertiary)

                if project.enabledUnits.count > 1 {
                    Button {
                        if active { store.stop(project, only: unit.id) }
                        else { store.launch(project, only: unit.id) }
                    } label: {
                        Label(active ? "停止" : "启动", systemImage: active ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(ModernButtonStyle(variant: active ? .danger : .secondary, size: .xs))
                    .disabled(store.busy.contains(project.id) || (active && !store.canStop(unit)))
                    .help(active && !store.canStop(unit) ? "外部服务请使用原启动方式停止" : unit.name)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(ModernTheme.surfaceSubtle.opacity(0.45))

            Divider().overlay(ModernTheme.border)

            // 端口与服务列表
            if items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: active ? "dot.radiowaves.left.and.right" : "network.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(ModernTheme.textTertiary)
                    Text(active ? "进程运行中，正在探测绑定的本机监听端口…" : "启动后将自动发现该进程树绑定的 HTTP / TCP 端口")
                        .font(.system(size: 12))
                        .foregroundStyle(ModernTheme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.endpoint.id) { index, entry in
                        EndpointRow(
                            store: store,
                            role: entry.role,
                            pids: entry.pids,
                            endpoint: entry.endpoint
                        )
                        if index < items.count - 1 {
                            Divider()
                                .overlay(ModernTheme.border)
                                .padding(.leading, 14)
                        }
                    }
                }
            }

            // 附加工作目录或守护模式元数据（仅在有自定义设置时展示）
            if unit.directory != "." && !unit.directory.isEmpty || unit.detached || !unit.logFile.isEmpty {
                Divider().overlay(ModernTheme.border)
                HStack(spacing: 12) {
                    if unit.directory != "." && !unit.directory.isEmpty {
                        Label("子目录: \(unit.directory)", systemImage: "folder")
                    }
                    if unit.detached {
                        Label("后台守护模式", systemImage: "arrow.triangle.branch")
                    }
                    if !unit.logFile.isEmpty {
                        Label("日志: \(unit.logFile)", systemImage: "doc.text")
                    }
                    Spacer()
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ModernTheme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(ModernTheme.surfaceSubtle.opacity(0.3))
            }
        }
        .background(ModernTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ModernTheme.border, lineWidth: 1)
        }
    }
}

struct EndpointRow: View {
    @ObservedObject var store: ProjectStore
    let role: ServiceRole
    let pids: [Int32]
    let endpoint: Endpoint

    @ViewState private var copied = false

    private var state: EndpointState {
        store.endpointStates[endpoint.id] ?? .stopped
    }

    private var roleTint: Color {
        switch role {
        case .frontend: return ModernTheme.primary
        case .backend: return ModernTheme.success
        case .unclassified: return ModernTheme.textSecondary
        }
    }

    var body: some View {
        let visual = StatusVisual.forEndpoint(state)

        HStack(spacing: 10) {
            // 角色标签（前端 / 后端 / 未分类）
            Text(role.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(roleTint)
                .padding(.horizontal, 6.5)
                .padding(.vertical, 2)
                .background(roleTint.opacity(0.11), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .frame(width: 48, alignment: .center)

            // 服务名称
            Text(endpoint.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ModernTheme.textPrimary)
                .lineLimit(1)

            // 完整地址预览
            Text(endpoint.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ModernTheme.textTertiary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // 监听 PID
            if !pids.isEmpty {
                Text("PID " + pids.map(String.init).joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(ModernTheme.textTertiary)
            }

            // 状态徽章
            StatusBadge(visual: visual, compact: true)

            // 复制链接按钮
            IconActionButton(
                icon: copied ? "checkmark" : "link",
                isActive: copied,
                size: 24,
                helpText: "复制服务地址 \(endpoint.url)"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(endpoint.url, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    copied = false
                }
            }

            // 端口跳转按钮
            if let url = URL(string: endpoint.url) {
                let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                if state.isOwned {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Text(verbatim: ":\(port)")
                                .fontDesign(.monospaced)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(ModernTheme.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(ModernTheme.primarySoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .help("在浏览器中打开 \(endpoint.url)")
                    .accessibilityLabel("打开 \(endpoint.name)")
                } else {
                    Text(verbatim: ":\(port)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ModernTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9.5)
    }
}

// MARK: - 现代化项目配置编辑器弹窗
struct ModernProjectEditor: View {
    let project: Project
    let onSave: (Project) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var editedProject: Project
    @ViewState private var errorMessage: String?

    init(project: Project, onSave: @escaping (Project) throws -> Void) {
        self.project = project
        self.onSave = onSave
        self._editedProject = ViewState(initialValue: project)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 弹窗顶栏
            HStack(spacing: 12) {
                ProjectIconView(name: editedProject.name.isEmpty ? "DevDock" : editedProject.name, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑项目启动配置")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ModernTheme.textPrimary)
                    Text("配置本地工作目录、启动命令序列与本机 HTTP 健康检查")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ModernTheme.textTertiary)
                }

                Spacer()

                Button("取消") {
                    dismiss()
                }
                .buttonStyle(ModernButtonStyle(variant: .secondary, size: .small))
                .keyboardShortcut(.cancelAction)

                Button("保存配置") {
                    do {
                        try onSave(editedProject)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(ModernButtonStyle(variant: .primary, size: .small))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(ModernTheme.surface)

            Rectangle()
                .fill(ModernTheme.border)
                .frame(height: 1)

            // 错误提示横幅
            if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(ModernTheme.danger)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(ModernTheme.textPrimary)
                    Spacer()
                    Button {
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ModernTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(ModernTheme.dangerBg)

                Rectangle()
                    .fill(ModernTheme.border)
                    .frame(height: 1)
            }

            // 滚动表单主体
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 基本信息卡片
                    VStack(alignment: .leading, spacing: 12) {
                        Text("基本信息")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ModernTheme.textSecondary)

                        VStack(spacing: 10) {
                            EditorFieldRow(label: "项目名称") {
                                TextField("例如：football 后端与管理台", text: $editedProject.name)
                                    .textFieldStyle(.roundedBorder)
                            }

                            EditorFieldRow(label: "项目目录") {
                                HStack(spacing: 8) {
                                    TextField("/Users/you/Documents/project", text: $editedProject.path)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                    Button("选择…") {
                                        chooseProjectDirectory()
                                    }
                                    .buttonStyle(ModernButtonStyle(variant: .secondary, size: .xs))
                                }
                            }

                            EditorFieldRow(label: "备注说明") {
                                TextField("可选备注（显示在详情头部）", text: $editedProject.note)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(14)
                        .background(ModernTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(ModernTheme.border, lineWidth: 1)
                        }
                    }

                    // 启动项卡片列表
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("启动单元（\(editedProject.units.count)）")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(ModernTheme.textSecondary)
                            Spacer()
                            Text("启用多个启动单元时将按顺序依次启动")
                                .font(.system(size: 11))
                                .foregroundStyle(ModernTheme.textTertiary)
                        }

                        ForEach($editedProject.units) { $unit in
                            LaunchUnitEditorCard(
                                unit: $unit,
                                canRemove: editedProject.units.count > 1,
                                onRemove: {
                                    editedProject.units.removeAll { $0.id == unit.id }
                                }
                            )
                        }

                        Button {
                            editedProject.units.append(LaunchUnit(name: "新启动项", command: "./dev"))
                        } label: {
                            Label("添加启动单元", systemImage: "plus")
                        }
                        .buttonStyle(ModernButtonStyle(variant: .secondary, size: .small, fullWidth: true))
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 720, height: 620)
        .background(ModernTheme.background)
        .tint(ModernTheme.primary)
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "选择项目根目录"
        if FileManager.default.fileExists(atPath: editedProject.path) {
            panel.directoryURL = URL(fileURLWithPath: editedProject.path)
        }
        if panel.runModal() == .OK, let url = panel.url {
            editedProject.path = url.path
        }
    }
}

private struct EditorFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ModernTheme.textSecondary)
                .frame(width: 82, alignment: .leading)
            content
        }
    }
}

private struct LaunchUnitEditorCard: View {
    @Binding var unit: LaunchUnit
    let canRemove: Bool
    let onRemove: () -> Void

    @ViewState private var showAdvanced = false
    @ViewState private var showEndpoints = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: $unit.enabled) {
                    Text(unit.name.isEmpty ? "未命名启动项" : unit.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ModernTheme.textPrimary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                if canRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label("移除", systemImage: "trash")
                            .font(.system(size: 11.5))
                            .foregroundStyle(ModernTheme.danger)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().overlay(ModernTheme.border)

            EditorFieldRow(label: "单元名称") {
                TextField("例如：API 服务", text: $unit.name)
                    .textFieldStyle(.roundedBorder)
            }

            EditorFieldRow(label: "启动命令") {
                TextField("./dev 或 pnpm dev", text: $unit.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            DisclosureGroup(
                isExpanded: Binding(
                    get: { showAdvanced || unit.detached || unit.directory != "." || !unit.logFile.isEmpty },
                    set: { showAdvanced = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    EditorFieldRow(label: "工作目录") {
                        TextField("相对项目根目录，默认为 .", text: $unit.directory)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    EditorFieldRow(label: "日志文件") {
                        TextField("可选：已有业务日志文件路径", text: $unit.logFile)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Toggle("脚本拉起后台守护进程后立即退出（Detached 模式）", isOn: $unit.detached)
                        .font(.system(size: 12))
                        .padding(.top, 2)

                    if unit.detached {
                        EditorFieldRow(label: "停止命令") {
                            TextField("例如：./go-start stop admin", text: $unit.stopCommand)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        EditorFieldRow(label: "PID 文件") {
                            TextField("例如：.run/admin.pid", text: $unit.pidFile)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        EditorFieldRow(label: "可执行文件") {
                            TextField("后台二进制相对或绝对路径", text: $unit.executable)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("工作目录与后台守护选项")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ModernTheme.textSecondary)
            }

            DisclosureGroup(
                isExpanded: Binding(
                    get: { showEndpoints || !unit.endpoints.isEmpty },
                    set: { showEndpoints = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($unit.endpoints) { $endpoint in
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("服务名称", text: $endpoint.name)
                                    .textFieldStyle(.roundedBorder)

                                Picker("类型", selection: $endpoint.role) {
                                    Text("自动识别").tag(nil as ServiceRole?)
                                    ForEach(ServiceRole.allCases, id: \.self) { role in
                                        Text(role.label).tag(Optional(role))
                                    }
                                }
                                .frame(width: 140)

                                Button {
                                    unit.endpoints.removeAll { $0.id == endpoint.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(ModernTheme.danger)
                                }
                                .buttonStyle(.plain)
                                .help("移除此服务检查")
                            }

                            HStack(spacing: 8) {
                                TextField("打开地址 (http://localhost:3000)", text: $endpoint.url)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                TextField("就绪检查 (http://localhost:3000/health)", text: $endpoint.healthURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                        }
                        .padding(10)
                        .background(ModernTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    Button {
                        let nextPort = 3000 + unit.endpoints.count
                        unit.endpoints.append(
                            Endpoint(
                                name: "服务 \(unit.endpoints.count + 1)",
                                url: "http://127.0.0.1:\(nextPort)",
                                healthURL: "http://127.0.0.1:\(nextPort)"
                            )
                        )
                    } label: {
                        Label("添加服务地址与就绪检查", systemImage: "plus.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(ModernButtonStyle(variant: .ghost, size: .xs))
                }
                .padding(.top, 8)
            } label: {
                Text("服务地址与 HTTP 就绪检查（\(unit.endpoints.count)）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ModernTheme.textSecondary)
            }
        }
        .padding(14)
        .background(ModernTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ModernTheme.border, lineWidth: 1)
        }
    }
}
