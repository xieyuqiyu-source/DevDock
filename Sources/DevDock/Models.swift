import Foundation

struct Endpoint: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var url: String
    var healthURL: String
    var port: Int? { URL(string: url).map { $0.port ?? ($0.scheme == "https" ? 443 : 80) } }
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

    static func project(at directory: URL) -> Project? {
        let path = directory.standardizedFileURL.path
        let dev = text(path, "dev")
        let football = text(path, "dev.sh")
        let hospital = text(path, "go-start")
        if dev.contains("JUNMO_DEV_SKIP_INSTALL"), dev.contains("18110") {
            return Project(name: directory.lastPathComponent, path: path, units: [
                LaunchUnit(name: "前后端", command: "./dev", endpoints: [
                    Endpoint(name: "Go API", url: "http://127.0.0.1:18110", healthURL: "http://127.0.0.1:18110/health"),
                    Endpoint(name: "控制台", url: "http://127.0.0.1:15175", healthURL: "http://127.0.0.1:15175")
                ])
            ], note: "沿用 ./dev 的热更新和启动顺序；前后端日志为脚本的合并输出。")
        }
        if football.contains("com.football.local-agent"), football.contains("9802") {
            return Project(name: directory.lastPathComponent, path: path, units: [
                LaunchUnit(name: "API · Web · Admin", command: "./dev.sh", endpoints: [
                    Endpoint(name: "Go API", url: "http://127.0.0.1:9800", healthURL: "http://127.0.0.1:9800/api/v1/home/summary"),
                    Endpoint(name: "Web", url: "http://127.0.0.1:9801", healthURL: "http://127.0.0.1:9801"),
                    Endpoint(name: "Admin", url: "http://127.0.0.1:9802", healthURL: "http://127.0.0.1:9802")
                ])
            ], note: "保留原脚本的启动顺序；三个端为合并日志。已运行的外部后端不由 DevDock 接管。")
        }
        if hospital.contains("start-bg"), hospital.contains("mini-api"), hospital.contains("admin-api") {
            let apiUnits = [("mini", "小程序 API", 8071, "/health/ready"), ("admin", "管理 API", 8072, "/admin-api/health/ready")].map { key, title, port, health in
                LaunchUnit(name: title, command: "./go-start start-bg \(key)", stopCommand: "./go-start stop \(key)",
                           logFile: ".run/hospital-api/\(key)/\(key).log", pidFile: ".run/hospital-api/\(key)/\(key).pid",
                           executable: ".run/hospital-api/\(key)/\(key)-api", detached: true,
                           endpoints: [Endpoint(name: title, url: "http://127.0.0.1:\(port)", healthURL: "http://127.0.0.1:\(port)\(health)")])
            }
            var units = apiUnits
            if hasDev(path, "apps/hospital-admin") {
                units.append(LaunchUnit(name: "管理网页", directory: "apps/hospital-admin", command: "npm run dev -- --host 127.0.0.1 --port 5173 --strictPort", endpoints: [Endpoint(name: "管理网页", url: "http://127.0.0.1:5173", healthURL: "http://127.0.0.1:5173")]))
            }
            if hasDev(path, "apps/ot-demo-h5") {
                units.append(LaunchUnit(name: "OT 演示", directory: "apps/ot-demo-h5", command: "corepack pnpm dev --host 127.0.0.1 --port 5174 --strictPort", enabled: false, endpoints: [Endpoint(name: "OT 演示", url: "http://127.0.0.1:5174/ot-demo/", healthURL: "http://127.0.0.1:5174/ot-demo/")]))
            }
            return Project(name: directory.lastPathComponent, path: path, units: units, note: "依次启动两个 API 和管理网页，OT 演示默认关闭。若 .env.local 改过端口，请在配置中调整服务地址。")
        }
        for entry in ["dev", "dev.sh", "start.sh", "go-start", "mac-start"] where !text(path, entry).isEmpty {
            return Project(name: directory.lastPathComponent, path: path,
                           units: [LaunchUnit(name: "项目", command: "./" + entry)],
                           note: "已发现脚本。首次启动前检查命令；可配置服务地址、停止命令和日志来源。")
        }
        if hasDev(path, ".") {
            let manager = FileManager.default.fileExists(atPath: path + "/pnpm-lock.yaml") ? "pnpm" : "npm run"
            return Project(name: directory.lastPathComponent, path: path, units: [LaunchUnit(name: "开发服务", command: manager + " dev")], note: "从 package.json 的 scripts.dev 发现；服务地址可在配置中补充。")
        }
        return nil
    }

    static func hasDev(_ root: String, _ subdirectory: String) -> Bool {
        let json = text(root, subdirectory + "/package.json")
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: String] else { return false }
        return scripts["dev"] != nil
    }

    // ponytail: bounded three-level discovery; add configurable depth only for deeper workspaces.
    static func scan(_ root: URL, depth: Int = 3) -> [Project] {
        var found: [Project] = []
        if let project = project(at: root) { found.append(project) }
        guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return found }
        for child in children.sorted(by: { $0.path < $1.path }) where !excluded.contains(child.lastPathComponent) {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // A detected project owns its nested packages; avoid duplicate API/front-end entries.
            if found.first?.path == root.path { break }
            found += scan(child, depth: depth - 1)
        }
        return found
    }
}
