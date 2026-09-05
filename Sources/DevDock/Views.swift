import SwiftUI
import AppKit

enum DockStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.65, green: 0.63, blue: 1, alpha: 1)
            : NSColor(red: 0.34, green: 0.31, blue: 0.78, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
    static let success = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.40, green: 0.83, blue: 0.60, alpha: 1)
            : NSColor(red: 0.12, green: 0.45, blue: 0.28, alpha: 1)
    })
}

struct ProjectGlyph: View {
    var name: String
    var size: CGFloat = 34
    private var symbol: String {
        if name.lowercased().contains("football") { return "soccerball" }
        if name.lowercased().contains("hospital") || name.contains("医院") { return "cross.case" }
        return "terminal"
    }
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(DockStyle.accent)
            .frame(width: size, height: size)
            .background(DockStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct DockSearch: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12))
                .focused($focused).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
            }
        }.padding(.horizontal, 10).padding(.vertical, 9)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DockStyle.accent.opacity(0.7) : DockStyle.hairline, lineWidth: 1))
    }
}

struct StatusLabel: View {
    let text: String
    var color: Color {
        switch text {
        case "已就绪", "运行中": return DockStyle.success
        case "已停止": return .secondary
        case "启动失败", "需要关注", "部分服务未就绪", "端口被占用": return .orange
        case "外部运行": return .blue
        default: return DockStyle.accent
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 11, weight: .medium))
        }.foregroundStyle(color)
    }
}

struct MenuPanel: View {
    @ObservedObject var store: ProjectStore
    var openProject: (UUID?) -> Void
    var quit: () -> Void
    @State private var query = ""
    private var filtered: [Project] { store.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProjectGlyph(name: "DevDock", size: 30)
                Text("DevDock").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(store.activeCount) 个运行中").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
            DockSearch(placeholder: "搜索项目", text: $query).padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { project in
                        HStack(spacing: 10) {
                            Button { openProject(project.id) } label: {
                                HStack(spacing: 10) {
                                    ProjectGlyph(name: project.name, size: 32)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        StatusLabel(text: store.status(project))
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help("查看 \(project.name) 的状态与日志")
                            if store.busy.contains(project.id) { ProgressView().controlSize(.small) }
                            if store.isActive(project) || store.busy.contains(project.id) {
                                Button { store.stop(project, restart: true) } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 22)
                                }.buttonStyle(.bordered).tint(DockStyle.accent)
                                    .disabled(store.busy.contains(project.id))
                                    .help("重启项目")
                                    .accessibilityLabel("重启 \(project.name)")
                            }
                            Button {
                                if store.isActive(project) || store.busy.contains(project.id) { store.stop(project) }
                                else { store.launch(project) }
                            } label: {
                                Image(systemName: store.isActive(project) || store.busy.contains(project.id) ? "stop.fill" : "play.fill")
                                    .font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 22)
                            }.buttonStyle(.bordered).tint(DockStyle.accent)
                                .disabled(store.phases[project.id] == "正在停止" && store.busy.contains(project.id))
                                .help(store.isActive(project) || store.busy.contains(project.id) ? "停止项目" : "启动项目")
                                .accessibilityLabel(store.isActive(project) || store.busy.contains(project.id) ? "停止 \(project.name)" : "启动 \(project.name)")
                        }.padding(.horizontal, 10).padding(.vertical, 10)
                    }
                    if filtered.isEmpty {
                        Text(store.projects.isEmpty ? "添加项目，开始一键启动。" : "没有匹配的项目")
                            .font(.callout).foregroundStyle(.secondary).padding(24)
                    }
                }.padding(.horizontal, 8)
            }.frame(height: min(360, CGFloat(max(1, filtered.count)) * 66 + 8))
            Divider().padding(.top, 8)
            HStack {
                Button { openProject(nil) } label: { Label("项目与日志", systemImage: "sidebar.left") }.font(.system(size: 12))
                Spacer()
                Button { quit() } label: { Image(systemName: "power").font(.system(size: 12)) }
                    .help("停止 DevDock 管理的服务并退出").accessibilityLabel("退出 DevDock")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 14)
        }.frame(width: 370).background(DockStyle.surface).tint(DockStyle.accent)
    }
}

