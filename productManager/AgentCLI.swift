import Foundation
import AppKit
import CoreGraphics

// Transport only: every operation re-enters the same manager used by the GUI.
// A task receipt is never evidence that the underlying operation completed.
enum AgentCLI {
    static let operations = ["status", "check-runtime-prerequisites", "inspect", "resolve-download", "resolve-manifest", "verify-installer", "select", "install", "import", "prepare-launch", "launch", "restart", "stop", "remove", "repair"]
    static var documentationURL: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("agent-cli.md") }
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["IDENTITYV_AGENT_TASK_ROOT"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/IdentityVOnMac/AgentTasks", isDirectory: true)
    }
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func output(_ value: Any) throws { FileHandle.standardOutput.write(try data(value)); FileHandle.standardOutput.write(Data([10])) }
    static func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw failure("invalid_task_id") }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "IdentityVAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func scrub(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"(?s)-----BEGIN [^-]*(?:PRIVATE KEY|CERTIFICATE)-----.*?(?:-----END [^-]+-----|$)"#, with: "<redacted secret block>", options: .regularExpression)
        value = value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "<HOME>")
        for pattern in [#"(?i)(https?://)[^/\s<>]+@"#, #"(?i)(https?://[^\s'\"<>?#]+)[?#][^\s'\"<>]*"#] {
            value = value.replacingOccurrences(of: pattern, with: "$1<redacted>", options: .regularExpression)
        }
        // Keep phase/error context when a diagnostic and a credential share one line.
        value = value.replacingOccurrences(of: #"(?im)(\b(?:cookie|set-cookie|authorization)\s*:\s*).*$"#, with: "$1<SECRET>", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)(\b(?:token|cookie|authorization|session(?:[_-]?id)?|secret|password|passphrase|private[_ -]?key|credential|api[_ -]?key|csrf|signature|jwt|access[_ -]?token)[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\\r\n])*\"|'(?:\\.|[^'\\\r\n])*'|(?:Bearer|Basic)\s+[^\s,;]+|[^\s,;}\]]+)"#, with: "$1<SECRET>", options: .regularExpression)
        return value.replacingOccurrences(of: #"(?i)\bBearer\s+[^\s,;]+|idvlogin://[^\s\"'<>]+|\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,})"#, with: "<SECRET>", options: .regularExpression)
    }
    static func read(_ dir: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("task.json"))) as? [String: Any] else { throw failure("invalid_task_record") }
        return value
    }
    static func save(_ value: [String: Any], _ dir: URL) throws { try data(value).write(to: dir.appendingPathComponent("task.json"), options: .atomic) }
    static func main(_ args: [String]) -> Int32 {
        do { return try dispatch(args) }
        catch { try? output(["schemaVersion": 1, "error": "agent_command_failed", "message": error.localizedDescription]); return 1 }
    }
    static func dispatch(_ args: [String]) throws -> Int32 {
        guard let command = args.first else { throw failure("Use agent help") }
        if command == "docs" {
            try output(["schemaVersion": 1, "format": "markdown", "text": String(contentsOf: documentationURL, encoding: .utf8)]); return 0
        }
        if command == "help" {
            try output(["schemaVersion": 1, "commands": ["docs", "run <operation> [arguments]", "start <operation> [arguments]", "task <id>", "events <id>", "logs <id> stdout|stderr", "cancel <id>"], "operations": operations, "documentationPath": documentationURL.path, "documentationAvailable": FileManager.default.isReadableFile(atPath: documentationURL.path)]); return 0
        }
        if command == "logs" {
            guard args.count == 3, ["stdout", "stderr"].contains(args[2]) else { throw failure("Expected logs <id> stdout|stderr") }
            let dir = try directory(args[1]); _ = try read(dir)
            let file = try FileHandle(forReadingFrom: dir.appendingPathComponent(args[2] + ".log")); defer { try? file.close() }
            let length = try file.seekToEnd(); try file.seek(toOffset: length > 65536 ? length - 65536 : 0)
            try output(["schemaVersion": 1, "taskId": args[1], "stream": args[2], "truncated": length > 65536, "text": scrub(String(decoding: file.readDataToEndOfFile(), as: UTF8.self))]); return 0
        }
        if ["task", "events", "cancel"].contains(command) {
            guard args.count == 2 else { throw failure("Expected task UUID") }
            let dir = try directory(args[1]); var record = try read(dir)
            if command == "events" {
                FileHandle.standardOutput.write(try Data(contentsOf: dir.appendingPathComponent("events.jsonl"))); return 0
            }
            if command == "cancel" {
                if ["queued", "running", "awaiting_confirmation"].contains(record["state"] as? String ?? "") {
                    try Data().write(to: dir.appendingPathComponent("cancel-requested"), options: .atomic)
                }
                record["cancellationRequested"] = FileManager.default.fileExists(atPath: dir.appendingPathComponent("cancel-requested").path)
                // Only the task worker writes task.json. Cancel is a request, not a terminal result.
            }
            if ["queued", "running", "awaiting_confirmation"].contains(record["state"] as? String ?? ""),
               let updated = record["updatedAt"] as? Double, Date().timeIntervalSince1970 - updated > 30 {
                record["observedState"] = "unknown" // sleep/crash/kill: never invent success or signal a recycled PID.
            }
            try output(record); return 0
        }
        if command == "worker" {
            guard args.count == 2 else { throw failure("Expected task UUID") }
            // A background receipt must outlive the caller's terminal session.
            // Foundation may already spawn a process-group leader (setsid then returns EPERM).
            // Ignore hangup in either case; all three stdio streams are detached by start.
            signal(SIGHUP, SIG_IGN)
            _ = setsid()
            return try execute(try directory(args[1]), stream: false)
        }
        guard ["run", "start"].contains(command), args.count >= 2, operations.contains(args[1]) else { throw failure("Unsupported agent command; use agent help") }
        let id = UUID().uuidString; let dir = try directory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try save(["schemaVersion": 1, "taskId": id, "state": "queued", "arguments": Array(args.dropFirst()), "updatedAt": Date().timeIntervalSince1970], dir)
        _ = FileManager.default.createFile(atPath: dir.appendingPathComponent("events.jsonl").path, contents: nil)
        if command == "run" { return try execute(dir, stream: true) }
        let worker = Process(); worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        worker.arguments = ["agent", "worker", id]
        worker.standardInput = FileHandle.nullDevice; worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        do { try worker.run() }
        catch { var record = try read(dir); record["state"] = "failed"; record["exitCode"] = 1; record["error"] = error.localizedDescription; try save(record, dir); throw error }
        try output(["schemaVersion": 1, "taskId": id, "state": "accepted"]); return 0
    }
    static func execute(_ dir: URL, stream: Bool) throws -> Int32 {
        var record = try read(dir)
        guard record["state"] as? String == "queued", let arguments = record["arguments"] as? [String], let operation = arguments.first, operations.contains(operation) else { throw failure("Task is not queued") }
        // Atomic exclusive claim prevents a repeated worker command from executing an operation twice.
        let claim = dir.appendingPathComponent("worker.lock")
        guard mkdir(claim.path, 0o700) == 0 else { throw failure("Task worker already claimed or task directory unavailable") }
        let events = try FileHandle(forWritingTo: dir.appendingPathComponent("events.jsonl")); defer { try? events.close() }
        var sequence = 0
        func event(_ kind: String, _ payload: [String: Any] = [:]) throws {
            sequence += 1
            var value = payload; value["schemaVersion"] = 1; value["taskId"] = record["taskId"]; value["sequence"] = sequence; value["event"] = kind; value["timestamp"] = Date().timeIntervalSince1970
            let bytes = try data(value) + Data([10]); events.write(bytes)
            if stream { FileHandle.standardOutput.write(bytes) }
        }
        func state(_ value: String) throws {
            record["state"] = value; record["updatedAt"] = Date().timeIntervalSince1970
            try save(record, dir)
            var payload: [String: Any] = ["state": value]
            if let code = record["exitCode"] { payload["exitCode"] = code }
            if let error = record["error"] { payload["error"] = error }
            try event("state", payload)
        }
        let cancel = dir.appendingPathComponent("cancel-requested")
        if operation == "remove" {
            try state("awaiting_confirmation")
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any], session[kCGSessionOnConsoleKey as String] as? Bool == true else {
                record["error"] = "confirmation_unavailable"; record["exitCode"] = 1; try state("failed"); return 1
            }
            let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = "你的 Agent 似乎在删除游戏，确认这样操作吗？"
            alert.informativeText = arguments.joined(separator: " "); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "确认删除")
            guard alert.runModal() == .alertSecondButtonReturn else { record["exitCode"] = 130; try state("cancelled"); return 130 }
        }
        if FileManager.default.fileExists(atPath: cancel.path) { record["exitCode"] = 130; try state("cancelled"); return 130 }
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL; child.arguments = arguments
        // Files avoid pipe backpressure and preserve complete output even when caller disconnects.
        let stdoutURL = dir.appendingPathComponent("stdout.log"), stderrURL = dir.appendingPathComponent("stderr.log")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil); _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdoutURL), err = try FileHandle(forWritingTo: stderrURL)
        defer { try? out.close(); try? err.close() }
        child.standardInput = FileHandle.nullDevice; child.standardOutput = out; child.standardError = err
        // Signal handlers only request cancellation. The worker forwards once to its exact child.
        let oldTerm = signal(SIGTERM, SIG_IGN), oldInt = signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { DispatchSource.makeSignalSource(signal: $0, queue: .global()) }
        for source in sources { source.setEventHandler { try? Data().write(to: cancel, options: .atomic) }; source.resume() }
        defer { sources.forEach { $0.cancel() }; signal(SIGTERM, oldTerm); signal(SIGINT, oldInt) }
        do { try child.run() } catch { record["error"] = error.localizedDescription; record["exitCode"] = 1; try state("failed"); return 1 }
        try state("running")
        let reader = try FileHandle(forReadingFrom: stderrURL); defer { try? reader.close() }
        var buffer = Data(), sentCancel = false
        func progress() throws {
            buffer.append(reader.readDataToEndOfFile())
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if let payload = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { try event("progress", ["payload": payload]) }
            }
            // Plain diagnostics may have no newline; raw bytes remain in stderr.log.
            if buffer.count > 1_048_576 { buffer.removeAll(keepingCapacity: false) }
        }
        while child.isRunning {
            try progress()
            if !sentCancel && FileManager.default.fileExists(atPath: cancel.path) { sentCancel = true; child.terminate(); try event("cancellation_requested") }
            record["updatedAt"] = Date().timeIntervalSince1970; try save(record, dir)
            Thread.sleep(forTimeInterval: 0.2)
        }
        child.waitUntilExit(); try progress()
        record["cancellationRequested"] = sentCancel
        record["childExitCode"] = child.terminationStatus
        let cancelled = child.terminationReason == .uncaughtSignal && sentCancel
        let code: Int32 = cancelled ? 130 : (child.terminationStatus == 0 ? 0 : 1)
        record["exitCode"] = code
        if let size = try? stdoutURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
           let bytes = try? Data(contentsOf: stdoutURL), let result = try? JSONSerialization.jsonObject(with: bytes) { record["output"] = result }
        // A cleanup error after a cancellation request remains failed; don't claim rollback completed.
        try state(cancelled ? "cancelled" : (code == 0 ? "succeeded" : "failed"))
        try event("result", ["exitCode": code, "childExitCode": child.terminationStatus, "stdoutPath": stdoutURL.path, "stderrPath": stderrURL.path])
        return code
    }
}
