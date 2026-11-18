import Foundation
import AppKit
import SwiftUI

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

    func testSoftwareUpdate() throws {
        let digest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        func release(_ tag: String, asset: String = SoftwareUpdate.archiveName, hash: String = digest) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tag_name": tag, "assets": [["name": asset, "digest": hash]]])
        }
        let metadata = try release("v0.10.0")
        let update = try unwrap(SoftwareUpdate.available(in: metadata, current: "0.2.9"))
        try equal(update.downloadURL.absoluteString, "https://github.com/xieyuqiyu-source/DevDock/releases/download/v0.10.0/DevDock-macOS-universal.zip")
        try expectNil(try SoftwareUpdate.available(in: metadata, current: "0.10.0"))
        try expectNil(try SoftwareUpdate.available(in: metadata, current: "1.0.0"))
        for invalid in [try release("v0.3.0-beta"), try release("../latest"), try release("v0.3.0", asset: "source.zip"), try release("v0.3.0", hash: "")] {
            do {
                _ = try SoftwareUpdate.available(in: invalid, current: "0.2.0")
            } catch { continue }
            throw AppError.message("Invalid release accepted")
        }
        let root = try temp()
        let source = root.appendingPathComponent("temporary")
        let target = root.appendingPathComponent("DevDock.zip")
        try Data("abc".utf8).write(to: source)
        try update.saveVerified(source, to: target)
        try equal(try Data(contentsOf: target), Data("abc".utf8))
        try expectNotNil(try target.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        let previous = Data("previous download".utf8)
        try previous.write(to: target)
        try Data("incomplete".utf8).write(to: source)
        do {
            try update.saveVerified(source, to: target)
            try expect(false, "Corrupt download accepted")
        } catch AppError.message(let message) where message.contains("校验失败") {}
        try equal(try Data(contentsOf: target), previous)
        try Data("abc".utf8).write(to: source)
        try update.saveVerified(source, to: target)
        try equal(try Data(contentsOf: target), Data("abc".utf8))
    }

    func testOrderingAndBrowserEndpoints() throws {
        let root = try temp()
        let store = ProjectStore(support: root, seed: false, monitor: false)
        let projects = ["A", "B", "C"].map { Project(name: $0, path: "/tmp", units: [LaunchUnit(name: "web", command: "true")]) }
        store.projects = projects
        store.moveProjects(from: IndexSet(integer: 2), to: 0)
        try equal(store.projects.map(\.name), ["C", "A", "B"])
        store.moveProjects(from: IndexSet(integer: 0), to: 3)
        try equal(store.projects, projects)
        store.moveProjects(from: IndexSet([0, 2]), to: 3)
        try equal(store.projects.map(\.name), ["B", "A", "C"])
        let restored = ProjectStore(support: root, seed: false, monitor: false)
        try equal(restored.projects, store.projects)
        let previous = store.projects
        try FileManager.default.removeItem(at: store.configURL)
        try FileManager.default.createDirectory(at: store.configURL, withIntermediateDirectories: true)
        store.moveProjects(from: IndexSet(integer: 0), to: 3)
        try equal(store.projects, previous)
        try expectNotNil(store.error)
        let web = Endpoint(name: "前端", url: "http://localhost:5173/app", healthURL: "http://localhost:5173")
        let occupied = Endpoint(name: "外部", url: "http://localhost:9999", healthURL: "http://localhost:9999")
        let remote = Endpoint(name: "非本地", url: "https://example.com", healthURL: "https://example.com")
        let duplicate = Endpoint(name: "重复", url: web.url, healthURL: web.url)
        let ipv6 = Endpoint(name: "IPv6", url: "http://[::1]:5174", healthURL: "http://[::1]:5174")
        store.discoveredEndpoints[projects[0].units[0].id] = [web, occupied, remote, duplicate, ipv6]
        store.endpointStates = [web.id: .ready, occupied.id: .occupied(123), remote.id: .ready, duplicate.id: .listening, ipv6.id: .listening]
        try equal(store.browserEndpoints(projects[0]).map(\.id), [web.id, ipv6.id])
        store.endpointStates = [:]
        try expect(store.browserEndpoints(projects[0]).isEmpty)
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
        let apiOnly = try unwrap(Discovery.project(at: root))
        try equal(apiOnly.units.count, 2)
        try apiOnly.validate()
        let admin = root.appendingPathComponent("apps/hospital-admin")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try #"{"scripts":{"dev":"vite"}}"#.write(to: admin.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let project = try unwrap(Discovery.project(at: root))
        try equal(project.units.count, 3)
        try expect(project.units[0].detached)
        try equal(project.units[1].command, "./go-start start-bg admin")
        try expectFalse(project.units[2].detached)
        try expect(project.units[2].command.contains("--strictPort"))
        let ot = root.appendingPathComponent("apps/ot-demo-h5")
        try FileManager.default.createDirectory(at: ot, withIntermediateDirectories: true)
        try #"{"scripts":{"dev":"vite"}}"#.write(to: ot.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let withOT = try unwrap(Discovery.project(at: root))
        try equal(withOT.units.count, 4)
        try equal(withOT.enabledUnits.count, 3)
        try expectFalse(withOT.units[3].enabled)
        try withOT.validate()
    }

    func testDiscoveryPreservesScriptsAndPackageManagers() throws {
        let root = try temp()
        let package = root.appendingPathComponent("package.json")
        try #"{"scripts":{"build":"vite build"}}"#.write(to: package, atomically: true, encoding: .utf8)
        try expectNil(Discovery.project(at: root))
        try #"{"scripts":{"dev":"  "}}"#.write(to: package, atomically: true, encoding: .utf8)
        try expectNil(Discovery.project(at: root))
        try #"{"scripts":{"dev":"vite"}}"#.write(to: package, atomically: true, encoding: .utf8)
        try equal(Discovery.project(at: root)?.units.first?.command, "npm run dev")
        try "lockfileVersion: 9".write(to: root.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        try equal(Discovery.project(at: root)?.units.first?.command, "pnpm dev")
        try "module example".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "fastapi".write(to: root.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        try "echo launch".write(to: root.appendingPathComponent("dev.sh"), atomically: true, encoding: .utf8)
        try equal(Discovery.project(at: root)?.units.first?.command, "./dev.sh")
        try "echo launch".write(to: root.appendingPathComponent("dev"), atomically: true, encoding: .utf8)
        try equal(Discovery.project(at: root)?.units.first?.command, "./dev")
        let nested = root.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "echo nested".write(to: nested.appendingPathComponent("dev"), atomically: true, encoding: .utf8)
        try equal(Discovery.scan(root).count, 1)

        let python = try temp()
        try "fastapi".write(to: python.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        try expectNil(Discovery.project(at: python))
        try "print('hello')".write(to: python.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        try equal(Discovery.project(at: python)?.units.first?.command, "python main.py")
        try "echo launch".write(to: python.appendingPathComponent("dev"), atomically: true, encoding: .utf8)
        try equal(Discovery.project(at: python)?.units.first?.command, "./dev")
    }

    func testModernButtonsHaveFinitePressedColors() throws {
        for variant: ModernButtonStyle.Variant in [.primary, .secondary, .ghost, .danger] {
            let style = ModernButtonStyle(variant: variant)
            try equal(style.foregroundColor(isPressed: true), style.foregroundColor(isPressed: false).opacity(0.8))
        }
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

    func testExternalProjectIsNotDuplicatedAndCanRestart() async throws {
        let root = try temp()
        let otherRoot = try temp()
        let server = """
        import os
        from http.server import HTTPServer, BaseHTTPRequestHandler
        from pathlib import Path
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
        port = Path('port')
        server = HTTPServer(('127.0.0.1', int(port.read_text()) if port.exists() else 0), Handler)
        Path('listener.pid').write_text(str(os.getpid()))
        port.write_text(str(server.server_port))
        server.serve_forever()
        """
        for directory in [root, otherRoot] {
            let dev = directory.appendingPathComponent("dev")
            try "#!/bin/bash\necho start >> launches\n/usr/bin/python3 serve.py &\nwait $!\n".write(to: dev, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dev.path)
            try server.write(to: directory.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
        }
        let environment = ProcessInfo.processInfo.environment
        let outside = try RunningCommand(command: "./dev", directory: root.path, environment: environment,
            logURL: root.appendingPathComponent("outside.log"), helperURL: helper)
        let other = try RunningCommand(command: "./dev", directory: otherRoot.path, environment: environment,
            logURL: otherRoot.appendingPathComponent("outside.log"), helperURL: helper)
        var store = ProjectStore(support: root.appendingPathComponent("support"), helperURL: helper, seed: false, monitor: false)
        do {
            let portFile = root.appendingPathComponent("port")
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: portFile.path) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let port = try String(contentsOf: portFile, encoding: .utf8)
            let oldListener = try unwrap(Int32(String(contentsOf: root.appendingPathComponent("listener.pid"), encoding: .utf8)))
            let url = "http://127.0.0.1:" + port
            let endpoint = Endpoint(name: "Web", url: url, healthURL: url)
            let project = Project(name: "已在终端启动", path: root.path, units: [LaunchUnit(name: "Web", command: "./dev", endpoints: [endpoint])])
            try store.update(project)
            store.launch(project)
            try await waitUntilIdle(store, project)
            try equal(store.status(project), "外部运行")
            try equal(store.browserEndpoints(project), [endpoint])
            try equal(store.displayedServices(project.units[0]).first?.pids, [oldListener])
            try equal(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8), "start\n")

            await store.shutdown()
            try expectFalse(outside.exited)
            store = ProjectStore(support: store.support, helperURL: helper, seed: false, monitor: false)
            await store.refresh()
            try equal(store.status(project), "外部运行")
            store.stop(project, restart: true)
            try await waitUntilIdle(store, project)
            try expectNil(store.notices[project.id])
            try expect(outside.exited)
            try expectNil(ProcessIdentity(oldListener))
            try expect(!other.exited, "An identically named launcher in a different directory must survive")
            try equal(store.status(project), "已就绪")
            try equal(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8), "start\nstart\n")

            store.stop(project)
            try await waitUntilIdle(store, project)
            try equal(store.status(project), "已停止")
            try equal(store.displayedServices(project.units[0]).first?.pids, [])
            try expectFalse(other.exited)
        } catch {
            await store.shutdown()
            await outside.stop()
            await other.stop()
            throw error
        }
        await outside.stop()
        await other.stop()
    }

    func testAlternateLaunchersAreObservedWithoutTakingOver() async throws {
        let root = try temp()
        let frontend = root.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: frontend, withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch launched-by-devdock\nexec /bin/sleep 60\n".write(to: root.appendingPathComponent("dev"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("dev").path)
        try """
        import os
        from http.server import HTTPServer, SimpleHTTPRequestHandler
        from pathlib import Path
        server = HTTPServer(('127.0.0.1', 0), SimpleHTTPRequestHandler)
        Path('port').write_text(str(server.server_port))
        Path('listener.pid').write_text(str(os.getpid()))
        server.serve_forever()
        """.write(to: frontend.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
        let outside = try RunningCommand(command: "/usr/bin/python3 serve.py", directory: frontend.path,
            environment: ProcessInfo.processInfo.environment, logURL: root.appendingPathComponent("outside.log"), helperURL: helper)
        let unit = LaunchUnit(name: "项目", command: "./dev")
        let project = Project(name: "其他方式启动", path: root.path, units: [unit])
        let support = root.appendingPathComponent("support")
        let store = ProjectStore(support: support, helperURL: helper, seed: false, monitor: false)
        do {
            try store.update(project)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: frontend.appendingPathComponent("listener.pid").path) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let port = try String(contentsOf: frontend.appendingPathComponent("port"), encoding: .utf8)
            let pid = try unwrap(Int32(String(contentsOf: frontend.appendingPathComponent("listener.pid"), encoding: .utf8)))
            await store.refresh()
            try equal(store.status(project), "外部监听")
            try equal(store.browserEndpoints(project).map(\.url), ["http://127.0.0.1:" + port])
            try equal(store.displayedServices(unit).first?.pids, [pid])
            try expectFalse(store.canStop(unit))
            try expectFalse(store.canRestart(project))
            store.launch(project)
            try await waitUntilIdle(store, project)
            try expectNil(store.notices[project.id])
            try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched-by-devdock").path))
            store.stop(project, restart: true)
            try await waitUntilIdle(store, project)
            try expectNotNil(store.notices[project.id])
            try expectFalse(outside.exited)
            try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched-by-devdock").path))
            await store.shutdown()
            try expectFalse(outside.exited)

            let restored = ProjectStore(support: support, helperURL: helper, seed: false, monitor: false)
            await restored.refresh()
            try equal(restored.status(project), "外部监听")
            let nested = Project(name: "嵌套项目", path: frontend.path, units: [LaunchUnit(name: "项目", command: "./dev")])
            try restored.update(nested)
            await restored.refresh()
            try expectFalse(restored.isActive(project))
            try expect(restored.browserEndpoints(project).isEmpty)
            try equal(restored.status(nested), "外部监听")
            let duplicate = Project(name: "共享目录", path: frontend.path, units: [LaunchUnit(name: "其他命令", command: "true")])
            try restored.update(duplicate)
            await restored.refresh()
            try expectFalse(restored.isActive(nested))
            try expectFalse(restored.isActive(duplicate))
            restored.remove(duplicate)
            await restored.refresh()
            try equal(restored.status(nested), "外部监听")
            await outside.stop()
            await restored.refresh()
            try expectFalse(restored.isActive(nested))
            try expect(restored.browserEndpoints(nested).isEmpty)
        } catch {
            await outside.stop()
            throw error
        }
    }

    func testExternalDiscoveryExcludesTestRunnersAndOtherDirectories() async throws {
        let root = try temp()
        try """
        import socket
        from pathlib import Path
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        Path('port').write_text(str(listener.getsockname()[1]))
        import time
        time.sleep(60)
        """.write(to: root.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
        let outside = try RunningCommand(command: "/usr/bin/python3 serve.py -test.v", directory: root.path,
            environment: ProcessInfo.processInfo.environment, logURL: root.appendingPathComponent("outside.log"), helperURL: helper)
        do {
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("port").path) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let project = Project(name: "测试项目", path: root.path, units: [LaunchUnit(name: "项目", command: "./dev")])
            let unit = project.units[0]
            var snapshot = try unwrap(await System.processSnapshot())
            try expect(snapshot.externalListeners(project, unit, projects: [project], excluding: []).isEmpty)
            let port = try String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8)
            let pid = try unwrap(snapshot.listeners.first { $0.port == Int(port) }?.pid)
            let row = try unwrap(snapshot.processes[pid])
            snapshot.processes[pid] = .init(parent: row.parent, group: row.group, command: "/usr/bin/python3 serve.py")
            try equal(snapshot.externalListeners(project, unit, projects: [project], excluding: []).map(\.pid), [pid])
            try expect(snapshot.externalListeners(project, unit, projects: [project], excluding: [pid]).isEmpty)
            let neighbor = Project(name: "其他目录", path: String(root.path.dropLast()), units: [unit])
            try expect(snapshot.externalListeners(neighbor, unit, projects: [neighbor], excluding: []).isEmpty)
            snapshot.processes[pid] = .init(parent: row.parent, group: row.group, command: "/usr/local/go/bin/go test ./server")
            try expect(snapshot.externalListeners(project, unit, projects: [project], excluding: []).isEmpty)
        } catch {
            await outside.stop()
            throw error
        }
        await outside.stop()
    }

    func testExternalDaemonUsesConfiguredStop() async throws {
        let root = try temp()
        let unit = LaunchUnit(name: "后台服务", command: "nohup /bin/sleep 60 </dev/null >/dev/null 2>&1 & echo $! > daemon.pid",
            stopCommand: "kill -TERM \"$(cat daemon.pid)\" && echo stopped > stop-called", pidFile: "daemon.pid", executable: "/bin/sleep", detached: true)
        let project = Project(name: "外部后台服务", path: root.path, units: [unit])
        let outside = try RunningCommand(command: unit.command, directory: root.path, environment: ProcessInfo.processInfo.environment,
            logURL: root.appendingPathComponent("outside.log"), helperURL: helper)
        let store = ProjectStore(support: root.appendingPathComponent("support"), helperURL: helper, seed: false, monitor: false)
        do {
            try store.update(project)
            for _ in 0..<100 where System.ownedPID(project: project, unit: unit) == nil {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let daemon = try unwrap(System.ownedPID(project: project, unit: unit))
            await store.refresh()
            try equal(store.status(project), "外部运行")
            store.stop(project)
            try await waitUntilIdle(store, project)
            try expectNil(store.notices[project.id])
            try expectNil(ProcessIdentity(daemon))
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("stop-called").path))
            try equal(store.status(project), "已停止")
        } catch {
            await outside.stop()
            throw error
        }
        await outside.stop()
    }

    func testAutoGameExecReplacementKeepsGracefulShutdown() async throws {
        let root = try temp()
        let files = FileManager.default
        let scripts = root.appendingPathComponent("scripts")
        let bin = root.appendingPathComponent(".venv/bin")
        try files.createDirectory(at: scripts, withIntermediateDirectories: true)
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: python, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        let dev = root.appendingPathComponent("dev")
        try "#!/bin/bash\nexec bash ./scripts/serve.sh\n".write(to: dev, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dev.path)
        try "exec .venv/bin/python scripts/dev.py\n".write(to: scripts.appendingPathComponent("serve.sh"), atomically: true, encoding: .utf8)
        let program = """
        import os, signal, socket, subprocess, sys, time
        from pathlib import Path
        # Fixture for the AUTO_GAME_DATA supervisor that also runs server-feed/main.py.
        if sys.argv[1:] == ['--web']:
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            Path('port').write_text(str(listener.getsockname()[1]))
            signal.pause()
        elif sys.argv[1:] == ['--supervise']:
            signal.signal(signal.SIGTERM, lambda *_: Path('direct-signal').touch())
            worker = subprocess.Popen([sys.executable, __file__, '--web'], start_new_session=True)
            sys.stdin.read()
            time.sleep(2.5)
            worker.terminate()
            worker.wait()
            Path('cleanup-finished').touch()
        else:
            with Path('launches').open('a') as f:
                f.write('start\\n')
            def stop(*_):
                global stopping
                stopping = True
            stopping = False
            signal.signal(signal.SIGTERM, stop)
            supervisor = subprocess.Popen([sys.executable, os.path.abspath(__file__), '--supervise'],
                                          stdin=subprocess.PIPE, start_new_session=True)
            while supervisor.poll() is None:
                if stopping:
                    supervisor.stdin.close()
                time.sleep(.05)
        """
        try program.write(to: scripts.appendingPathComponent("dev.py"), atomically: true, encoding: .utf8)
        let outside = try RunningCommand(command: "./dev", directory: root.path, environment: ProcessInfo.processInfo.environment,
            logURL: root.appendingPathComponent("outside.log"), helperURL: helper)
        let store = ProjectStore(support: root.appendingPathComponent("support"), helperURL: helper, seed: false, monitor: false)
        let project = Project(name: "Auto Game fixture", path: root.path, units: [LaunchUnit(name: "项目", command: "./dev")])
        do {
            let portFile = root.appendingPathComponent("port")
            for _ in 0..<100 where !files.fileExists(atPath: portFile.path) {
                if outside.exited { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try expect(files.fileExists(atPath: portFile.path), tailText(outside.sink.url, bytes: 2048))
            let port = try String(contentsOf: portFile, encoding: .utf8)
            try store.update(project)
            store.launch(project)
            try await waitUntilIdle(store, project)
            try equal(store.status(project), "外部运行")
            try equal(store.browserEndpoints(project).map(\.url), ["http://127.0.0.1:" + port])
            try equal(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8), "start\n")
            store.stop(project)
            try await waitUntilIdle(store, project)
            try expect(outside.exited)
            try expect(files.fileExists(atPath: root.appendingPathComponent("cleanup-finished").path))
            try expectFalse(files.fileExists(atPath: root.appendingPathComponent("direct-signal").path))
            try equal(store.status(project), "已停止")
        } catch {
            await store.shutdown()
            await outside.stop()
            throw error
        }
    }

    private func waitUntilIdle(_ store: ProjectStore, _ project: Project) async throws {
        for _ in 0..<150 where store.busy.contains(project.id) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expectFalse(store.busy.contains(project.id))
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

    func testServiceRolesUseOwnedListeners() throws {
        let snapshot = ProcessSnapshot(processOutput: """
        101 100 100 /opt/bin/node /tmp/example/node_modules/vite/bin/vite.js --port 4173
        102 100 100 /usr/bin/python3 -m uvicorn example:app
        103 100 100 node server.js --description vite
        200 1 200 /usr/bin/python3 -m uvicorn unrelated:app
        """, listenerOutput: """
        p101
        cnode
        tIPv4
        n127.0.0.1:4173
        n127.0.0.1:4174
        p102
        cPython
        tIPv4
        n127.0.0.1:8000
        p103
        cnode
        tIPv4
        n127.0.0.1:5173
        p200
        cPython
        tIPv4
        n127.0.0.1:8001
        """)
        func endpoint(_ name: String, _ port: Int) -> Endpoint {
            let url = "http://127.0.0.1:\(port)"
            return Endpoint(name: name, url: url, healthURL: url)
        }
        let web = endpoint("node", 4173)
        let secondAddress = endpoint("node", 4174)
        let api = endpoint("Python", 8000)
        let unknown = endpoint("node", 5173)
        let owned: Set<Int32> = [101, 102, 103]
        let discovered = [web, secondAddress, api, unknown]
        let activity = Dictionary(uniqueKeysWithValues: try discovered.map { ($0.id, try unwrap(snapshot.activity(for: $0, owned: owned))) })
        let groups = ServiceGroup.group(configured: [], discovered: discovered, activity: activity)
        try equal(groups.map(\.role), [.frontend, .backend, .unclassified])
        try equal(groups.map(\.pids), [[101], [102], [103]])
        try equal(groups[0].endpoints, [web, secondAddress])
        try expectNil(snapshot.activity(for: endpoint("API", 8001), owned: owned))

        let oldConfiguration = #"{"id":"original","name":"Go API","url":"http://127.0.0.1:5173","healthURL":"http://127.0.0.1:5173"}"#
        var configured = try JSONDecoder().decode(Endpoint.self, from: Data(oldConfiguration.utf8))
        try expectNil(configured.role)
        try equal(ServiceGroup.group(configured: [configured], discovered: [], activity: [:]).first?.role, .backend)
        configured.role = .frontend
        try equal(ServiceGroup.group(configured: [configured], discovered: [], activity: [:]).first?.role, .frontend)

        var frontend = web
        frontend.name = "前端页面"
        var backend = secondAddress
        backend.name = "管理 API"
        let shared = ServiceGroup.group(configured: [frontend, backend], discovered: [], activity: activity)
        try equal(shared.count, 1)
        try equal(shared.first?.role, .unclassified)
        try equal(shared.first?.pids, [101])
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
            try checks.testSoftwareUpdate()
            print("PASS release selection, verified download, quarantine and safe replacement")
            try checks.testOrderingAndBrowserEndpoints()
            print("PASS project ordering, persistence rollback and browser endpoint filtering")
            try checks.testDiscoveryDoesNotExecuteAndSkipsDependencies()
            print("PASS discovery is read-only and bounded")
            try checks.testHospitalDiscoverySeparatesAPIsFromWeb()
            print("PASS hospital API/web discovery")
            try checks.testDiscoveryPreservesScriptsAndPackageManagers()
            print("PASS script priority, npm/pnpm detection, and nested-project deduplication")
            try checks.testModernButtonsHaveFinitePressedColors()
            print("PASS all modern button colors when pressed")
            try await checks.testCaptureDrainsLargeOutputAndTimesOut()
            print("PASS capture backpressure and timeout")
            try await checks.testForegroundStopsEntireProcessGroupAndPreservesWorkingDirectory()
            print("PASS foreground process-group cleanup and Unicode paths")
            try await checks.testExternalProjectIsNotDuplicatedAndCanRestart()
            print("PASS external project recognition, deduplication and restart")
            try await checks.testAlternateLaunchersAreObservedWithoutTakingOver()
            print("PASS alternate launchers, nested ownership, deduplication, and observation-only shutdown")
            try await checks.testExternalDiscoveryExcludesTestRunnersAndOtherDirectories()
            print("PASS test-runner, managed-listener, and directory-boundary exclusions")
            try await checks.testExternalDaemonUsesConfiguredStop()
            print("PASS external daemon uses the verified stop command")
            try await checks.testAutoGameExecReplacementKeepsGracefulShutdown()
            print("PASS Auto Game exec replacement, port discovery, and supervised shutdown")
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
            try checks.testServiceRolesUseOwnedListeners()
            print("PASS frontend/backend roles, verified listener PIDs, and grouping")
            try checks.testBoundedLogsAndANSIConversion()
            print("PASS log rotation, bounded reading and ANSI conversion")
            print("All 20 checks passed. No business project was started.")
        } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