struct MainView: View {
    @ObservedObject var store: ProjectStore
    @Binding var selected: UUID?
    @State private var query = ""
    @State private var editing: Project?
    var selectedProject: Project? { store.projects.first { $0.id == selected } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ProjectGlyph(name: "DevDock", size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DevDock").font(.system(size: 17, weight: .semibold))
                        Text("本地项目，随时就绪").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 22)
                DockSearch(placeholder: "搜索项目", text: $query).padding(.horizontal, 14)
                HStack {
                    Text("项目").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(String(store.projects.count)).font(.system(size: 11)).monospacedDigit()
                }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 8)
                List(selection: $selected) {
                    ForEach(store.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { project in
                        HStack(spacing: 10) {
                            ProjectGlyph(name: project.name, size: 32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(project.name)
                                StatusLabel(text: store.status(project))
                            }
                        }.padding(.vertical, 9).tag(project.id).listRowSeparator(.hidden)
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                HStack(spacing: 6) {
                    Circle().fill(store.activeCount > 0 ? DockStyle.success : Color.secondary).frame(width: 5, height: 5)
                    Text("\(store.activeCount) 个项目运行中").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 20).padding(.bottom, 16)
                Divider().padding(.horizontal, 16)
                HStack {
                    Menu {
                        Button("扫描项目目录…") { store.importFolder() }
                        Button("手动添加…") { manualAdd() }
                    } label: { Label("添加项目", systemImage: "plus") }
                        .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12, weight: .medium))
                    Spacer()
                    if store.scanning { ProgressView().controlSize(.small) }
                }.padding(18)
            }.frame(minWidth: 220, idealWidth: 250, maxWidth: 310).background(DockStyle.canvas)
            Group {
                if let project = selectedProject {
                    ProjectDetail(store: store, project: project, edit: { editing = project }).id(project.id)
                } else {
                    VStack(spacing: 16) {
                        ProjectGlyph(name: "DevDock", size: 64)
                        Text("项目留在菜单栏，终端留给工作。").font(.title3.weight(.medium))
                        Text("选择左侧项目查看状态与日志，或扫描一个项目目录。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("扫描项目目录…") { store.importFolder() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DockStyle.surface)
                }
            }.frame(minWidth: 570, maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 820, minHeight: 540).tint(DockStyle.accent)
        .sheet(item: $editing) { project in
            ProjectEditor(project: project) { updated in try store.update(updated); selected = updated.id }.tint(DockStyle.accent)
        }
        .alert("DevDock", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onAppear { if selected == nil { selected = store.projects.first?.id } }
    }

    private func manualAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = "选择项目目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editing = Discovery.project(at: url) ?? Project(name: url.lastPathComponent, path: url.path, units: [LaunchUnit(name: "项目", command: "./dev")])
    }
}

struct ProjectDetail: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    var edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ProjectGlyph(name: project.name, size: 48)
                VStack(alignment: .leading, spacing: 7) {
                    Text(project.name).font(.system(size: 23, weight: .semibold)).textSelection(.enabled).lineLimit(2)
                    Text(project.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(project.path)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("编辑启动配置…", action: edit).disabled(store.isActive(project) || store.busy.contains(project.id))
                    Button("在 Finder 中显示") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) }
                    Button("显示日志目录") { NSWorkspace.shared.open(store.logsURL) }
                    Divider()
                    Button("从列表移除", role: .destructive) { store.remove(project) }.disabled(store.isActive(project) || store.busy.contains(project.id))
                } label: { Image(systemName: "ellipsis").font(.system(size: 17)).frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().help("项目选项")
            }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)
            HStack(spacing: 12) {
                StatusLabel(text: store.status(project))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.035), in: Capsule())
                if let started = store.startedAt(project) {
                    Text("启动于 \(started.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isActive(project) || store.busy.contains(project.id) {
                    Button { store.stop(project) } label: { Label("停止", systemImage: "stop.fill") }
                        .disabled(store.phases[project.id] == "正在停止" && store.busy.contains(project.id))
                    Button { store.stop(project, restart: true) } label: { Label("重启", systemImage: "arrow.clockwise") }.disabled(store.busy.contains(project.id))
                } else {
                    Button { store.launch(project) } label: { Label("启动项目", systemImage: "play.fill").padding(.horizontal, 5) }
                        .buttonStyle(.borderedProminent)
                }
            }.controlSize(.large).padding(.horizontal, 28).padding(.bottom, 22)
            if let notice = store.notices[project.id] {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 28).padding(.bottom, 16)
            }
            serviceList
            LogViewer(store: store, project: project).padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 18)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DockStyle.surface)
    }

    private var serviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("服务").font(.system(size: 12, weight: .semibold))
                Text(String(project.enabledUnits.count) + " 个启动项").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.bottom, 9)
            ForEach(project.enabledUnits) { unit in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(unit.name).font(.system(size: 12, weight: .medium))
                        Text(unit.command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).textSelection(.enabled).help(unit.command)
                        if let pid = store.processID(unit) {
                            Text(verbatim: "PID " + String(pid)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }.frame(width: 180, alignment: .leading)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(store.displayedEndpoints(unit)) { endpoint in
                            let state = store.endpointStates[endpoint.id] ?? .stopped
                            HStack(spacing: 7) {
                                Image(systemName: state == .ready ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11)).foregroundStyle(endpointColor(state))
                                Text(endpoint.name).font(.system(size: 11))
                                Spacer()
                                Text(state.label).font(.system(size: 10)).foregroundStyle(endpointColor(state))
                                    .help(endpointHint(state))
                                if let url = URL(string: endpoint.url) {
                                    Link(destination: url) {
                                        HStack(spacing: 5) {
                                            Text(verbatim: url.port.map { ":" + String($0) } ?? "打开").font(.system(size: 11, design: .monospaced))
                                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                                        }
                                    }.disabled(!state.isOwned).foregroundStyle(state.isOwned ? DockStyle.accent : Color.secondary)
                                        .help(state.isOwned ? endpoint.url : endpointHint(state))
                                }
                            }
                        }
                        if store.displayedEndpoints(unit).isEmpty {
                            Text(store.isActive(unit) ? "尚未发现监听端口" : "启动后自动识别端口").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                    if project.enabledUnits.count > 1 {
                        Button { store.isActive(unit) ? store.stop(project, only: unit.id) : store.launch(project, only: unit.id) } label: {
                            Image(systemName: store.isActive(unit) ? "stop.fill" : "play.fill").font(.system(size: 10)).frame(width: 18, height: 20)
                        }.disabled(store.busy.contains(project.id))
                            .help(store.isActive(unit) ? "停止 \(unit.name)" : "启动 \(unit.name)")
                            .accessibilityLabel(store.isActive(unit) ? "停止 \(unit.name)" : "启动 \(unit.name)")
                    }
                }.padding(.vertical, 12)
                if unit.id != project.enabledUnits.last?.id { Divider() }
            }
        }.padding(.horizontal, 28)
    }

    private func endpointColor(_ state: EndpointState) -> Color {
        switch state {
        case .ready: return DockStyle.success
        case .listening: return DockStyle.accent
        case .occupied, .unready: return .orange
        case .stopped: return .secondary
        }
    }

    private func endpointHint(_ state: EndpointState) -> String {
        switch state {
        case .occupied(let pid): return "由其他进程 PID \(pid) 占用，不属于这个启动项。"
        case .listening: return "已确认属于本项目的 TCP 监听端口；未配置 HTTP 就绪检查。"
        case .ready: return "进程归属和 HTTP 就绪检查均已通过。"
        case .unready: return "端口属于本项目，但 HTTP 就绪检查尚未通过。"
        case .stopped: return "未发现属于本项目的监听进程。"
        }
    }
}

struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var project: Project
    var save: (Project) throws -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("启动配置").font(.title2.weight(.semibold)).padding(20)
            ScrollView {
                Form {
                    TextField("项目名称", text: $project.name)
                    TextField("项目目录", text: $project.path)
                    if !project.note.isEmpty { Text(project.note).font(.caption).foregroundStyle(.secondary) }
                    ForEach($project.units) { $unit in
                        Section {
                            UnitEditor(unit: $unit)
                            if project.units.count > 1 {
                                Button("移除此启动项", role: .destructive) { project.units.removeAll { $0.id == unit.id } }
                            }
                        } header: { Text(unit.name).font(.headline) }
                    }
                    Button { project.units.append(LaunchUnit(name: "新服务", command: "npm run dev")) } label: { Label("添加启动项", systemImage: "plus") }
                }.formStyle(.grouped)
            }
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 20) }
            HStack {
                Text("启动项按列表顺序执行；扫描和保存不会执行命令。") .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { do { try save(project); dismiss() } catch { self.error = error.localizedDescription } }
                    .keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 680, height: 670)
    }
}

struct UnitEditor: View {
    @Binding var unit: LaunchUnit
    var body: some View {
        Toggle("随项目启动", isOn: $unit.enabled)
        TextField("名称", text: $unit.name)
        TextField("工作目录（相对项目）", text: $unit.directory)
        TextField("启动命令", text: $unit.command)
        TextField("已有日志文件（可选）", text: $unit.logFile)
        Toggle("脚本启动后台服务后退出", isOn: $unit.detached)
        if unit.detached {
            TextField("停止命令", text: $unit.stopCommand)
            TextField("PID 文件", text: $unit.pidFile)
            TextField("后台可执行文件路径", text: $unit.executable)
        }
        ForEach($unit.endpoints) { $endpoint in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("服务名称", text: $endpoint.name)
                    Button { unit.endpoints.removeAll { $0.id == endpoint.id } } label: { Image(systemName: "minus.circle") }.help("移除服务检查")
                }
                TextField("打开地址", text: $endpoint.url)
                TextField("就绪检查地址", text: $endpoint.healthURL)
            }.padding(.vertical, 4)
        }
        Button("添加服务检查") {
            unit.endpoints.append(Endpoint(name: "服务 \(unit.endpoints.count + 1)", url: "http://127.0.0.1:3000", healthURL: "http://127.0.0.1:3000"))
        }
    }
}

