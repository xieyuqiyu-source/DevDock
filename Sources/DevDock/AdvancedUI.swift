import SwiftUI
import AppKit

// MARK: - 统一设计系统（OrbStack / Linear / Raycast 风格）
enum ModernTheme {
    // 品牌强调色（克制高对比靛蓝）
    static let primary = adaptive(0x4F46E5, 0x818CF8)
    static let primaryHover = adaptive(0x4338CA, 0x6366F1)
    static let primarySoft = adaptive(0xEEF2FF, 0x1E2238)

    // 运行 / 就绪（翡翠绿）
    static let success = adaptive(0x059669, 0x34D399)
    static let successBg = adaptive(0xECFDF5, 0x0D2820)

    // 警告 / 未就绪 / 端口冲突（琥珀色）
    static let warning = adaptive(0xD97706, 0xFBBF24)
    static let warningBg = adaptive(0xFFFBEB, 0x2A200C)

    // 危险 / 失败（绯红色）
    static let danger = adaptive(0xDC2626, 0xF87171)
    static let dangerBg = adaptive(0xFEF2F2, 0x2C1418)

    // 表面层级
    static let sidebar = adaptive(0xF1F3F6, 0x14161A)
    static let background = adaptive(0xF7F8FA, 0x101114)
    static let surface = adaptive(0xFFFFFF, 0x181A20)
    static let surfaceSubtle = adaptive(0xF2F4F7, 0x1F222A)
    static let surfaceHover = adaptive(0xEBEEF3, 0x252932)
    static let codeBg = adaptive(0xEFF1F5, 0x21242D)

    // 终端日志区
    static let terminalBg = adaptive(0xF9FAFC, 0x0C0E12)
    static let terminalHeader = adaptive(0xF1F3F7, 0x14171E)
    static let terminalGutter = adaptive(0xF3F5F8, 0x101319)

    // 边框（1px 精细分割）
    static let border = adaptive(0xE3E6EC, 0x252831)
    static let borderStrong = adaptive(0xCFD4DE, 0x343846)

    // 文本层级
    static let textPrimary = adaptive(0x111827, 0xF3F4F6)
    static let textSecondary = adaptive(0x4B5563, 0x9CA3AF)
    static let textTertiary = adaptive(0x858E9D, 0x6B7280)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - 状态语义映射
struct StatusVisual {
    let text: String
    let color: Color
    let background: Color
    let icon: String
    let isRunning: Bool
    let isBusy: Bool

    static func forProject(_ status: String) -> StatusVisual {
        switch status {
        case "已就绪":
            return StatusVisual(text: status, color: ModernTheme.success, background: ModernTheme.successBg, icon: "checkmark.circle.fill", isRunning: true, isBusy: false)
        case "运行中", "外部运行", "外部监听":
            return StatusVisual(text: status, color: ModernTheme.success, background: ModernTheme.successBg, icon: "bolt.horizontal.circle.fill", isRunning: true, isBusy: false)
        case "部分服务未就绪", "端口被占用":
            return StatusVisual(text: status, color: ModernTheme.warning, background: ModernTheme.warningBg, icon: "exclamationmark.circle.fill", isRunning: status == "部分服务未就绪", isBusy: false)
        case "启动失败", "需要关注":
            return StatusVisual(text: status, color: ModernTheme.danger, background: ModernTheme.dangerBg, icon: "exclamationmark.triangle.fill", isRunning: status == "需要关注", isBusy: false)
        case "已停止":
            return StatusVisual(text: status, color: ModernTheme.textTertiary, background: ModernTheme.surfaceSubtle, icon: "circle", isRunning: false, isBusy: false)
        default:
            return StatusVisual(text: status, color: ModernTheme.primary, background: ModernTheme.primarySoft, icon: "arrow.triangle.2.circlepath", isRunning: false, isBusy: true)
        }
    }

    static func forEndpoint(_ state: EndpointState) -> StatusVisual {
        switch state {
        case .ready:
            return StatusVisual(text: "已就绪", color: ModernTheme.success, background: ModernTheme.successBg, icon: "checkmark.circle.fill", isRunning: true, isBusy: false)
        case .listening:
            return StatusVisual(text: "监听中", color: ModernTheme.primary, background: ModernTheme.primarySoft, icon: "dot.radiowaves.left.and.right", isRunning: true, isBusy: false)
        case .unready:
            return StatusVisual(text: "未就绪", color: ModernTheme.warning, background: ModernTheme.warningBg, icon: "clock.fill", isRunning: true, isBusy: false)
        case .occupied(let pid):
            return StatusVisual(text: "占用 (PID \(String(pid)))", color: ModernTheme.danger, background: ModernTheme.dangerBg, icon: "xmark.octagon.fill", isRunning: false, isBusy: false)
        case .stopped:
            return StatusVisual(text: "未监听", color: ModernTheme.textTertiary, background: ModernTheme.surfaceSubtle, icon: "minus.circle", isRunning: false, isBusy: false)
        }
    }
}

// MARK: - 原生毛玻璃材质背景
struct VisualEffectSurface: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - 现代化按钮样式
struct ModernButtonStyle: ButtonStyle {
    var variant: Variant = .primary
    var size: Size = .medium
    var fullWidth = false

