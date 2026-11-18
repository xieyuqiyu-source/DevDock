import SwiftUI
import AppKit

/// IDE 级终端日志查看器 - 支持来源切换、级别徽章过滤、书签定位与实时跟随
struct EnhancedLogViewer: View {
    @ObservedObject var store: ProjectStore
    let project: Project
    var onClose: (() -> Void)? = nil

    @ViewState private var selectedSource: String = ""
    @ViewState private var searchText = ""
    @ViewState private var filterLevel: LogLevel = .all
    @ViewState private var bookmarksOnly = false
    @ViewState private var autoScroll = true
    @ViewState private var bookmarks: Set<Int> = []
    @ViewState private var logContent = ""
    @ViewState private var copiedFeedback = false

    enum LogLevel: String, CaseIterable {
        case all = "全部"
        case error = "错误"
        case warning = "警告"
        case info = "信息"
        case debug = "调试"
    }

    private var sources: [(name: String, url: URL)] {
        store.logSources(project)
    }

    private var currentURL: URL? {
        selectedSource.isEmpty ? sources.first?.url : sources.first { $0.url.path == selectedSource }?.url
    }

    private var currentSourceLabel: String {
        if selectedSource.isEmpty {
            if let first = sources.first {
                let unitTitle = first.name.components(separatedBy: " · ").first ?? first.name
                return "实时 · \(unitTitle)"
            }
            return "最新日志"
        }
        return sources.first { $0.url.path == selectedSource }?.name ?? "最新日志"
    }

    private var logSourceMenuItems: [MenuAction] {
        var list: [MenuAction] = [
            MenuAction(title: "最新日志（实时）") { selectedSource = "" }
        ]
        if !sources.isEmpty {
            list.append(.separator)
            for source in sources {
                list.append(MenuAction(title: source.name) { selectedSource = source.url.path })
            }
        }
        return list
    }

    private var parsedLines: [(lineNumber: Int, content: String, level: LogLevel)] {
        guard !logContent.isEmpty else { return [] }
        let rawLines = logContent.split(separator: "\n", omittingEmptySubsequences: false)
        // 若末尾只是一个换行符，去掉最后一个空行避免多余行号
        let trimmed = rawLines.last?.isEmpty == true ? Array(rawLines.dropLast()) : Array(rawLines)
        return trimmed.enumerated().map { idx, sub in
            let str = String(sub)
            return (idx + 1, str, detectLogLevel(str))
        }
    }

    private var errorCount: Int {
        parsedLines.reduce(0) { $0 + ($1.level == .error ? 1 : 0) }
    }

    private var warningCount: Int {
        parsedLines.reduce(0) { $0 + ($1.level == .warning ? 1 : 0) }
    }