struct LogViewer: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    @State private var selectedPath = ""
    @State private var text = ""
    @State private var query = ""
    @State private var errorsOnly = false
    @State private var follow = true

    var sources: [(name: String, url: URL)] { store.logSources(project) }
    var currentPath: String { selectedPath.isEmpty ? (sources.first?.url.path ?? "") : selectedPath }
    var visible: String {
        if query.isEmpty && !errorsOnly { return text }
        return text.components(separatedBy: "\n").filter { line in
            (query.isEmpty || line.localizedCaseInsensitiveContains(query)) && (!errorsOnly || Self.isError(line))
        }.joined(separator: "\n")
    }
    static func isError(_ line: String) -> Bool { ["error", "fatal", "panic", "失败", "错误"].contains { line.localizedCaseInsensitiveContains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("日志").font(.system(size: 12, weight: .semibold))
                if !sources.isEmpty {
                    Menu {
                        Button("最新日志（实时）") { selectedPath = "" }
                        Divider()
                        ForEach(sources, id: \.url.path) { item in
                            Button(item.name) { selectedPath = item.url.path }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(sources.first(where: { $0.url.path == selectedPath })?.name ?? "最新日志（实时）").lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(.system(size: 11)).foregroundStyle(.primary)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(DockStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DockStyle.hairline, lineWidth: 1))
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 290, alignment: .leading).accessibilityLabel("日志来源")
                }
                Spacer(minLength: 8)
                Button { follow.toggle() } label: {
                    Image(systemName: "arrow.down.to.line").frame(width: 18, height: 18).padding(5)
                        .foregroundStyle(follow ? DockStyle.accent : Color.secondary)
                        .background(DockStyle.accent.opacity(follow ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                    .help(follow ? "关闭自动滚动" : "跟随最新日志").accessibilityLabel("自动滚动").accessibilityValue(follow ? "已开启" : "已关闭")
                Button { exportLog() } label: { Image(systemName: "square.and.arrow.up").frame(width: 18, height: 18) }
                    .controlSize(.small).help("导出当前日志").accessibilityLabel("导出当前日志").disabled(currentPath.isEmpty)
            }.padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)
            HStack(spacing: 12) {
                DockSearch(placeholder: "搜索日志内容", text: $query)
                Toggle("仅错误", isOn: $errorsOnly).toggleStyle(.checkbox).font(.system(size: 11))
            }.padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            if text.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 27, weight: .light)).foregroundStyle(DockStyle.accent.opacity(0.75))
                    Text(currentPath.isEmpty ? "日志从这里开始" : "等待日志输出…").font(.system(size: 13, weight: .medium))
                    Text("启动项目后，实时查看输出与错误。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 22).background(Color(nsColor: .textBackgroundColor))
            } else {
                NativeLogText(text: visible, follow: follow)
            }
            Divider()
            HStack(spacing: 6) {
                Text("\(visible.split(separator: "\n").count) 行").monospacedDigit()
                Text("· 最近 512 KB")
                Spacer()
                Circle().fill(follow ? DockStyle.accent : Color.secondary).frame(width: 4, height: 4)
                Text(follow ? "实时跟随" : "保留滚动位置")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }.background(DockStyle.canvas.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DockStyle.hairline, lineWidth: 1))
        .task {
            while !Task.isCancelled {
                let path = currentPath
                if !path.isEmpty {
                    let next = await Task.detached(priority: .utility) { tailText(URL(fileURLWithPath: path)) }.value
                    if currentPath == path, next != text { text = next }
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
        .onChange(of: selectedPath) { _ in text = "" }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = project.name + ".log"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try Data(contentsOf: URL(fileURLWithPath: currentPath)).write(to: target, options: .atomic) }
        catch { store.error = "导出失败：\(error.localizedDescription)" }
    }
}

struct NativeLogText: NSViewRepresentable {
    let text: String
    let follow: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 16, height: 15)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("项目日志")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let origin = scroll.contentView.bounds.origin
        let selection = view.selectedRange()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph])
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, _, _ in
            if let line, LogViewer.isError(line) { attributed.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range) }
        }
        view.textStorage?.setAttributedString(attributed)
        if NSMaxRange(selection) <= ns.length { view.setSelectedRange(selection) }
        if follow { view.scrollToEndOfDocument(nil) }
        else { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }
}
