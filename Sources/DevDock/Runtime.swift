import Foundation
import Darwin

struct CommandResult {
    let status: Int32
    let output: String
}

struct Listener: Hashable {
    let pid: Int32
    let name: String
    let host: String
    let port: Int
    let ipv6: Bool

    var localURL: String? {
        if host == "::1" || host == "::" || (host == "*" && ipv6) { return "http://[::1]:\(port)" }
        if ["*", "0.0.0.0", "127.0.0.1"].contains(host) { return "http://127.0.0.1:\(port)" }
        return nil
    }
    func matches(_ value: String) -> Bool {
        guard let url = URL(string: value), port == (url.port ?? (url.scheme == "https" ? 443 : 80)) else { return false }
        let target = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard target == "localhost" || target.contains(":") == ipv6 else { return false }
        return host == target || host == "*" || host == "0.0.0.0" || host == "::"
            || (target == "localhost" && ["127.0.0.1", "::1"].contains(host))
    }
}

struct ProcessSnapshot {
    struct ProcessRow { let parent: Int32; let group: Int32; let command: String }
    var processes: [Int32: ProcessRow]
    var listeners: [Listener]

    init(processOutput: String, listenerOutput: String) {
        processes = [:]
        for line in processOutput.split(separator: "\n") {
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            if fields.count >= 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]), let group = Int32(fields[2]) {
                processes[pid] = ProcessRow(parent: parent, group: group, command: fields.count == 4 ? String(fields[3]) : "")
            }
        }
        var pid: Int32 = 0
        var name = "服务"
        var ipv6 = false
        var found = Set<Listener>()
        for line in listenerOutput.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst()) ?? 0; name = "服务"; ipv6 = false
            case "c": name = String(line.dropFirst())
            case "t": ipv6 = line.dropFirst() == "IPv6"
            case "n":
                guard pid > 1, let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]), (1...65535).contains(port) else { continue }
                let host = String(line[line.index(after: line.startIndex)..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                found.insert(Listener(pid: pid, name: name, host: host, port: port, ipv6: ipv6))
            default: break
            }
        }
        listeners = found.sorted { ($0.port, $0.pid, $0.host) < ($1.port, $1.pid, $1.host) }
    }

    func ownedPIDs(group: Int32?, daemon: Int32?) -> Set<Int32> {
        var owned = Set(processes.compactMap { group != nil && $0.value.group == group ? $0.key : nil })
        if let daemon { owned.insert(daemon) }
        // Include daemon descendants (e.g. reload workers), never similarly named processes.
        var previous = -1
        while previous != owned.count {
            previous = owned.count
            for (pid, row) in processes where owned.contains(row.parent) { owned.insert(pid) }
        }
        return owned
    }

    func externalProcesses(_ project: Project, _ unit: LaunchUnit, excluding managed: Set<Int32>) -> [ProcessIdentity] {
        let directory = System.canonicalPath(project.resolved(unit.directory))
        if unit.detached {
            guard let pid = System.ownedPID(project: project, unit: unit), let identity = ProcessIdentity(pid),
                  !belongsToManagedRun(pid, roots: managed),
                  System.workingDirectory(pid) == directory ||
                  System.canonicalPath(project.resolved(unit.executable)).hasPrefix(directory + "/") else { return [] }
            return [identity]
        }
        let command = unit.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = command.hasPrefix("./") ? directory + "/" + command.dropFirst(2) : nil
        let autoGameEntry = Discovery.autoGameEntry(in: directory, unit: unit)
        return processes.compactMap { pid, row in
            // shortcut: recognize exact commands and shell-run scripts; add explicit identity for custom wrappers.
            if row.command != command, row.command != script,
               !matchesAutoGame(pid, command: row.command, entry: autoGameEntry, directory: directory) {
                guard let script, row.command.hasSuffix(" " + command) || row.command.hasSuffix(" " + script) else { return nil }
                let parts = row.command.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2, parts[1] == command || parts[1] == script,
                      ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(String(parts[0]).split(separator: "/").last ?? "") else { return nil }
            }
            guard !belongsToManagedRun(pid, roots: managed),
                  let identity = ProcessIdentity(pid), System.workingDirectory(pid) == directory else { return nil }
            return identity
        }.sorted { $0.pid < $1.pid }
    }

    private func matchesAutoGame(_ pid: Int32, command: String, entry: String?, directory: String) -> Bool {
        guard let entry else { return false }
        func isPython(_ path: String) -> Bool {
            let name = path.split(separator: "/").last?.lowercased() ?? ""
            return name == "python" || (name.hasPrefix("python3") && name.dropFirst(6).allSatisfy { $0 == "." || $0.isNumber })
        }
        let supervisor = " --supervise"
        let launcher = command.hasSuffix(supervisor) ? String(command.dropLast(supervisor.count)) : command
        for path in [entry, "./" + entry, directory + "/" + entry] {
            let suffix = " " + path
            guard launcher.hasSuffix(suffix) else { continue }
            let executable = String(launcher.dropLast(suffix.count))
            if isPython(executable), let actual = System.executable(pid: pid), isPython(actual),
               !executable.contains(where: \.isWhitespace) || executable == actual {
                return true
            }
        }
        return false
    }

    func externalListeners(_ project: Project, _ unit: LaunchUnit, projects: [Project], excluding roots: Set<Int32>) -> [ProcessIdentity] {
        let directory = System.canonicalPath(project.resolved(unit.directory))
        let directories = projects.flatMap { project in
            project.enabledUnits.map { ($0.id, System.canonicalPath(project.resolved($0.directory))) }
        }
        return Set(listeners.filter { $0.localURL != nil }.map(\.pid)).sorted().compactMap { pid in
            guard !belongsToManagedRun(pid, roots: roots), let identity = ProcessIdentity(pid),
                  let working = System.workingDirectory(pid),
                  working == directory || working.hasPrefix(directory + "/") else { return nil }
            let matches = directories.filter { working == $0.1 || working.hasPrefix($0.1 + "/") }
            let closest = matches.map { $0.1.count }.max()
            let owners = matches.filter { $0.1.count == closest }
            // shortcut: shared launch directories need an exact launcher match to disambiguate units.
            guard owners.count == 1, owners.first?.0 == unit.id,
                  isProjectService(pid, directory: directory), identity.isAlive else { return nil }
            return identity
        }
    }

    private func isProjectService(_ pid: Int32, directory: String) -> Bool {
        guard let executable = System.executable(pid: pid) else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        var service = ["node", "nodejs", "bun", "deno"].contains(name) || name.hasPrefix("python")
            || System.canonicalPath(executable).hasPrefix(directory + "/")
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted, let row = processes[current],
              let working = System.workingDirectory(current),
              working == directory || working.hasPrefix(directory + "/") {
            if Self.isTestCommand(row.command) { return false }
            let words = row.command.split(whereSeparator: \.isWhitespace)
            if words.first?.split(separator: "/").last == "go", words.dropFirst().first == "run" { service = true }
            current = row.parent
        }
        return service && !name.hasSuffix(".test")
    }

    private static func isTestCommand(_ command: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace)
        let names = words.map { $0.split(separator: "/").last ?? $0 }
        if words.contains(where: { $0.hasPrefix("-test.") || $0 == "--test" })
            || names.contains(where: { ["pytest", "unittest", "jest", "jest.js", "vitest", "vitest.mjs"].contains($0) }) { return true }
        guard let executable = names.first else { return false }
        if executable == "go", words.dropFirst().first == "test" { return true }
        if ["npm", "pnpm", "yarn", "bun"].contains(executable),
           let script = words.dropFirst().drop(while: { $0 == "run" || $0 == "run-script" }).first {
            return script == "test" || script.hasPrefix("test:")
        }
        return false
    }

    private func belongsToManagedRun(_ pid: Int32, roots: Set<Int32>) -> Bool {
        var current = pid
        while current > 1 {
            if roots.contains(current) { return true }
            guard let row = processes[current], row.parent != current else { return false }
            if roots.contains(row.group) { return true }
            current = row.parent
        }
        return false
    }

    func state(for endpoint: Endpoint, owned: Set<Int32>) -> EndpointState {
        let opening = matchingListeners(endpoint.url)
        let checking = matchingListeners(endpoint.healthURL)
        // Fail closed for shared/reused sockets: an HTTP response is never ownership evidence.
        if let other = (opening + checking).first(where: { !owned.contains($0.pid) }) { return .occupied(other.pid) }
        guard !opening.isEmpty, !checking.isEmpty else { return .stopped }
        return .listening
    }

    func activity(for endpoint: Endpoint, owned: Set<Int32>) -> EndpointActivity? {
        let matching = matchingListeners(endpoint.url)
        guard !matching.isEmpty, matching.allSatisfy({ owned.contains($0.pid) }) else { return nil }
        let roles = Set(matching.compactMap { serviceRole($0) })
        return EndpointActivity(pids: Set(matching.map(\.pid)).sorted(),
                                inferredRole: roles.count == 1 ? roles.first : nil)
    }

    private func serviceRole(_ listener: Listener) -> ServiceRole? {
        let arguments = (processes[listener.pid]?.command ?? "").split(whereSeparator: \.isWhitespace)
        func basename(_ value: Substring) -> Substring { value.split(separator: "/").last ?? value }
        let executable = arguments.first.map(basename) ?? Substring(listener.name)
        let entry: Substring
        if executable == "node" || executable == "nodejs" || executable.hasPrefix("python") {
            let index = arguments.dropFirst().first == "-m" ? 2 : 1
            entry = arguments.indices.contains(index) ? basename(arguments[index]) : executable
        } else {
            entry = executable
        }
        // shortcut: only recognize explicit server entries; configure a role for custom or full-stack servers.
        switch entry {
        case "vite", "vite.js", "webpack-dev-server", "webpack-dev-server.js": return .frontend
        case "uvicorn", "gunicorn", "gunicorn:": return .backend
        default: return nil
        }
    }

    private func matchingListeners(_ value: String) -> [Listener] {
        let exact = listeners.filter { $0.matches(value) }
        guard exact.isEmpty, let url = URL(string: value), url.host == "127.0.0.1" else { return exact }
        // lsof cannot distinguish IPv6-only from dual-stack sockets. A wildcard is a
        // candidate only when no IPv4 socket wins; HTTP still has to pass for readiness.
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        return listeners.filter { $0.ipv6 && ["*", "::"].contains($0.host) && $0.port == port }
    }
}

