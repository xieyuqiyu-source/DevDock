import Foundation
import AppKit

@MainActor
final class DevDockTests {
    var temporary: [URL] = []
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DevDock-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporary.append(url)
        return url
    }

    var helper: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/DevDock")
    }

    func testDiscoveryDoesNotExecuteAndSkipsDependencies() throws {
        let root = try temp()
        let project = root.appendingPathComponent("项目 ' $(touch SHOULD_NOT_EXIST)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "#!/bin/bash\ntouch SHOULD_NOT_EXIST\n".write(to: project.appendingPathComponent("dev"), atomically: true, encoding: .utf8)
        let ignored = root.appendingPathComponent("node_modules/fake")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try "echo ignored".write(to: ignored.appendingPathComponent("dev"), atomically: true, encoding: .utf8)
        let found = Discovery.scan(root)
        try equal(found.count, 1)
        try equal(found[0].path, project.path)
        try expectFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    func testHospitalDiscoverySeparatesAPIsFromWeb() throws {
        let root = try temp()
        try "start-bg mini-api admin-api".write(to: root.appendingPathComponent("go-start"), atomically: true, encoding: .utf8)
        let admin = root.appendingPathComponent("apps/hospital-admin")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try #"{"scripts":{"dev":"vite"}}"#.write(to: admin.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let project = try unwrap(Discovery.project(at: root))
        try equal(project.units.count, 3)
        try expect(project.units[0].detached)
        try equal(project.units[1].command, "./go-start start-bg admin")
        try expectFalse(project.units[2].detached)
        try expect(project.units[2].command.contains("--strictPort"))
    }

    func testCaptureDrainsLargeOutputAndTimesOut() async throws {
        let result = try await System.capture("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' x"], timeout: 3)
        try equal(result.status, 0)
        try equal(result.output.count, 200000)
        let before = Date()
        let stubborn = try await System.capture("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
        try different(stubborn.status, 0)
        try less(Date().timeIntervalSince(before), 3)
    }

    func testForegroundStopsEntireProcessGroupAndPreservesWorkingDirectory() async throws {
        let root = try temp()
        let directory = root.appendingPathComponent("中文 ' 空格")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("launch.log")
        let command = try RunningCommand(command: "pwd; /bin/sleep 60 & echo CHILD=$!; wait", directory: directory.path,
            environment: ProcessInfo.processInfo.environment, logURL: log, helperURL: helper)
        // Login shell initialization can take longer on different hosts or under build load.
        for _ in 0..<100 {
            if tailText(log).contains("CHILD=") || command.exited { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectFalse(command.exited)
        try equal(getpgid(command.pid), command.pid)
        let content = tailText(log)
        try expect(content.contains(directory.path))
        let child = content.components(separatedBy: "\n").first { $0.hasPrefix("CHILD=") }.flatMap { Int32($0.dropFirst(6)) }
        try expectNotNil(child)
        await command.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        try expect(command.exited)
        if let child { try expectNil(System.executable(pid: child), "Child process must be gone after group stop") }
    }

    @MainActor
    func testDetachedLifecycleAndPIDOwnership() async throws {
        let root = try temp()
        let pidPath = root.appendingPathComponent("daemon.pid")
        let unit = LaunchUnit(name: "隔离后台", command: "nohup /bin/sleep 60 > daemon.log 2>&1 < /dev/null & echo $! > daemon.pid",
            stopCommand: "kill -TERM \"$(cat daemon.pid)\"", logFile: "daemon.log", pidFile: "daemon.pid", executable: "/bin/sleep", detached: true)
        let project = Project(name: "后台测试", path: root.path, units: [unit])
        let store = ProjectStore(support: root.appendingPathComponent("support"), helperURL: helper, seed: false, monitor: false)
        try store.update(project)
        store.launch(project)
        for _ in 0..<150 {
            if !store.busy.contains(project.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectNil(store.notices[project.id])
        var pid = try unwrap(System.ownedPID(project: project, unit: unit))
        defer { kill(pid, SIGKILL) }
        try expect(store.isActive(project))
        // A PID file pointing to this test runner must not be treated as the configured daemon.
        try String(getpid()).write(to: pidPath, atomically: true, encoding: .utf8)
        try expectNil(System.ownedPID(project: project, unit: unit))
        try String(pid).write(to: pidPath, atomically: true, encoding: .utf8)
        let previousPID = pid
        store.stop(project, restart: true)
        for _ in 0..<150 {
            if !store.busy.contains(project.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        pid = try unwrap(System.ownedPID(project: project, unit: unit))
        try expectNil(store.notices[project.id])
        try different(pid, previousPID)
        try expectNil(System.executable(pid: previousPID), "Restart must stop the previous process")
        try expect(store.isActive(project))
        store.stop(project)
        for _ in 0..<100 {
            if !store.busy.contains(project.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectNil(store.notices[project.id])
        try expectNil(System.ownedPID(project: project, unit: unit))
        try expectFalse(store.isActive(project))
        let restored = ProjectStore(support: root.appendingPathComponent("support"), helperURL: helper, seed: false, monitor: false)
        try equal(restored.projects, [project])
    }

    @MainActor
    func testRepeatedUnitStopAndCancelledLaunch() async throws {
        let root = try temp()
        let first = LaunchUnit(name: "one", command: "/bin/sleep 60")
        let second = LaunchUnit(name: "two", command: "/bin/sleep 60")
        let project = Project(name: "多服务", path: root.path, units: [first, second])
        let store = ProjectStore(support: root.appendingPathComponent("support"), helperURL: helper, seed: false, monitor: false)
        try store.update(project)
        store.launch(project)
        for _ in 0..<150 {
            if !store.busy.contains(project.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectNil(store.notices[project.id])
        store.stop(project, only: first.id)
        for _ in 0..<80 {
            if !store.busy.contains(project.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectFalse(store.isActive(first))
        try expect(store.isActive(second))
        store.stop(project, only: second.id)
        for _ in 0..<80 {
            if !store.busy.contains(project.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectFalse(store.isActive(project))
        store.launch(project)
        try await Task.sleep(nanoseconds: 100_000_000)
        store.stop(project)
        await store.shutdown()
        try expectFalse(store.isActive(project))
        try expectFalse(store.busy.contains(project.id))
    }

    @MainActor
    func testDetachedMissingPIDStillCleansProcessGroup() async throws {
        let root = try temp()
        let unit = LaunchUnit(name: "错误 PID 路径", command: "nohup /bin/sleep 60 > daemon.log 2>&1 < /dev/null & echo $! > actual.pid",
            stopCommand: "true", pidFile: "missing.pid", executable: "/bin/sleep", detached: true)
        let project = Project(name: "失败清理", path: root.path, units: [unit])
        let store = ProjectStore(support: root.appendingPathComponent("support"), helperURL: helper, seed: false, monitor: false)
        try store.update(project)
        store.launch(project)
        for _ in 0..<150 {
            if !store.busy.contains(project.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectNotNil(store.notices[project.id])
        let value = try String(contentsOf: root.appendingPathComponent("actual.pid"), encoding: .utf8)
        let pid = try unwrap(Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        try expectNotNil(System.executable(pid: pid))
        store.stop(project)
        for _ in 0..<100 {
            if !store.busy.contains(project.id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectNil(System.executable(pid: pid))
        try expectFalse(store.isActive(project))
    }

    @MainActor
    func testOneProjectsPortNeverLightsAnotherProject() async throws {
        for dualStack in [false, true] {
        let root = try temp()
        let script = """
        from http.server import HTTPServer, BaseHTTPRequestHandler
        from pathlib import Path
        import socket
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'OK')
            def log_message(self, *args): pass
        class DualStackHTTPServer(HTTPServer):
            address_family = socket.AF_INET6
            def server_bind(self):
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                super().server_bind()
        server = \(dualStack ? "DualStackHTTPServer(('::', 0), Handler)" : "HTTPServer(('127.0.0.1', 0), Handler)")
        Path('port').write_text(str(server.server_port))
        server.serve_forever()
        """
        try script.write(to: root.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
        let unit = LaunchUnit(name: "动态端口服务", command: "/usr/bin/python3 serve.py")
        let a = Project(name: "真正监听的项目 A", path: root.path, units: [unit])
        let store = ProjectStore(support: root.appendingPathComponent("support"), helperURL: helper, seed: false, monitor: false)
        try store.update(a)
        store.launch(a)
        do {
            for _ in 0..<150 {
                if !store.busy.contains(a.id), FileManager.default.fileExists(atPath: root.appendingPathComponent("port").path) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let port = try String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8)
            let url = "http://127.0.0.1:" + port
            let endpoint = Endpoint(name: "相同端口", url: url, healthURL: url)
            let b = Project(name: "尚未启动的项目 B", path: root.path, units: [LaunchUnit(name: "B", command: "/bin/sleep 60", endpoints: [endpoint])])
            try store.update(b)
            await store.refresh()
            try equal(store.status(b), "端口被占用")
            try expectFalse(store.endpointStates[endpoint.id]?.isOwned ?? true)
            let discoveredURL = dualStack ? "http://[::1]:" + port : url
            let discovered = try unwrap(store.discoveredEndpoints[unit.id]?.first { $0.url == discoveredURL })
            try equal(store.endpointStates[discovered.id], .listening)
            // Keep the actual process running while adding a health check to its test configuration.
            var configuredA = a
            let ownEndpoint = Endpoint(name: "A 健康检查", url: url, healthURL: url)
            configuredA.units[0].endpoints = [ownEndpoint]
            let index = try unwrap(store.projects.firstIndex { $0.id == a.id })
            store.projects[index] = configuredA
            await store.refresh()
            try equal(store.endpointStates[ownEndpoint.id], .ready)
            try equal(store.status(b), "端口被占用")
            await store.shutdown()
            await store.refresh()
            try equal(store.endpointStates[endpoint.id], .stopped)
            try expect((store.discoveredEndpoints[unit.id] ?? []).isEmpty)
        } catch { await store.shutdown(); throw error }
        }
    }

    func testAddressFamilyAndSharedListeners() throws {
        let snapshot = ProcessSnapshot(processOutput: "100 1 100\n101 100 101\n200 1 200\n", listenerOutput: """
        p101
        cnode
        tIPv6
        n*:5173
        p200
        cother
        tIPv4
        n127.0.0.1:5173
        """)
        let owned = snapshot.ownedPIDs(group: 100, daemon: nil)
        try expect(owned.contains(101))
        try expectFalse(owned.contains(200))
        try expect(snapshot.ownedPIDs(group: nil, daemon: 100).contains(101))
        let listener = try unwrap(snapshot.listeners.first { $0.pid == 101 })
        let url = try unwrap(listener.localURL)
        try equal(url, "http://[::1]:5173")
        let ipv6 = Endpoint(name: "IPv6", url: url, healthURL: url)
        try equal(snapshot.state(for: ipv6, owned: owned), .listening)
        let ipv4 = Endpoint(name: "IPv4", url: "http://127.0.0.1:5173", healthURL: "http://127.0.0.1:5173")
        try equal(snapshot.state(for: ipv4, owned: owned), .occupied(200))
        let localhost = Endpoint(name: "两种地址族", url: "http://localhost:5173", healthURL: "http://localhost:5173")
        try equal(snapshot.state(for: localhost, owned: owned), .occupied(200))
        var shared = snapshot
        shared.listeners.append(Listener(pid: 200, name: "shared", host: "*", port: 5173, ipv6: true))
        try equal(shared.state(for: ipv6, owned: owned), .occupied(200))
        try Project(name: "IPv6 配置", path: "/tmp", units: [LaunchUnit(name: "IPv6", command: "true", endpoints: [ipv6])]).validate()
    }

    func testBoundedLogsAndANSIConversion() throws {
        let root = try temp()
        let log = root.appendingPathComponent("out.log")
        let sink = try LogSink(url: log)
        sink.append(Data(repeating: 65, count: 4 * 1024 * 1024))
        sink.append(Data(repeating: 66, count: 2 * 1024 * 1024))
        try expect(FileManager.default.fileExists(atPath: log.appendingPathExtension("previous").path))
        try equal(tailText(log).count, 512 * 1024)
        let colored = root.appendingPathComponent("colored.log")
        try "\u{001B}[31mERROR 中文\u{001B}[0m\n".write(to: colored, atomically: true, encoding: .utf8)
        try equal(tailText(colored), "ERROR 中文\n")
    }
}

func expect(_ value: Bool, _ message: String = "condition failed", file: StaticString = #filePath, line: UInt = #line) throws {
    if !value { throw AppError.message("\(file):\(line): \(message)") }
}
func expectFalse(_ value: Bool) throws { try expect(!value) }
func equal<T: Equatable>(_ a: T, _ b: T) throws { try expect(a == b, "\(a) != \(b)") }
func different<T: Equatable>(_ a: T, _ b: T) throws { try expect(a != b) }
func less<T: Comparable>(_ a: T, _ b: T) throws { try expect(a < b) }
func expectNil<T>(_ value: T?, _ message: String = "expected nil", file: StaticString = #filePath, line: UInt = #line) throws {
    try expect(value == nil, "\(message): \(String(describing: value))", file: file, line: line)
}
func expectNotNil<T>(_ value: T?) throws { try expect(value != nil) }
func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw AppError.message("Unexpected nil") }; return value }

@main
struct Checks {
    @MainActor static func main() async {
        let checks = DevDockTests()
        defer { for url in checks.temporary { try? FileManager.default.removeItem(at: url) } }
        do {
            try checks.testDiscoveryDoesNotExecuteAndSkipsDependencies()
            print("PASS discovery is read-only and bounded")
            try checks.testHospitalDiscoverySeparatesAPIsFromWeb()
            print("PASS hospital API/web discovery")
            try await checks.testCaptureDrainsLargeOutputAndTimesOut()
            print("PASS capture backpressure and timeout")
            try await checks.testForegroundStopsEntireProcessGroupAndPreservesWorkingDirectory()
            print("PASS foreground process-group cleanup and Unicode paths")
            try await checks.testDetachedLifecycleAndPIDOwnership()
            print("PASS detached lifecycle, PID ownership, config persistence")
            try await checks.testRepeatedUnitStopAndCancelledLaunch()
            print("PASS repeated per-unit stop, cancelled launch and shutdown")
            try await checks.testDetachedMissingPIDStillCleansProcessGroup()
            print("PASS failed detached launch cleans group even with missing PID file")
            try await checks.testOneProjectsPortNeverLightsAnotherProject()
            print("PASS one project never lights another project on the same port")
            try checks.testAddressFamilyAndSharedListeners()
            print("PASS IPv4/IPv6 address ownership, daemon descendants and shared sockets")
            try checks.testBoundedLogsAndANSIConversion()
            print("PASS log rotation, bounded reading and ANSI conversion")
            print("All 10 checks passed. No business project was started.")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
