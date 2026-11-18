import Foundation

/// 项目模板配置系统
struct ProjectTemplate: Codable {
    var id: String
    var name: String
    var description: String
    var patterns: [DetectionPattern]
    var units: [LaunchUnitTemplate]
    var note: String

    struct DetectionPattern: Codable {
        enum PatternType: String, Codable {
            case fileExists
            case fileContains
            case commandOutput
        }

        var type: PatternType
        var path: String
        var content: String?
        var command: String?
    }

    struct LaunchUnitTemplate: Codable {
        var name: String
        var directory: String
        var command: String
        var stopCommand: String?
        var logFile: String?
        var pidFile: String?
        var executable: String?
        var detached: Bool
        var enabled: Bool
        var endpoints: [EndpointTemplate]
        var requiresDevScript: Bool? = nil
    }

    struct EndpointTemplate: Codable {
        var name: String
        var url: String
        var healthURL: String
        var role: ServiceRole?
    }

    func matches(at directory: URL) -> Bool {
        let path = directory.path

        for pattern in patterns {
            switch pattern.type {
            case .fileExists:
                let filePath = path + "/" + pattern.path
                if !FileManager.default.fileExists(atPath: filePath) {
                    return false
                }

            case .fileContains:
                let filePath = path + "/" + pattern.path
                guard let content = try? String(contentsOfFile: filePath, encoding: .utf8),
                      let required = pattern.content else {
                    return false
                }
                if !content.contains(required) {
                    return false
                }

            case .commandOutput:
                // 为安全起见，不在匹配阶段执行命令
                return false
            }
        }

        return true
    }

    func instantiate(at directory: URL) -> Project {
        let path = directory.standardizedFileURL.path
        let units = self.units.filter {
            $0.requiresDevScript != true || Discovery.hasDev(path, $0.directory)
        }.map { template -> LaunchUnit in
            let endpoints = template.endpoints.map { ep -> Endpoint in
                Endpoint(name: ep.name, url: ep.url, healthURL: ep.healthURL, role: ep.role)
            }

            return LaunchUnit(
                name: template.name,
                directory: template.directory,
                command: template.command,
                stopCommand: template.stopCommand ?? "",
                logFile: template.logFile ?? "",
                pidFile: template.pidFile ?? "",
                executable: template.executable ?? "",
                detached: template.detached,
                enabled: template.enabled,
                endpoints: endpoints
            )
        }

        return Project(
            name: self.name.isEmpty ? directory.lastPathComponent : self.name,
            path: path,
            units: units,
            note: self.note
        )
    }
}

/// 项目模板管理器
final class TemplateManager {
    static let shared = TemplateManager()

    private var templates: [ProjectTemplate] = []
    private let templatesURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevDock", isDirectory: true)
        templatesURL = support.appendingPathComponent("templates", isDirectory: true)