struct ProcessIdentity: Equatable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    init?(_ pid: Int32, parent: Int32? = nil) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, pid != getpid(), proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), parent.map({ Int32(info.pbi_ppid) == $0 }) != false else { return nil }
        self.pid = pid
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
    }

    var isAlive: Bool { Self(pid) == self }
}

private final class CaptureBuffer {
    private let lock = NSLock()
    private var data = Data()
    func drain(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            // Keep memory bounded even for a noisy shell profile, but always drain the pipe.
            if data.count < AppConfiguration.captureBufferMaxSize { data.append(contentsOf: buffer.prefix(count)) }
        }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum System {
    static func processSnapshot() async -> ProcessSnapshot? {
        async let processes = capture("/bin/ps", ["-axww", "-o", "pid=,ppid=,pgid=,command="])
        async let listeners = capture("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpctn"])
        guard let (p, l) = try? await (processes, listeners), p.status == 0, [0, 1].contains(l.status) else { return nil }
        return ProcessSnapshot(processOutput: p.output, listenerOutput: l.output)
    }
    static func capture(_ executable: String, _ arguments: [String], timeout: Double = AppConfiguration.processSnapshotTimeout) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let buffer = CaptureBuffer()
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            pipe.fileHandleForReading.readabilityHandler = { _ in buffer.drain(fd) }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { task in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.drain(fd)
                continuation.resume(returning: CommandResult(status: task.terminationStatus, output: buffer.text))
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
            } catch {
                process.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : canonicalPath(path)
    }

