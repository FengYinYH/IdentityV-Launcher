import Foundation
import AppKit
import CoreGraphics

// Transport only: every operation re-enters the same manager used by the GUI.
// A task receipt is never evidence that the underlying operation completed.
enum AgentCLI {
    static let operations = ["status", "check-runtime-prerequisites", "inspect", "resolve-location", "resolve-download", "resolve-manifest", "verify-installer", "select", "install", "import", "prepare-launch", "launch", "restart", "stop", "remove", "remove-preview", "repair"]
    static var documentationURL: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("agent-cli.md") }
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["IDENTITYV_AGENT_TASK_ROOT"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/IdentityVOnMac/AgentTasks", isDirectory: true)
    }
    static func localized(_ key: String) -> String {
        let defaults = UserDefaults(suiteName: "com.fengyin.identityv.launcher") ?? .standard
        let code = LauncherLanguage.configured(from: defaults).locale.identifier
        let resources = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        guard let bundle = Bundle(url: resources.appendingPathComponent(code + ".lproj")) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func output(_ value: Any) throws { FileHandle.standardOutput.write(try data(value)); FileHandle.standardOutput.write(Data([10])) }
    static func directory(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw failure("invalid_task_id") }
        return root.appendingPathComponent(uuid.uuidString, isDirectory: true)
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
            try output(["schemaVersion": 1, "commands": ["docs", "run <operation> [arguments]", "start <operation> [arguments]", "task <id>", "events <id>", "logs <id> stdout|stderr", "cancel <id>"], "operations": operations, "entrypoint": documentationURL.deletingLastPathComponent().appendingPathComponent("idv").path, "documentationPath": documentationURL.path, "documentationAvailable": FileManager.default.isReadableFile(atPath: documentationURL.path)]); return 0
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
        if args[1] == "remove", args.dropFirst(2).contains("--expected-removal-token") {
            throw failure("Removal confirmation token is managed internally")
        }
        let id = UUID().uuidString; let dir = try directory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try save(["schemaVersion": 1, "taskId": id, "state": "queued", "arguments": Array(args.dropFirst()), "updatedAt": Date().timeIntervalSince1970], dir)
        // An accepted task always has readable streams, even while queued or
        // waiting for confirmation; callers must not race worker startup.
        for name in ["events.jsonl", "stdout.log", "stderr.log"] {
            guard FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw failure("task_stream_creation_failed") }
        }
        if command == "run" { return try execute(dir, stream: true) }
        let worker = Process(); worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        worker.arguments = ["agent", "worker", id]
        worker.standardInput = FileHandle.nullDevice; worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        do { try worker.run() }
        catch { var record = try read(dir); record["state"] = "failed"; record["exitCode"] = 1; record["error"] = error.localizedDescription; try save(record, dir); throw error }
        try output(["schemaVersion": 1, "taskId": id, "state": "accepted"]); return 0
    }
    /// Obtain the same guarded deletion targets the core will revalidate
    /// after confirmation. Commands are not useful descriptions of user data.
    static func deletionPreview(_ arguments: [String]) throws -> [String: Any] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["remove-preview", "--json"] + Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure(String(scrub(String(decoding: bytes.suffix(65536), as: UTF8.self)).prefix(2048)))
        }
        guard let preview = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              preview["schemaVersion"] as? Int == 1,
              let token = preview["removalToken"] as? String, token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let targets = preview["targets"] as? [[String: String]], !targets.isEmpty,
              targets.allSatisfy({ $0["path"]?.hasPrefix("/") == true }) else {
            throw failure("invalid_removal_preview")
        }
        return preview
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
            if let code = record["errorCode"] { payload["errorCode"] = code }
            try event("state", payload)
        }
        let cancel = dir.appendingPathComponent("cancel-requested")
        // Signal handlers only request cancellation. The worker forwards once to its exact child.
        let oldTerm = signal(SIGTERM, SIG_IGN), oldInt = signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { DispatchSource.makeSignalSource(signal: $0, queue: .global()) }
        for source in sources { source.setEventHandler { try? Data().write(to: cancel, options: .atomic) }; source.resume() }
        defer { sources.forEach { $0.cancel() }; signal(SIGTERM, oldTerm); signal(SIGINT, oldInt) }
        if FileManager.default.fileExists(atPath: cancel.path) {
            record["exitCode"] = 130; record["cancellationRequested"] = true
            try state("cancelled"); return 130
        }
        if operation == "remove" {
            try state("awaiting_confirmation")
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any], session[kCGSessionOnConsoleKey as String] as? Bool == true else {
                record["error"] = "confirmation_unavailable"; record["exitCode"] = 1; try state("failed"); return 1
            }
            let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
            let preview: [String: Any]
            do { preview = try deletionPreview(arguments) }
            catch {
                record["errorCode"] = "removal_preview_failed"; record["error"] = error.localizedDescription
                record["exitCode"] = 1; try state("failed"); return 1
            }
            record["removalPreview"] = preview
            try save(record, dir)
            let alert = NSAlert(); alert.messageText = localized("你的 Agent 似乎在删除游戏，确认这样操作吗？")
            let resourceDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            if let icon = NSImage(contentsOf: resourceDirectory.appendingPathComponent("IdentityVLauncher.icns")) {
                alert.icon = icon
            }
            let gamePath = preview["gamePath"] as? String ?? localized("当前游戏目录不可用")
            let paths = (preview["targets"] as? [[String: String]] ?? []).compactMap { $0["path"] }
            let ownership = preview["externalGameRoot"] as? Bool == true ? "\n" + localized("外部游戏文件保留，仅清除以下受管项目。") : ""
            alert.informativeText = localized("游戏位置：") + "\n" + gamePath + ownership + "\n\n" + localized("将移入废纸篓：") + "\n" + paths.joined(separator: "\n")
            alert.addButton(withTitle: localized("取消")); alert.addButton(withTitle: localized("确认删除"))
            // The modal run loop must keep heartbeating and service API/signal
            // cancellation. Otherwise cancel writes a marker but leaves this
            // worker (and its dialog) blocked until a human clicks a button.
            var confirmationError: Error?
            let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
                record["updatedAt"] = Date().timeIntervalSince1970
                do { try save(record, dir) }
                catch { confirmationError = error; app.abortModal() }
                if FileManager.default.fileExists(atPath: cancel.path) { app.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            let response = alert.runModal()
            timer.invalidate()
            alert.window.orderOut(nil)
            if let error = confirmationError {
                record["error"] = error.localizedDescription; record["exitCode"] = 1
                try state("failed"); return 1
            }
            guard response == .alertSecondButtonReturn else {
                record["exitCode"] = 130
                record["cancellationRequested"] = FileManager.default.fileExists(atPath: cancel.path)
                try state("cancelled"); return 130
            }
        }
        if FileManager.default.fileExists(atPath: cancel.path) { record["exitCode"] = 130; record["cancellationRequested"] = true; try state("cancelled"); return 130 }
        var executionArguments = arguments
        if operation == "remove", let preview = record["removalPreview"] as? [String: Any],
           let token = preview["removalToken"] as? String {
            executionArguments += ["--expected-removal-token", token]
        }
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL; child.arguments = executionArguments
        // Files avoid pipe backpressure and preserve complete output even when caller disconnects.
        let stdoutURL = dir.appendingPathComponent("stdout.log"), stderrURL = dir.appendingPathComponent("stderr.log")
        let out = try FileHandle(forWritingTo: stdoutURL), err = try FileHandle(forWritingTo: stderrURL)
        defer { try? out.close(); try? err.close() }
        child.standardInput = FileHandle.nullDevice; child.standardOutput = out; child.standardError = err
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
        let cancelled = sentCancel && (child.terminationReason == .uncaughtSignal || (child.terminationReason == .exit && child.terminationStatus == 130))
        let code: Int32 = cancelled ? 130 : (child.terminationStatus == 0 ? 0 : 1)
        record["exitCode"] = code
        if code != 0 && !cancelled {
            record["errorCode"] = "core_operation_failed"
            // Keep a bounded, filtered summary alongside the exact child code;
            // clients should not need an extra logs call just to learn why.
            if let file = try? FileHandle(forReadingFrom: stderrURL) {
                defer { try? file.close() }
                let length = (try? file.seekToEnd()) ?? 0
                try? file.seek(toOffset: length > 65536 ? length - 65536 : 0)
                let tail = scrub(String(decoding: file.readDataToEndOfFile(), as: UTF8.self))
                let summary = tail.split(separator: "\n").last.map(String.init) ?? "Core operation failed"
                record["error"] = String(summary.prefix(2048))
            }
        }
        if let size = try? stdoutURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
           let bytes = try? Data(contentsOf: stdoutURL), let result = try? JSONSerialization.jsonObject(with: bytes) { record["output"] = result }
        // A cleanup error after a cancellation request remains failed; don't claim rollback completed.
        try state(cancelled ? "cancelled" : (code == 0 ? "succeeded" : "failed"))
        try event("result", ["exitCode": code, "childExitCode": child.terminationStatus, "stdoutPath": stdoutURL.path, "stderrPath": stderrURL.path])
        return code
    }
}
