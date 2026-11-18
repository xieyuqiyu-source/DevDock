import Foundation

struct Endpoint: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var url: String
    var healthURL: String
    var role: ServiceRole? = nil
}

enum ServiceRole: String, Codable, CaseIterable {
    case frontend, backend, unclassified

    var label: String {
        switch self {
        case .frontend: return "前端"
        case .backend: return "后端"
        case .unclassified: return "未分类"
        }
    }

    static func fromName(_ name: String) -> Self? {
        let words = name.lowercased().split { !$0.isASCII || !$0.isLetter }
        let frontend = words.contains { ["frontend", "web", "ui"].contains($0) }
            || ["前端", "网页", "控制台", "管理后台"].contains { name.contains($0) }
            || name.lowercased() == "admin"
        let backend = words.contains { ["backend", "api"].contains($0) }
            || ["后端", "接口"].contains { name.contains($0) }
        if frontend && backend { return .unclassified }
        if frontend { return .frontend }
        if backend { return .backend }
        return nil
    }
}

struct EndpointActivity: Equatable {
    let pids: [Int32]
    let inferredRole: ServiceRole?
}

struct ServiceGroup: Identifiable {
    let id: String
    let endpoints: [Endpoint]
    let pids: [Int32]
    let role: ServiceRole

    static func group(configured: [Endpoint], discovered: [Endpoint], activity: [String: EndpointActivity]) -> [Self] {
        enum Key: Hashable { case listening([Int32]), configured(String) }
        func key(_ endpoint: Endpoint) -> Key {
            if let current = activity[endpoint.id], !current.pids.isEmpty { return .listening(current.pids) }
            return .configured(endpoint.id)
        }
        let endpoints = configured + discovered
        let configuredIDs = Set(configured.map(\.id))
        let grouped = Dictionary(grouping: endpoints, by: key)
        var seen = Set<Key>()
        return endpoints.compactMap { endpoint in
            let identity = key(endpoint)
            guard seen.insert(identity).inserted, let addresses = grouped[identity] else { return nil }
            let named = Set(addresses.compactMap { configuredIDs.contains($0.id) ? ($0.role ?? ServiceRole.fromName($0.name)) : nil })
            let roles = named.isEmpty ? Set(addresses.compactMap { activity[$0.id]?.inferredRole }) : named
            return Self(id: endpoint.id, endpoints: addresses, pids: activity[endpoint.id]?.pids ?? [],
                        role: roles.count == 1 ? roles.first ?? .unclassified : .unclassified)
        }
    }
}

enum EndpointState: Equatable {
    case stopped, listening, ready, unready, occupied(Int32)

    var isOwned: Bool {
        switch self {
        case .listening, .ready, .unready: return true
        case .stopped, .occupied: return false
        }
    }
    var label: String {
        switch self {
        case .stopped: return "未监听"
        case .listening: return "监听中"
        case .ready: return "已就绪"
        case .unready: return "未就绪"
        case .occupied: return "其他进程占用"
        }
    }
}

struct LaunchUnit: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var directory: String = "."
    var command: String
    var stopCommand: String = ""
    var logFile: String = ""
    var pidFile: String = ""
    var executable: String = ""
    var detached = false
    var enabled = true
    var endpoints: [Endpoint] = []
}

struct Project: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var units: [LaunchUnit]
    var note = ""

    var enabledUnits: [LaunchUnit] { units.filter(\.enabled) }
    var endpoints: [Endpoint] { enabledUnits.flatMap(\.endpoints) }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.hasPrefix("/"), FileManager.default.fileExists(atPath: path),
              !units.isEmpty, !enabledUnits.isEmpty else {
            throw AppError.message("请填写项目名称、有效的绝对目录，并至少启用一个启动项。")
        }
        for unit in units {
            guard !unit.name.isEmpty, !unit.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.message("每个启动项都需要名称和启动命令。")
            }
            let working = resolved(unit.directory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: working, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AppError.message("工作目录不存在：\(working)")
            }
            if unit.detached && (unit.stopCommand.isEmpty || unit.pidFile.isEmpty || unit.executable.isEmpty) {
                throw AppError.message("后台启动项需要停止命令、PID 文件和进程可执行文件路径。")
            }
            for endpoint in unit.endpoints {
                for value in [endpoint.url, endpoint.healthURL] {
                    guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""),
                          ["localhost", "127.0.0.1", "::1"].contains((url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else {
                        throw AppError.message("服务地址必须是本机 HTTP(S) 地址：\(value)")
                    }
                }
            }
        }
    }

    func resolved(_ relative: String) -> String {
        if relative.hasPrefix("/") { return URL(fileURLWithPath: relative).standardized.path }
        return URL(fileURLWithPath: path).appendingPathComponent(relative).standardized.path
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

struct Discovery {
    static let excluded: Set<String> = ["node_modules", "vendor", "dist", "build", ".git", ".build", ".run", "tmp", "Library"]

    static func text(_ root: String, _ relative: String) -> String {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000 else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func autoGameEntry(in directory: String, unit: LaunchUnit) -> String? {
        guard !unit.detached, unit.command.trimmingCharacters(in: .whitespacesAndNewlines) == "./dev",
              text(directory, "dev").contains("scripts/serve.sh"),
              text(directory, "scripts/serve.sh").contains("exec .venv/bin/python scripts/dev.py") else { return nil }
        let entry = "scripts/dev.py"
        let source = text(directory, entry)
        return source.contains("AUTO_GAME_DATA") && source.contains("--supervise") && source.contains("server-feed/main.py") ? entry : nil
    }

    static func project(at directory: URL) -> Project? {
        return TemplateManager.shared.detect(at: directory.standardizedFileURL)
    }

    static func hasDev(_ root: String, _ subdirectory: String = ".") -> Bool {
        guard let data = text(root, subdirectory + "/package.json").data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any],
              let command = scripts["dev"] as? String else { return false }
        return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ponytail: bounded three-level discovery; add configurable depth only for deeper workspaces.
    static func scan(_ root: URL, depth: Int = 3) -> [Project] {
        var found: [Project] = []
        if let project = project(at: root) { return [project] }
        guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return found }
        for child in children.sorted(by: { $0.path < $1.path }) where !excluded.contains(child.lastPathComponent) {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            found += scan(child, depth: depth - 1)
        }
        return found
    }
}