    static func stopExternal(_ roots: [ProcessIdentity], in snapshot: ProcessSnapshot, supervised: Bool = false) async -> Bool {
        var targets = roots.filter(\.isAlive)
        let children = Dictionary(grouping: snapshot.processes, by: { $0.value.parent })
        var index = 0
        while index < targets.count {
            let parent = targets[index]
            index += 1
            if parent.isAlive {
                for (pid, _) in children[parent.pid] ?? [] {
                    if let child = ProcessIdentity(pid, parent: parent.pid), !targets.contains(child) { targets.append(child) }
                }
            }
        }
        if supervised {
            let liveRoots = roots.filter(\.isAlive)
            let rootPIDs = Set(liveRoots.map(\.pid))
            let launchers = liveRoots.filter { !rootPIDs.contains(snapshot.processes[$0.pid]?.parent ?? 0) }
            guard !Task.isCancelled, launchers.count <= 1 else { return false }
            // Auto Game waits for its worker and web service to finish in order.
            for root in launchers {
                if root.isAlive { kill(root.pid, SIGTERM) }
            }
            for _ in 0..<AppConfiguration.serviceCheckRetries {
                if !targets.contains(where: \.isAlive) { return true }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return false }
            }
            return !targets.contains(where: \.isAlive)
        }
        // External jobs can share a group with the user's shell; signal verified PIDs only.
        for signal in [SIGTERM, SIGKILL] {
            guard !Task.isCancelled else { return false }
            for target in targets where target.isAlive { kill(target.pid, signal) }
            for _ in 0..<20 {
                if !targets.contains(where: \.isAlive) { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return !targets.contains(where: \.isAlive)
    }

    static func executable(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func ownedPID(project: Project, unit: LaunchUnit) -> Int32? {
        guard let value = try? String(contentsOfFile: project.resolved(unit.pidFile), encoding: .utf8),
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
              let actual = executable(pid: pid),
              URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == URL(fileURLWithPath: project.resolved(unit.executable)).resolvingSymlinksInPath().path else { return nil }
        return pid
    }

    static func healthy(_ endpoint: Endpoint) async -> Bool {
        guard let url = URL(string: endpoint.healthURL), ["localhost", "127.0.0.1", "::1"].contains((url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        request.setValue("DevDock/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
        } catch { return false }
    }

    static func shellEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Resolve the user's interactive shell once, without persisting or displaying credentials.
        if let result = try? await capture("/bin/zsh", ["-ilc", "/usr/bin/env -0"], timeout: 8), result.status == 0 {
            for entry in result.output.split(separator: "\0") {
                guard let equal = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<equal])
                guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { continue }
                environment[key] = String(entry[entry.index(after: equal)...])
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home)/go/bin"
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        return environment
    }
}

/// One bounded log file per command. Pipe draining happens away from the UI thread.
final class LogSink {
    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle
    private var size: UInt64 = 0
    private let limit = AppConfiguration.logMaxFileSize
    private(set) var failure: String?

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        do {
            if size + UInt64(data.count) > limit {
                try handle.close()
                let previous = url.appendingPathExtension("previous")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                handle = try FileHandle(forWritingTo: url)
                size = 0
            }
            try handle.write(contentsOf: data)
            size += UInt64(data.count)
        } catch { failure = error.localizedDescription }
    }

    deinit { try? handle.close() }
}

final class RunningCommand {
    let process = Process()
    let pipe = Pipe()
    let sink: LogSink
    let started = Date()
    var pid: Int32 { process.processIdentifier }
    var exited: Bool { !process.isRunning }
    var exitCode: Int32? { exited ? process.terminationStatus : nil }

    init(command: String, directory: String, environment: [String: String], logURL: URL, helperURL: URL) throws {
        sink = try LogSink(url: logURL)
        process.executableURL = helperURL
        process.arguments = ["--run", directory, command]
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let sink = self.sink
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { sink.append(data) }
        }
        do { try process.run() }
        catch { pipe.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    func stop() async {
        let group = pid
        guard group > 1 else { return }
        // The helper verifies its own process group before exec. Never signal the app's group.
        if getpgid(group) == group || kill(-group, 0) == 0 {
            kill(-group, SIGTERM)
            for _ in 0..<30 {
                if kill(-group, 0) != 0 { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        } else if process.isRunning {
            // A click can arrive before the helper has established its process group.
            process.terminate()
        }
    }
}

/// Entry point used by this app's own command launches, not a second service or dependency.
func runHelperIfRequested() {
    let args = CommandLine.arguments
    guard args.count == 4, args[1] == "--run" else { return }
    // Foundation may already make its subprocess a group leader; setsid would then fail with EPERM.
    guard (getpgrp() == getpid() || setpgid(0, 0) == 0), chdir(args[2]) == 0 else {
        fputs("DevDock: 无法创建独立进程组或进入工作目录。\n", stderr)
        exit(126)
    }
    let values = ["/bin/zsh", "-lc", args[3]]
    let pointers = values.map { strdup($0) } + [nil]
    pointers.withUnsafeBufferPointer { ptr in _ = execv("/bin/zsh", ptr.baseAddress!) }
    fputs("DevDock: 无法执行 shell。\n", stderr)
    exit(127)
}

func tailText(_ url: URL, bytes: UInt64 = AppConfiguration.logTailBytes) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    do {
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: length > bytes ? length - bytes : 0)
        let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        // Strip terminal control sequences while preserving readable line breaks.
        return text.replacingOccurrences(of: "\\u001B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    } catch { return "读取日志失败：\(error.localizedDescription)" }
}