    private var filteredLines: [(lineNumber: Int, content: String, level: LogLevel)] {
        parsedLines.filter { item in
            if bookmarksOnly && !bookmarks.contains(item.lineNumber) { return false }
            if filterLevel != .all && item.level != filterLevel { return false }
            if !searchText.isEmpty && !item.content.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(ModernTheme.border)
            terminalBody
            Divider().overlay(ModernTheme.border)
            footerBar
        }
        .background(ModernTheme.terminalBg)
        .onChange(of: selectedSource) { _ in
            logContent = ""
            bookmarks.removeAll()
            bookmarksOnly = false
        }
        .onChange(of: sources.map { $0.url.path }) { paths in
            if !selectedSource.isEmpty, !paths.contains(selectedSource) {
                selectedSource = ""
            }
        }
        .task(id: currentURL?.path) {
            logContent = ""
            bookmarks.removeAll()
            guard let url = currentURL else { return }
            while !Task.isCancelled {
                let content = await Task.detached(priority: .utility) { tailText(url) }.value
                guard !Task.isCancelled, currentURL?.path == url.path else { return }
                if content != logContent { logContent = content }
                do {
                    try await Task.sleep(nanoseconds: UInt64(AppConfiguration.logTailInterval * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            // 来源选择器（原生 NSMenu + 纯净自定义胶囊按钮）
            NativeMenuButton(
                items: logSourceMenuItems,
                style: ModernButtonStyle(variant: .secondary, size: .xs),
                accessibilityTitle: "选择日志来源"
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ModernTheme.primary)
                    Text(currentSourceLabel)
                        .lineLimit(1)
                        .frame(maxWidth: 125, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(ModernTheme.textTertiary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            // 级别过滤胶囊组
            HStack(spacing: 3) {
                levelChip(.all, count: nil, tint: ModernTheme.primary)
                levelChip(.error, count: errorCount, tint: ModernTheme.danger)
                levelChip(.warning, count: warningCount, tint: ModernTheme.warning)
                levelChip(.info, count: nil, tint: ModernTheme.primary)
            }
            .padding(2)
            .background(ModernTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(ModernTheme.border, lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)

            // 书签筛选按钮
            if !bookmarks.isEmpty {
                Button {
                    bookmarksOnly.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10))
                        Text("\(bookmarks.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(bookmarksOnly ? .white : ModernTheme.warning)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(bookmarksOnly ? ModernTheme.warning : ModernTheme.warningBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("仅显示已标记书签行")
            }

            Spacer(minLength: 4)

            // 搜索过滤框
            ModernSearchBar(text: $searchText, placeholder: "过滤日志…", compact: true)
                .frame(minWidth: 105, maxWidth: 185)

            // 操作按钮组
            HStack(spacing: 2) {
                IconActionButton(
                    icon: "arrow.down.to.line",
                    isActive: autoScroll,
                    size: 26,
                    helpText: autoScroll ? "已开启自动滚动跟随" : "点击恢复自动跟随最新日志"
                ) {
                    autoScroll.toggle()
                }

                IconActionButton(
                    icon: copiedFeedback ? "checkmark" : "doc.on.doc",
                    isActive: copiedFeedback,
                    size: 26,
                    helpText: "复制当前过滤后的日志"
                ) {
                    copyVisibleLogs()
                }
                .disabled(filteredLines.isEmpty)

                IconActionButton(
                    icon: "square.and.arrow.up",
                    size: 26,
                    helpText: "导出原始日志文件"
                ) {
                    exportLog()
                }
                .disabled(currentURL == nil)

                if let onClose {
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 3)
                    IconActionButton(
                        icon: "chevron.down",
                        size: 26,
                        helpText: "收起终端日志面板"
                    ) {
                        onClose()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(ModernTheme.terminalHeader)
    }

    private func levelChip(_ level: LogLevel, count: Int?, tint: Color) -> some View {
        let selected = filterLevel == level
        return Button {
            filterLevel = level
        } label: {
            HStack(spacing: 4) {
                Text(level.rawValue)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? tint : tint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(tint.opacity(selected ? 0.16 : 0.12), in: Capsule())
                }
            }
            .foregroundStyle(selected ? ModernTheme.textPrimary : ModernTheme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(selected ? ModernTheme.surfaceSubtle : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var terminalBody: some View {
        if logContent.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: currentURL == nil ? "doc.text.magnifyingglass" : "waveform.path.ecg")
                    .font(.system(size: 22))
                    .foregroundStyle(ModernTheme.textTertiary)
                Text(currentURL == nil ? "暂无日志文件" : "等待进程标准输出…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(ModernTheme.textSecondary)
                Text(currentURL == nil ? "启动项目后将在此实时流式展示 stdout / stderr" : "输出产生后将每 0.75 秒自动追加")
                    .font(.system(size: 11))
                    .foregroundStyle(ModernTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ModernTheme.terminalBg)
        } else if filteredLines.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(ModernTheme.textTertiary)
                Text("当前筛选条件下没有匹配的日志行")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(ModernTheme.textSecondary)
                Button("重置筛选条件") {
                    filterLevel = .all
                    searchText = ""
                    bookmarksOnly = false
                }
                .buttonStyle(ModernButtonStyle(variant: .secondary, size: .xs))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ModernTheme.terminalBg)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredLines, id: \.lineNumber) { line in
                            LogLineView(
                                lineNumber: line.lineNumber,
                                content: line.content,
                                level: line.level,
                                isBookmarked: bookmarks.contains(line.lineNumber),
                                onToggleBookmark: {
                                    if bookmarks.contains(line.lineNumber) {
                                        bookmarks.remove(line.lineNumber)
                                        if bookmarks.isEmpty { bookmarksOnly = false }
                                    } else {
                                        bookmarks.insert(line.lineNumber)
                                    }
                                }
                            )
                            .id(line.lineNumber)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(ModernTheme.terminalBg)
                .onChange(of: logContent) { _ in
                    if autoScroll, let lastLine = filteredLines.last {
                        proxy.scrollTo(lastLine.lineNumber, anchor: .bottom)
                    }
                }
                .onAppear {
                    if autoScroll, let lastLine = filteredLines.last {
                        proxy.scrollTo(lastLine.lineNumber, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle()
                    .fill(autoScroll ? ModernTheme.success : ModernTheme.textTertiary)
                    .frame(width: 5, height: 5)
                Text(autoScroll ? "实时跟随" : "滚动已锁定")
            }

            Text("显示 \(filteredLines.count) / \(parsedLines.count) 行")
                .monospacedDigit()

            if !bookmarks.isEmpty {
                Button("清空 \(bookmarks.count) 个书签") {
                    bookmarks.removeAll()
                    bookmarksOnly = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(ModernTheme.warning)
            }

            Spacer()

            Text("缓冲上限 512 KB")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(ModernTheme.textTertiary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(ModernTheme.terminalHeader)
    }

    private func detectLogLevel(_ line: String) -> LogLevel {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("错误") || lower.contains("fatal") || lower.contains("panic") || lower.contains("失败") {
            return .error
        } else if lower.contains("warn") || lower.contains("警告") {
            return .warning
        } else if lower.contains("debug") || lower.contains("调试") {
            return .debug
        }
        return .info
    }

    private func copyVisibleLogs() {
        let joined = filteredLines.map(\.content).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
        copiedFeedback = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copiedFeedback = false
        }
    }

    private func exportLog() {
        guard let url = currentURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = project.name + "-log.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: .atomic)
        } catch {
            store.error = "导出失败: \(error.localizedDescription)"
        }
    }
}

struct LogLineView: View {
    let lineNumber: Int
    let content: String
    let level: EnhancedLogViewer.LogLevel
    let isBookmarked: Bool
    let onToggleBookmark: () -> Void
    @ViewState private var hovering = false

    private var textColor: Color {
        switch level {
        case .error: return ModernTheme.danger
        case .warning: return ModernTheme.warning
        case .info: return ModernTheme.textPrimary.opacity(0.88)
        case .debug: return ModernTheme.textTertiary
        case .all: return ModernTheme.textPrimary
        }
    }

    private var rowBackground: Color {
        if isBookmarked { return ModernTheme.warning.opacity(0.09) }
        if level == .error { return ModernTheme.danger.opacity(0.06) }
        if hovering { return ModernTheme.surfaceHover.opacity(0.5) }
        return Color.clear
    }

    private var indicatorColor: Color {
        if isBookmarked { return ModernTheme.warning }
        if level == .error { return ModernTheme.danger }
        if level == .warning { return ModernTheme.warning.opacity(0.7) }
        return Color.clear
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // 左侧状态竖条 + 行号与书签栏
            HStack(spacing: 4) {
                Rectangle()
                    .fill(indicatorColor)
                    .frame(width: 2.5)

                Button(action: onToggleBookmark) {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 9.5))
                        .foregroundStyle(isBookmarked ? ModernTheme.warning : ModernTheme.textTertiary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .opacity(isBookmarked || hovering ? 1 : 0)
                .help(isBookmarked ? "移除书签" : "标记书签")
                .accessibilityLabel(isBookmarked ? "移除书签" : "添加书签")

                Text(verbatim: "\(lineNumber)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(ModernTheme.textTertiary)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.trailing, 8)

            // 日志正文
            Text(content.isEmpty ? " " : content)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 2)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
