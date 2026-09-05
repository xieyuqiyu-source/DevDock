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
    struct ProcessRow { let parent: Int32; let group: Int32 }
    var processes: [Int32: ProcessRow]
    var listeners: [Listener]

    init(processOutput: String, listenerOutput: String) {
        processes = [:]
        for line in processOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            if fields.count == 3 { processes[fields[0]] = ProcessRow(parent: fields[1], group: fields[2]) }
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

    func state(for endpoint: Endpoint, owned: Set<Int32>) -> EndpointState {
        let opening = matchingListeners(endpoint.url)
        let checking = matchingListeners(endpoint.healthURL)
        // Fail closed for shared/reused sockets: an HTTP response is never ownership evidence.
        if let other = (opening + checking).first(where: { !owned.contains($0.pid) }) { return .occupied(other.pid) }
        guard !opening.isEmpty, !checking.isEmpty else { return .stopped }
        return .listening
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
            if data.count < 2 * 1024 * 1024 { data.append(contentsOf: buffer.prefix(count)) }
        }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum System {
    static func processSnapshot() async -> ProcessSnapshot? {
        async let processes = capture("/bin/ps", ["-ax", "-o", "pid=,ppid=,pgid="])
        async let listeners = capture("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpctn"])
        guard let (p, l) = try? await (processes, listeners), p.status == 0, [0, 1].contains(l.status) else { return nil }
        return ProcessSnapshot(processOutput: p.output, listenerOutput: l.output)
    }
    static func capture(_ executable: String, _ arguments: [String], timeout: Double = 5) async throws -> CommandResult {
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

    static func listeningPID(port: Int) async -> Int32? {
        let result = try? await capture("/usr/sbin/lsof", ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"])
        return result?.output.split(separator: "\n").first.flatMap { Int32($0) }
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
    private let limit: UInt64 = 5 * 1024 * 1024
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

func tailText(_ url: URL, bytes: UInt64 = 512 * 1024) -> String {
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
