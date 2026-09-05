import AppKit
import Combine

@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var endpointStates: [String: EndpointState] = [:]
    @Published var discoveredEndpoints: [UUID: [Endpoint]] = [:]
    @Published var phases: [UUID: String] = [:]
    @Published var notices: [UUID: String] = [:]
    @Published var busy: Set<UUID> = []
    @Published var error: String?
    @Published var revision = 0
    @Published var scanning = false

    let support: URL
    var configURL: URL { support.appendingPathComponent("projects.json") }
    var logsURL: URL { support.appendingPathComponent("Logs", isDirectory: true) }
    private var commands: [UUID: RunningCommand] = [:]
    private var ownedDetached: [UUID: Int32] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var operationTokens: [UUID: UUID] = [:]
    private var monitor: Task<Void, Never>?
    private var environment: [String: String]?
    private var persistenceBlocked = false
    private var shuttingDown = false
    private var ownershipVersion = 0
    private var refreshTicket = 0
    let helperURL: URL

    init(support: URL? = nil, helperURL: URL? = nil, seed: Bool = true, monitor: Bool = true) {
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DevDock", isDirectory: true)
        self.helperURL = helperURL ?? Bundle.main.executableURL!
        do {
            try FileManager.default.createDirectory(at: self.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: configURL.path) {
                projects = try JSONDecoder().decode([Project].self, from: Data(contentsOf: configURL))
                try validateIDs(projects)
            } else if seed {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                projects = ["/Documents/Game/wlsg-v2/君陌助手", "/Documents/Work/football", "/Documents/Work/hospital-assistant-go"]
                    .compactMap { Discovery.project(at: URL(fileURLWithPath: home + $0)) }
                try save()
            }
        } catch {
            self.error = "无法读取项目配置，原文件已保留：\(error.localizedDescription)"
            persistenceBlocked = true
        }
        if monitor {
            startMonitor()
        }
    }

    deinit { monitor?.cancel() }

    private func startMonitor() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func resumeAfterCancelledQuit() {
        shuttingDown = false
        startMonitor()
    }

    private func validateIDs(_ projects: [Project]) throws {
        let ids = projects.map(\.id)
        let units = projects.flatMap(\.units).map(\.id)
        let endpoints = projects.flatMap(\.units).flatMap(\.endpoints).map(\.id)
        guard Set(ids).count == ids.count, Set(units).count == units.count, Set(endpoints).count == endpoints.count else {
            throw AppError.message("配置中有重复的项目或启动项 ID。")
        }
    }

    func save() throws {
        guard !persistenceBlocked else { throw AppError.message("配置文件读取失败，请先修复或移走 projects.json 后重新打开应用。") }
        try validateIDs(projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(projects).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    func update(_ project: Project) throws {
        try project.validate()
        guard !isActive(project), !busy.contains(project.id) else { throw AppError.message("请先停止项目，再修改启动配置。") }
        let previous = projects
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.append(project) }
        do { try save() } catch { projects = previous; throw error }
    }

    func remove(_ project: Project) {
        guard !isActive(project), !busy.contains(project.id) else { error = "请先停止项目，再移除。"; return }
        let previous = projects
        projects.removeAll { $0.id == project.id }
        do { try save() } catch { projects = previous; self.error = error.localizedDescription }
    }

    func importFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择项目或项目总目录"
        panel.prompt = "扫描项目"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        scanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { urls.flatMap { Discovery.scan($0) } }.value
            let previous = projects
            for project in found where !projects.contains(where: { $0.path == project.path }) { projects.append(project) }
            do { try save() } catch { projects = previous; self.error = error.localizedDescription }
            scanning = false
            if found.isEmpty { error = "未发现 dev、dev.sh、go-start 等入口或 package.json 的 dev 命令。可用“手动添加”配置项目。" }
        }
    }

    func isActive(_ project: Project) -> Bool { project.units.contains { isActive($0) } }
    func isActive(_ unit: LaunchUnit) -> Bool {
        if ownedDetached[unit.id] != nil { return true }
        if let command = commands[unit.id] { return !command.exited || kill(-command.pid, 0) == 0 }
        return false
    }

    func status(_ project: Project) -> String {
        if busy.contains(project.id) { return phases[project.id] ?? "处理中" }
        if isActive(project) {
            if notices[project.id] != nil { return "需要关注" }
            let endpoints = project.endpoints
            if endpoints.isEmpty { return "运行中" }
            return endpoints.allSatisfy { endpointStates[$0.id] == .ready } ? "已就绪" : "部分服务未就绪"
        }
        if notices[project.id] != nil { return "启动失败" }
        if project.endpoints.contains(where: { if case .occupied = endpointStates[$0.id] { return true }; return false }) { return "端口被占用" }
        return "已停止"
    }

    var activeCount: Int { projects.filter { isActive($0) }.count }

    func launch(_ project: Project, only: UUID? = nil) {
        guard !shuttingDown, !busy.contains(project.id) else { return }
        busy.insert(project.id)
        notices[project.id] = nil
        phases[project.id] = "正在启动"
        let token = UUID()
        operationTokens[project.id] = token
        operations[project.id] = Task {
            do { try await start(project, only: only) }
            catch is CancellationError { }
            catch { notices[project.id] = error.localizedDescription }
            if operationTokens[project.id] == token {
                busy.remove(project.id)
                phases[project.id] = nil
                operations[project.id] = nil
            }
            revision += 1
        }
    }

    private func start(_ project: Project, only: UUID?) async throws {
        try project.validate()
        if environment == nil { environment = await System.shellEnvironment() }
        for unit in project.enabledUnits where only == nil || unit.id == only {
            try Task.checkCancellation()
            guard !isActive(unit) else { continue }
            phases[project.id] = "正在启动 · \(unit.name)"
            if unit.detached, System.ownedPID(project: project, unit: unit) != nil {
                throw AppError.message("\(unit.name) 已在外部运行。请先用项目原有方式停止，再由 DevDock 启动。")
            }
            for endpoint in unit.endpoints {
                if let port = endpoint.port, let pid = await System.listeningPID(port: port) {
                    throw AppError.message("\(endpoint.name) 的端口 \(port) 已被 PID \(pid) 占用。现有进程未被修改，请先停止它或修改端口配置。")
                }
            }
            try Task.checkCancellation()
            let command = try RunningCommand(command: unit.command, directory: project.resolved(unit.directory),
                                             environment: environment ?? [:], logURL: newLogURL(project, unit), helperURL: helperURL)
            commands[unit.id] = command
            ownershipVersion += 1
            discoveredEndpoints[unit.id] = nil
            for endpoint in unit.endpoints { endpointStates[endpoint.id] = .stopped }
            revision += 1
            if unit.detached {
                for _ in 0..<1200 {
                    // Register a daemon even if the user clicked Stop while its build was running.
                    if let pid = System.ownedPID(project: project, unit: unit) { registerDaemon(pid, for: unit.id) }
                    try Task.checkCancellation()
                    if command.exited { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if !command.exited { throw AppError.message("\(unit.name) 的后台启动命令超过 120 秒，可停止后查看日志。") }
                guard command.exitCode == 0 else { throw AppError.message("\(unit.name) 启动命令退出（\(command.exitCode ?? -1)），请查看启动日志。") }
                // The launcher can exit before nohup has exec'd the configured daemon.
                // Keep checking executable ownership; never accept the PID file alone.
                for _ in 0..<30 {
                    if let pid = System.ownedPID(project: project, unit: unit) {
                        registerDaemon(pid, for: unit.id)
                        break
                    }
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let pid = System.ownedPID(project: project, unit: unit) else {
                    throw AppError.message("\(unit.name) 未找到匹配的后台进程，请检查 PID 文件和可执行文件配置。")
                }
                registerDaemon(pid, for: unit.id)
            }
            if !unit.endpoints.isEmpty {
                phases[project.id] = "等待服务就绪 · \(unit.name)"
                var ready = false
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline {
                    try Task.checkCancellation()
                    await refresh()
                    if unit.endpoints.allSatisfy({ endpointStates[$0.id] == .ready }) { ready = true; break }
                    if !unit.detached, command.exited {
                        throw AppError.message("\(unit.name) 的启动脚本已退出（\(command.exitCode ?? -1)），请查看日志。")
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if !ready { throw AppError.message("\(unit.name) 尚未通过服务检查，已启动的进程保留供排查。检查日志或点击停止。") }
            } else if !unit.detached {
                try await Task.sleep(nanoseconds: 300_000_000)
                if command.exited { throw AppError.message("启动脚本已退出（\(command.exitCode ?? -1)）。若脚本会自行后台运行，请在配置中启用后台模式并填写 PID、停止命令。") }
            }
        }
    }

    func stop(_ project: Project, only: UUID? = nil, restart: Bool = false) {
        guard !(busy.contains(project.id) && phases[project.id] == "正在停止") else { return }
        let previous = operations[project.id]
        previous?.cancel()
        busy.insert(project.id)
        phases[project.id] = "正在停止"
        let token = UUID()
        operationTokens[project.id] = token
        let operation = Task {
            await previous?.value
            busy.insert(project.id)
            phases[project.id] = "正在停止"
            await stopUnits(project, only: only)
            if operationTokens[project.id] == token {
                busy.remove(project.id)
                phases[project.id] = nil
                operations[project.id] = nil
            }
            revision += 1
            if restart && notices[project.id] == nil { launch(project, only: only) }
        }
        operations[project.id] = operation
    }

    private func stopUnits(_ project: Project, only: UUID?) async {
        ownershipVersion += 1
        notices[project.id] = nil
        for unit in project.units.reversed() where only == nil || unit.id == only {
            if unit.detached {
                // Stop the launcher first, so it cannot create a daemon after cleanup.
                if let command = commands[unit.id] { await command.stop() }
                if let pid = ownedDetached[unit.id] ?? (commands[unit.id] != nil ? System.ownedPID(project: project, unit: unit) : nil) {
                    if System.ownedPID(project: project, unit: unit) == pid {
                        do {
                            let command = try RunningCommand(command: unit.stopCommand, directory: project.resolved(unit.directory), environment: environment ?? ProcessInfo.processInfo.environment,
                                logURL: newLogURL(project, unit, suffix: "stop"), helperURL: helperURL)
                            for _ in 0..<150 {
                                if command.exited { break }
                                try? await Task.sleep(nanoseconds: 100_000_000)
                            }
                            if !command.exited { await command.stop() }
                            if System.ownedPID(project: project, unit: unit) == pid {
                                notices[project.id] = "\(unit.name) 未能停止，请查看日志或使用项目停止命令。"
                                continue
                            }
                        } catch { notices[project.id] = error.localizedDescription; continue }
                    }
                    ownedDetached[unit.id] = nil
                }
            } else if let command = commands[unit.id] { await command.stop() }
            commands[unit.id] = nil
            discoveredEndpoints[unit.id] = nil
            ownershipVersion += 1
        }
        await refresh()
    }

    func shutdown() async {
        shuttingDown = true
        monitor?.cancel()
        let pending = Array(operations.values)
        for operation in pending { operation.cancel() }
        for operation in pending { await operation.value }
        for project in projects where isActive(project) { await stopUnits(project, only: nil) }
    }

    func displayedEndpoints(_ unit: LaunchUnit) -> [Endpoint] {
        unit.endpoints + (discoveredEndpoints[unit.id] ?? [])
    }

    private func registerDaemon(_ pid: Int32, for unit: UUID) {
        if ownedDetached[unit] != pid { ownedDetached[unit] = pid; ownershipVersion += 1 }
    }

    private func ownedPIDs(_ project: Project, _ unit: LaunchUnit, in snapshot: ProcessSnapshot) -> Set<Int32> {
        let group = commands[unit.id].map(\.pid)
        let daemon = ownedDetached[unit.id].flatMap { System.ownedPID(project: project, unit: unit) == $0 ? $0 : nil }
        return snapshot.ownedPIDs(group: group, daemon: daemon)
    }

    func refresh() async {
        refreshTicket += 1
        let ticket = refreshTicket
        let version = ownershipVersion
        let scannedProjects = projects
        guard let before = await System.processSnapshot() else {
            if ticket == refreshTicket { endpointStates = [:]; discoveredEndpoints = [:] }
            return
        }
        var probes: [Endpoint] = []
        for project in scannedProjects {
            for unit in project.enabledUnits {
                let owned = ownedPIDs(project, unit, in: before)
                probes += unit.endpoints.filter { before.state(for: $0, owned: owned) == .listening }
            }
        }
        let responses = await withTaskGroup(of: (String, Bool).self) { group in
            for endpoint in probes { group.addTask { (endpoint.id, await System.healthy(endpoint)) } }
            var values: [String: Bool] = [:]
            for await (id, value) in group { values[id] = value }
            return values
        }
        // Recheck ownership after HTTP: another process may have taken over the port meanwhile.
        let finalSnapshot = await System.processSnapshot()
        guard ticket == refreshTicket, version == ownershipVersion, scannedProjects == projects else { return }
        guard let after = finalSnapshot else { endpointStates = [:]; discoveredEndpoints = [:]; return }
        var states: [String: EndpointState] = [:]
        var discovered: [UUID: [Endpoint]] = [:]
        for project in scannedProjects {
            for unit in project.enabledUnits {
                let owned = ownedPIDs(project, unit, in: after)
                for endpoint in unit.endpoints {
                    let state = after.state(for: endpoint, owned: owned)
                    states[endpoint.id] = state == .listening ? (responses[endpoint.id] == true ? .ready : .unready) : state
                }
                var addresses = Set<String>()
                for listener in after.listeners where owned.contains(listener.pid) {
                    guard let url = listener.localURL, !addresses.contains(url),
                          !unit.endpoints.contains(where: { listener.matches($0.url) }) else { continue }
                    addresses.insert(url)
                    let endpoint = Endpoint(id: "runtime-\(unit.id)-\(url)", name: listener.name + " · 自动发现", url: url, healthURL: url)
                    discovered[unit.id, default: []].append(endpoint)
                    // Discovery proves a TCP listener, not that an unknown service is HTTP-ready.
                    states[endpoint.id] = after.state(for: endpoint, owned: owned)
                }
            }
        }
        if states != endpointStates { endpointStates = states }
        if discovered != discoveredEndpoints { discoveredEndpoints = discovered }
        for project in projects where !busy.contains(project.id) {
            for unit in project.units {
                if let pid = ownedDetached[unit.id], System.ownedPID(project: project, unit: unit) != pid {
                    ownedDetached[unit.id] = nil
                    ownershipVersion += 1
                    notices[project.id] = "\(unit.name) 的后台进程已退出，请查看日志。"
                }
                if let command = commands[unit.id], !unit.detached, command.exited, notices[project.id] == nil {
                    notices[project.id] = "\(unit.name) 的脚本已退出（\(command.exitCode ?? -1)），请查看日志。"
                }
                if let message = commands[unit.id]?.sink.failure { notices[project.id] = "日志写入失败：\(message)" }
            }
        }
        revision += 1
    }

    private func newLogURL(_ project: Project, _ unit: LaunchUnit, suffix: String = "start") -> URL {
        let folder = logsURL.appendingPathComponent(project.id.uuidString).appendingPathComponent(unit.id.uuidString)
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let batches = files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in batches.dropFirst(19) {
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.removeItem(at: old.appendingPathExtension("previous"))
            }
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent("\(stamp)-\(suffix)-\(UUID().uuidString.prefix(4)).log")
    }

    func logSources(_ project: Project) -> [(name: String, url: URL)] {
        var sources: [(String, URL)] = []
        for unit in project.units {
            if !unit.logFile.isEmpty { sources.append((unit.name + " · 服务日志", URL(fileURLWithPath: project.resolved(unit.logFile)))) }
            let folder = logsURL.appendingPathComponent(project.id.uuidString).appendingPathComponent(unit.id.uuidString)
            if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for file in files.sorted(by: {
                    if ($0.pathExtension == "previous") != ($1.pathExtension == "previous") { return $0.pathExtension != "previous" }
                    return $0.lastPathComponent > $1.lastPathComponent
                }) {
                    sources.append((unit.name + " · " + file.lastPathComponent, file))
                }
            }
        }
        return sources
    }

    func startedAt(_ project: Project) -> Date? { project.units.compactMap { commands[$0.id]?.started }.min() }
    func processID(_ unit: LaunchUnit) -> Int32? { ownedDetached[unit.id] ?? commands[unit.id].flatMap { $0.exited ? nil : $0.pid } }
}
