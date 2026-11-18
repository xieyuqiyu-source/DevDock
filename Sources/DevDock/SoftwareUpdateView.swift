import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SoftwareUpdateView: View {
    private enum Phase: Equatable {
        case checking, current, available(SoftwareUpdate), downloading(SoftwareUpdate, URL), saved(URL), failed(String)
    }

    @ViewState private var phase: Phase = .checking
    @Environment(\.dismiss) private var dismiss
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DevDock 软件更新").font(.headline)
            if let currentVersion { Text("当前版本 \(currentVersion)").foregroundStyle(.secondary) }
            switch phase {
            case .checking:
                ProgressView("正在检查更新…")
            case .current:
                Text("你使用的已是最新版本。")
            case .available(let update):
                Text("发现新版本 \(update.tag)")
                Button("下载新版…") { chooseDestination(for: update) }.keyboardShortcut(.defaultAction)
            case .downloading(let update, _):
                ProgressView("正在下载并校验 \(update.tag)…")
            case .saved(let url):
                Text("下载完成。准备好停止托管服务时，退出 DevDock，解压并替换旧版应用。")
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case .failed(let message):
                Text(message).textSelection(.enabled)
                Button("重试") { phase = .checking }
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .task(id: phase) {
            do {
                switch phase {
                case .checking:
                    guard let currentVersion else { throw AppError.message("请从 DevDock.app 检查更新。") }
                    let update = try await SoftwareUpdate.latest(current: currentVersion)
                    try Task.checkCancellation()
                    phase = update.map(Phase.available) ?? .current
                case .downloading(let update, let url):
                    try await update.download(to: url)
                    try Task.checkCancellation()
                    phase = .saved(url)
                default: break
                }
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func chooseDestination(for update: SoftwareUpdate) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "DevDock-\(update.tag)-macOS.zip"
        if panel.runModal() == .OK, let url = panel.url { phase = .downloading(update, url) }
    }
}