    enum Variant {
        case primary, secondary, ghost, danger
    }

    enum Size {
        case xs, small, medium, large

        var height: CGFloat {
            switch self {
            case .xs: return 24
            case .small: return 28
            case .medium: return 34
            case .large: return 40
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .xs: return 11
            case .small: return 12
            case .medium: return 13
            case .large: return 14
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .xs: return 8
            case .small: return 11
            case .medium: return 14
            case .large: return 18
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .xs: return 6
            case .small: return 7
            case .medium, .large: return 8
            }
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        ButtonChrome(style: self, configuration: configuration)
    }

    func foregroundColor(isPressed: Bool) -> Color {
        let color: Color
        switch variant {
        case .primary, .danger: color = .white
        case .secondary: color = ModernTheme.textPrimary
        case .ghost: color = ModernTheme.textSecondary
        }
        return isPressed ? color.opacity(0.8) : color
    }

    private struct ButtonChrome: View {
        let style: ModernButtonStyle
        let configuration: ModernButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var hovered = false

        var body: some View {
            let radius = style.size.cornerRadius
            configuration.label
                .font(.system(size: style.size.fontSize, weight: .medium))
                .foregroundStyle(style.foregroundColor(isPressed: configuration.isPressed))
                .padding(.horizontal, style.size.horizontalPadding)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                .frame(height: style.size.height)
                .background(fillColor, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                }
                .opacity(isEnabled ? 1.0 : 0.45)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovered)
                .onHover { hovered = $0 }
        }

        private var fillColor: Color {
            if configuration.isPressed {
                switch style.variant {
                case .primary: return ModernTheme.primaryHover
                case .danger: return ModernTheme.danger.opacity(0.88)
                case .secondary: return ModernTheme.surfaceHover
                case .ghost: return ModernTheme.surfaceHover
                }
            }
            if hovered && isEnabled {
                switch style.variant {
                case .primary: return ModernTheme.primaryHover
                case .danger: return ModernTheme.danger.opacity(0.92)
                case .secondary: return ModernTheme.surfaceSubtle
                case .ghost: return ModernTheme.surfaceSubtle
                }
            }
            switch style.variant {
            case .primary: return ModernTheme.primary
            case .danger: return ModernTheme.danger
            case .secondary: return ModernTheme.surface
            case .ghost: return Color.clear
            }
        }