        loadBuiltInTemplates()
        loadUserTemplates()
    }

    private func loadBuiltInTemplates() {
        // 迁移原有的硬编码项目识别
        templates.append(createJunmoTemplate())
        templates.append(createFootballTemplate())
        templates.append(createHospitalTemplate())
    }

    private func loadUserTemplates() {
        guard FileManager.default.fileExists(atPath: templatesURL.path) else { return }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: templatesURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let template = try? JSONDecoder().decode(ProjectTemplate.self, from: data) else {
                continue
            }
            templates.append(template)
        }
    }

    func detect(at directory: URL) -> Project? {
        // 优先匹配用户自定义模板（后加载的优先）
        for template in templates.reversed() {
            if template.matches(at: directory) {
                return template.instantiate(at: directory)
            }
        }

        // 回退到通用脚本发现
        return discoverGenericProject(at: directory)
    }

    private func discoverGenericProject(at directory: URL) -> Project? {
        let path = directory.standardizedFileURL.path

        // 检查常见启动脚本
        for entry in ["dev", "dev.sh", "start.sh", "go-start", "mac-start"] {
            let scriptPath = path + "/" + entry
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: scriptPath, isDirectory: &isDirectory), !isDirectory.boolValue,
               !Discovery.text(path, entry).isEmpty {
                return Project(
                    name: directory.lastPathComponent,
                    path: path,
                    units: [LaunchUnit(name: "项目", command: "./" + entry)],
                    note: "已发现脚本。首次启动前检查命令；可配置服务地址、停止命令和日志来源。"
                )
            }
        }

        if Discovery.hasDev(path) {
            let manager = FileManager.default.fileExists(atPath: path + "/pnpm-lock.yaml") ? "pnpm" : "npm run"
            return Project(name: directory.lastPathComponent, path: path,
                           units: [LaunchUnit(name: "开发服务", command: manager + " dev")],
                           note: "从 package.json 的 scripts.dev 发现；服务地址可在配置中补充。")
        }
        if FileManager.default.fileExists(atPath: path + "/go.mod") {
            return Project(name: directory.lastPathComponent, path: path,
                           units: [LaunchUnit(name: "Go 服务", command: "go run .")])
        }
        if FileManager.default.fileExists(atPath: path + "/requirements.txt"),
           FileManager.default.fileExists(atPath: path + "/main.py") {
            return Project(name: directory.lastPathComponent, path: path,
                           units: [LaunchUnit(name: "Python 服务", command: "python main.py")])
        }
        return nil
    }

    func saveTemplate(_ template: ProjectTemplate) throws {
        guard !template.id.isEmpty, template.id != ".", template.id != "..",
              !template.id.contains("/"), !template.id.contains("\0") else {
            throw AppError.message("模板 ID 必须是有效的文件名。")
        }
        try FileManager.default.createDirectory(at: templatesURL, withIntermediateDirectories: true)

        let fileURL = templatesURL.appendingPathComponent(template.id + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(template)
        try data.write(to: fileURL, options: .atomic)
        templates.removeAll { $0.id == template.id }
        templates.append(template)
    }

    func listTemplates() -> [ProjectTemplate] {
        return templates
    }

    // MARK: - 内置模板定义

    private func createJunmoTemplate() -> ProjectTemplate {
        ProjectTemplate(
            id: "junmo-assistant",
            name: "",
            description: "君陌助手项目",
            patterns: [
                .init(type: .fileExists, path: "dev", content: nil, command: nil),
                .init(type: .fileContains, path: "dev", content: "JUNMO_DEV_SKIP_INSTALL", command: nil),
                .init(type: .fileContains, path: "dev", content: "18110", command: nil)
            ],
            units: [
                .init(
                    name: "前后端",
                    directory: ".",
                    command: "./dev",
                    stopCommand: nil,
                    logFile: nil,
                    pidFile: nil,
                    executable: nil,
                    detached: false,
                    enabled: true,
                    endpoints: [
                        .init(name: "Go API", url: "http://127.0.0.1:18110", healthURL: "http://127.0.0.1:18110/health", role: .backend),
                        .init(name: "控制台", url: "http://127.0.0.1:15175", healthURL: "http://127.0.0.1:15175", role: .frontend)
                    ]
                )
            ],
            note: "沿用 ./dev 的热更新和启动顺序；前后端日志为脚本的合并输出。"
        )
    }

    private func createFootballTemplate() -> ProjectTemplate {
        ProjectTemplate(
            id: "football",
            name: "",
            description: "Football 项目",
            patterns: [
                .init(type: .fileExists, path: "dev.sh", content: nil, command: nil),
                .init(type: .fileContains, path: "dev.sh", content: "com.football.local-agent", command: nil),
                .init(type: .fileContains, path: "dev.sh", content: "9802", command: nil)
            ],
            units: [
                .init(
                    name: "API · Web · Admin",
                    directory: ".",
                    command: "./dev.sh",
                    stopCommand: nil,
                    logFile: nil,
                    pidFile: nil,
                    executable: nil,
                    detached: false,
                    enabled: true,
                    endpoints: [
                        .init(name: "Go API", url: "http://127.0.0.1:9800", healthURL: "http://127.0.0.1:9800/api/v1/home/summary", role: .backend),
                        .init(name: "Web", url: "http://127.0.0.1:9801", healthURL: "http://127.0.0.1:9801", role: .frontend),
                        .init(name: "Admin", url: "http://127.0.0.1:9802", healthURL: "http://127.0.0.1:9802", role: .frontend)
                    ]
                )
            ],
            note: "保留原脚本的启动顺序；三个端为合并日志。已运行的外部后端不由 DevDock 接管。"
        )
    }

    private func createHospitalTemplate() -> ProjectTemplate {
        ProjectTemplate(
            id: "hospital-assistant",
            name: "",
            description: "医院助手项目",
            patterns: [
                .init(type: .fileExists, path: "go-start", content: nil, command: nil),
                .init(type: .fileContains, path: "go-start", content: "start-bg", command: nil),
                .init(type: .fileContains, path: "go-start", content: "mini-api", command: nil),
                .init(type: .fileContains, path: "go-start", content: "admin-api", command: nil)
            ],
            units: [
                .init(
                    name: "小程序 API",
                    directory: ".",
                    command: "./go-start start-bg mini",
                    stopCommand: "./go-start stop mini",
                    logFile: ".run/hospital-api/mini/mini.log",
                    pidFile: ".run/hospital-api/mini/mini.pid",
                    executable: ".run/hospital-api/mini/mini-api",
                    detached: true,
                    enabled: true,
                    endpoints: [
                        .init(name: "小程序 API", url: "http://127.0.0.1:8071", healthURL: "http://127.0.0.1:8071/health/ready", role: .backend)
                    ]
                ),
                .init(
                    name: "管理 API",
                    directory: ".",
                    command: "./go-start start-bg admin",
                    stopCommand: "./go-start stop admin",
                    logFile: ".run/hospital-api/admin/admin.log",
                    pidFile: ".run/hospital-api/admin/admin.pid",
                    executable: ".run/hospital-api/admin/admin-api",
                    detached: true,
                    enabled: true,
                    endpoints: [
                        .init(name: "管理 API", url: "http://127.0.0.1:8072", healthURL: "http://127.0.0.1:8072/admin-api/health/ready", role: .backend)
                    ]
                ),
                .init(
                    name: "管理网页",
                    directory: "apps/hospital-admin",
                    command: "npm run dev -- --host 127.0.0.1 --port 5173 --strictPort",
                    stopCommand: nil,
                    logFile: nil,
                    pidFile: nil,
                    executable: nil,
                    detached: false,
                    enabled: true,
                    endpoints: [
                        .init(name: "管理网页", url: "http://127.0.0.1:5173", healthURL: "http://127.0.0.1:5173", role: .frontend)
                    ],
                    requiresDevScript: true
                ),
                .init(
                    name: "OT 演示",
                    directory: "apps/ot-demo-h5",
                    command: "corepack pnpm dev --host 127.0.0.1 --port 5174 --strictPort",
                    detached: false,
                    enabled: false,
                    endpoints: [
                        .init(name: "OT 演示", url: "http://127.0.0.1:5174/ot-demo/", healthURL: "http://127.0.0.1:5174/ot-demo/", role: .frontend)
                    ],
                    requiresDevScript: true
                )
            ],
            note: "依次启动两个 API 和管理网页，OT 演示默认关闭。若 .env.local 改过端口，请在配置中调整服务地址。"
        )
    }
}
