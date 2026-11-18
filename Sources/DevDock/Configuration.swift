import Foundation

/// 应用配置参数集中管理
enum AppConfiguration {
    // 进程监控
    static let processRefreshInterval: TimeInterval = 3.0
    static let processSnapshotTimeout: TimeInterval = 5.0

    // 服务启动
    static let serviceReadyTimeout: TimeInterval = 120.0
    static let daemonLaunchCheckRetries = 30
    static let serviceCheckRetries = 1200

    // 日志
    static let logTailInterval: TimeInterval = 0.75
    static let logMaxFileSize: UInt64 = 5 * 1024 * 1024
    static let logTailBytes: UInt64 = 512 * 1024
    static let logRetentionCount = 20

    // UI 尺寸与阈值
    static let menuPanelWidth: CGFloat = 368
    static let sidebarWidth: CGFloat = 236
    static let headerHeight: CGFloat = 46
    static let defaultLogDrawerHeight: CGFloat = 268
    static let minLogDrawerHeight: CGFloat = 170
    static let maxLogDrawerHeight: CGFloat = 480
    static let compactSearchThreshold = 4
    static let maxVisibleMenuItems = 7

    // 性能
    static let captureBufferMaxSize = 2 * 1024 * 1024
}