        private var borderColor: Color {
            switch style.variant {
            case .primary: return Color.white.opacity(0.14)
            case .danger: return Color.white.opacity(0.14)
            case .secondary: return hovered && isEnabled ? ModernTheme.borderStrong : ModernTheme.border
            case .ghost: return Color.clear
            }
        }
    }
}

// MARK: - 悬停微交互图标按钮
struct IconActionButton: View {
    let icon: String
    var title: String? = nil
    var isActive: Bool = false
    var size: CGFloat = 28
    var helpText: String = ""
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(isActive ? ModernTheme.primary : (hovered ? ModernTheme.textPrimary : ModernTheme.textSecondary))
            .padding(.horizontal, title == nil ? 0 : 9)
            .frame(minWidth: size, minHeight: size)
            .background(
                isActive ? ModernTheme.primarySoft : (hovered && isEnabled ? ModernTheme.surfaceHover : Color.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(ModernTheme.primary.opacity(0.25), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .help(helpText)
        .accessibilityLabel(helpText.isEmpty ? (title ?? icon) : helpText)
        .onHover { hovered = $0 }
    }
}

// MARK: - 语义化状态胶囊
struct StatusBadge: View {
    let visual: StatusVisual
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if visual.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(visual.color)
                    .frame(width: 6, height: 6)
            }
            Text(visual.text)
                .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(visual.color)
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 3 : 4)
        .background(visual.background, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(visual.color.opacity(0.18), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 项目图标组件
struct ProjectIconView: View {
    let name: String
    var size: CGFloat = 40

    private var info: (icon: String, gradient: [Color]) {
        let lower = name.lowercased()
        if lower.contains("football") || lower.contains("sport") || name.contains("球") {
            return ("soccerball", [Color(hex: 0x10B981), Color(hex: 0x047857)])
        } else if lower.contains("hospital") || name.contains("医院") || name.contains("医") {
            return ("cross.case.fill", [Color(hex: 0xF43F5E), Color(hex: 0xBE123C)])
        } else if lower.contains("game") || name.contains("游戏") || name.contains("君陌") {
            return ("gamecontroller.fill", [Color(hex: 0x8B5CF6), Color(hex: 0x6D28D9)])
        } else if lower.contains("web") || lower.contains("admin") || name.contains("网页") || name.contains("后台") {
            return ("globe", [Color(hex: 0x0EA5E9), Color(hex: 0x0369A1)])
        } else if lower.contains("api") || lower.contains("server") || lower.contains("go") {
            return ("server.rack", [Color(hex: 0xF59E0B), Color(hex: 0xB45309)])
        } else if name.contains("助手") || lower.contains("ai") || lower.contains("bot") {
            return ("cpu.fill", [Color(hex: 0x6366F1), Color(hex: 0x4338CA)])
        } else {
            return ("terminal.fill", [Color(hex: 0x4F46E5), Color(hex: 0x3730A3)])
        }
    }

    var body: some View {
        let radius = round(size * 0.25)
        ZStack {
            LinearGradient(colors: info.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: info.icon)
                .font(.system(size: round(size * 0.43), weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 无原生双焦点环的纯净输入框
struct CleanTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var fontSize: CGFloat = 12.5

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if isFocused, let window = nsView.window, window.firstResponder !== nsView.currentEditor() {
            DispatchQueue.main.async {
                if self.isFocused, nsView.window?.firstResponder !== nsView.currentEditor() {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CleanTextField

        init(_ parent: CleanTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if !parent.text.isEmpty {
                    parent.text = ""
                } else {
                    control.window?.makeFirstResponder(nil)
                    parent.isFocused = false
                }
                return true
            }
            return false
        }
    }
}

// MARK: - 精致搜索栏
struct ModernSearchBar: View {
    @Binding var text: String
    let placeholder: String
    var shortcutHint: String? = nil
    var compact: Bool = false
    var requestedFocus: Binding<Bool>? = nil

    @ViewState private var internalFocused = false

    private var focusBinding: Binding<Bool> {
        requestedFocus ?? $internalFocused
    }

    var body: some View {
        let active = focusBinding.wrappedValue
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                .foregroundStyle(active ? ModernTheme.primary : ModernTheme.textTertiary)

            CleanTextField(
                placeholder: placeholder,
                text: $text,
                isFocused: focusBinding,
                fontSize: compact ? 12 : 12.5
            )
            .frame(height: compact ? 16 : 18)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ModernTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            } else if let shortcutHint, !active {
                Text(shortcutHint)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(ModernTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(ModernTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(ModernTheme.border, lineWidth: 1)
                    }
            }
        }
        .padding(.horizontal, compact ? 9 : 10)
        .frame(height: compact ? 28 : 32)
        .background(ModernTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(active ? ModernTheme.primary : ModernTheme.border, lineWidth: active ? 1.5 : 1)
        }
    }
}

// MARK: - 总览工作台（Dashboard）
struct DashboardView: View {
    @ObservedObject var store: ProjectStore
    let searchQuery: String
    let onSelectProject: (UUID, Bool) -> Void
    let onManualAdd: () -> Void

    private var stats: (total: Int, running: Int, ports: Int, alerts: Int) {
        let running = store.projects.filter { store.isActive($0) }.count
        let ports = store.projects.reduce(0) { $0 + store.browserEndpoints($1).count }
        let alerts = store.projects.filter {
            store.notices[$0.id] != nil || store.status($0) == "端口被占用"
        }.count
        return (store.projects.count, running, ports, alerts)
    }

    private var filtered: [Project] {
        guard !searchQuery.isEmpty else { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.path.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 紧凑指标栏
                HStack(spacing: 12) {
                    StatCard(
                        title: "项目总数",
                        value: "\(stats.total)",
                        subtitle: stats.total > 0 ? "支持拖拽调整优先级" : "尚未导入本地仓库",
                        icon: "square.stack.3d.up.fill",
                        color: ModernTheme.primary
                    )
                    StatCard(
                        title: "运行服务",
                        value: "\(stats.running)",
                        subtitle: stats.running > 0 ? "进程实时守护中" : "当前全部空闲",
                        icon: "bolt.horizontal.fill",
                        color: stats.running > 0 ? ModernTheme.success : ModernTheme.textTertiary
                    )
                    StatCard(
                        title: "活跃端口",
                        value: "\(stats.ports)",
                        subtitle: stats.ports > 0 ? "点击卡片端口一键访问" : "启动后自动关联监听",
                        icon: "network",
                        color: stats.ports > 0 ? ModernTheme.primary : ModernTheme.textTertiary
                    )
                    StatCard(
                        title: "异常告警",
                        value: "\(stats.alerts)",
                        subtitle: stats.alerts > 0 ? "存在冲突或退出通知" : "所有服务状态健康",
                        icon: stats.alerts > 0 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill",
                        color: stats.alerts > 0 ? ModernTheme.danger : ModernTheme.success
                    )
                }

                // 项目区域标题
                HStack(alignment: .firstTextBaseline) {
                    Text(searchQuery.isEmpty ? "全部项目" : "搜索结果（\(filtered.count)）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ModernTheme.textSecondary)
                    Spacer()
                    if !store.projects.isEmpty {
                        Text("每 \(Int(AppConfiguration.processRefreshInterval)) 秒同步进程与端口归属")
                            .font(.system(size: 11))
                            .foregroundStyle(ModernTheme.textTertiary)
                    }
                }

                if filtered.isEmpty {
                    EmptyStateView(
                        icon: searchQuery.isEmpty ? "folder.badge.gearshape" : "magnifyingglass",
                        title: searchQuery.isEmpty ? "开始托管你的本地开发项目" : "没有找到匹配「\(searchQuery)」的项目",
                        subtitle: searchQuery.isEmpty
                            ? "扫描工作区目录即可自动识别 dev 脚本、Go 服务、Vite 与 Node.js 项目"
                            : "可在左侧搜索栏按 Esc 清空过滤条件",
                        primaryTitle: searchQuery.isEmpty ? "扫描项目目录…" : nil,
                        primaryAction: searchQuery.isEmpty ? { store.importFolder() } : nil,
                        secondaryTitle: searchQuery.isEmpty ? "手动添加…" : nil,
                        secondaryAction: searchQuery.isEmpty ? onManualAdd : nil
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 14, alignment: .top)],
                        spacing: 14
                    ) {
                        ForEach(filtered) { project in
                            ProjectCard(
                                store: store,
                                project: project,
                                onSelect: { openLogs in onSelectProject(project.id, openLogs) }
                            )
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(ModernTheme.background)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ModernTheme.textSecondary)
                Spacer(minLength: 4)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ModernTheme.textPrimary)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(ModernTheme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ModernTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ModernTheme.border, lineWidth: 1)
        }
    }
}

// MARK: - 总览项目卡片
struct ProjectCard: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    let onSelect: (Bool) -> Void

    @ViewState private var hovered = false

    private var statusVisual: StatusVisual {
        StatusVisual.forProject(store.status(project))
    }

    private var liveEndpoints: [Endpoint] {
        store.browserEndpoints(project)
    }

    var body: some View {
        let busy = store.busy.contains(project.id)
        let active = store.isActive(project)

        VStack(alignment: .leading, spacing: 0) {
            // 头部点击进入详情
            Button {
                onSelect(false)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        ProjectIconView(name: project.name, size: 38)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ModernTheme.textPrimary)
                                .lineLimit(1)

                            Text(ModernTheme.abbreviatedPath(project.path))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ModernTheme.textTertiary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        StatusBadge(visual: statusVisual, compact: true)
                    }

                    // 告警条（如有）
                    if let notice = store.notices[project.id] {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(ModernTheme.warning)
                            Text(notice)
                                .font(.system(size: 11))
                                .foregroundStyle(ModernTheme.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ModernTheme.warningBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    // 服务单元概览
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(project.enabledUnits.prefix(3)) { unit in
                            ServiceRowCompact(store: store, unit: unit)
                        }
                        if project.enabledUnits.count > 3 {
                            Text("其余 \(project.enabledUnits.count - 3) 个启动项…")
                                .font(.system(size: 11))
                                .foregroundStyle(ModernTheme.textTertiary)
                        }
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(project.name)")

            // 如果有可直达端口，展示快捷端口胶囊条
            if !liveEndpoints.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(liveEndpoints) { endpoint in
                            if let url = URL(string: endpoint.url) {
                                let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                                Link(destination: url) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(ModernTheme.success)
                                            .frame(width: 5, height: 5)
                                        Text(endpoint.name)
                                            .lineLimit(1)
                                        Text(verbatim: ":\(port)")
                                            .fontDesign(.monospaced)
                                            .foregroundStyle(ModernTheme.primary)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(ModernTheme.primary)
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ModernTheme.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(ModernTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(ModernTheme.border, lineWidth: 1)
                                    }
                                }
                                .help(endpoint.url)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }

            Divider().overlay(ModernTheme.border)

            // 卡片底部操作栏
            HStack(spacing: 6) {
                Button {
                    onSelect(false)
                } label: {
                    Label("详情", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(ModernButtonStyle(variant: .ghost, size: .xs))

                Button {
                    onSelect(true)
                } label: {
                    Label("日志", systemImage: "terminal")
                }
                .buttonStyle(ModernButtonStyle(variant: .ghost, size: .xs))

                Spacer(minLength: 4)

                if active && !busy && store.canRestart(project) {
                    IconActionButton(icon: "arrow.clockwise", size: 24, helpText: "重启 \(project.name)") {
                        store.stop(project, restart: true)
                    }
                }

                if !busy && !active {
                    Button {
                        store.launch(project)
                    } label: {
                        Label("启动", systemImage: "play.fill")
                    }
                    .buttonStyle(ModernButtonStyle(variant: .primary, size: .xs))
                } else {
                    Button(busy ? (store.phases[project.id] == "正在停止" ? "停止中" : "启动中") : (store.canStop(project) ? "停止" : "外部监听")) {
                        store.stop(project)
                    }
                    .buttonStyle(ModernButtonStyle(variant: store.canStop(project) || busy ? .danger : .secondary, size: .xs))
                    .disabled(store.phases[project.id] == "正在停止" || (!busy && !store.canStop(project)))
                    .help(active && !store.canStop(project) ? "外部服务请使用原启动方式停止" : "停止 \(project.name)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(ModernTheme.surfaceSubtle.opacity(0.45))
        }
        .background(ModernTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(hovered ? ModernTheme.borderStrong : ModernTheme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(hovered ? 0.06 : 0.02), radius: hovered ? 10 : 4, y: 2)
        .animation(.easeOut(duration: 0.14), value: hovered)
        .onHover { hovered = $0 }
    }
}

struct ServiceRowCompact: View {
    @ObservedObject var store: ProjectStore
    let unit: LaunchUnit

    var body: some View {
        let active = store.isActive(unit)
        HStack(spacing: 7) {
            Circle()
                .fill(active ? ModernTheme.success : ModernTheme.textTertiary.opacity(0.6))
                .frame(width: 6, height: 6)

            Text(unit.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ModernTheme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if let pid = store.processID(unit) {
                Text(verbatim: "PID \(pid)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ModernTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(ModernTheme.codeBg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Text(unit.command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ModernTheme.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
        }
    }
}

// MARK: - 空状态组件
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var primaryTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(ModernTheme.primary)
                .frame(width: 60, height: 60)
                .background(ModernTheme.primarySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ModernTheme.textPrimary)

                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ModernTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: 10) {
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(ModernButtonStyle(variant: .primary, size: .small))
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(ModernButtonStyle(variant: .secondary, size: .small))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
    }
}

// MARK: - 原生 NSMenu 触发按钮（完全保留自定义 SwiftUI 按钮视觉，消除 NSPopUpButton 边框割裂）
struct MenuAction {
    enum Role { case normal, destructive, separator }
    let title: String
    var role: Role = .normal
    var isEnabled: Bool = true
    var action: () -> Void = {}

    static var separator: MenuAction { MenuAction(title: "", role: .separator) }
}

private final class MenuTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

private struct AnchorViewReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView) }
    }
}

struct NativeMenuButton<Label: View>: View {
    let items: [MenuAction]
    var style: ModernButtonStyle? = nil
    var accessibilityTitle: String = ""
    @ViewBuilder let label: () -> Label

    @ViewState private var anchorView: NSView?

    var body: some View {
        Group {
            if let style {
                Button(action: showMenu, label: label)
                    .buttonStyle(style)
            } else {
                Button(action: showMenu, label: label)
                    .buttonStyle(.plain)
            }
        }
        .background(AnchorViewReader { anchorView = $0 })
        .accessibilityLabel(accessibilityTitle)
    }

    private func showMenu() {
        guard let view = anchorView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items {
            if entry.role == .separator {
                menu.addItem(.separator())
                continue
            }
            let target = MenuTarget(entry.action)
            let item = NSMenuItem(title: entry.title, action: #selector(MenuTarget.invoke), keyEquivalent: "")
            item.target = target
            item.isEnabled = entry.isEnabled
            item.representedObject = target
            if entry.role == .destructive && entry.isEnabled {
                item.attributedTitle = NSAttributedString(
                    string: entry.title,
                    attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)]
                )
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }
}

// MARK: - 颜色辅助扩展
extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
