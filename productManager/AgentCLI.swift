import Foundation
import AppKit
import CoreGraphics
import Darwin

// Transport only: every operation re-enters the same manager used by the GUI.
// A task receipt is never evidence that the underlying operation completed.
enum AgentCLI {
    static let operations = ["status", "check-runtime-prerequisites", "inspect", "resolve-location", "resolve-download", "resolve-manifest", "verify-installer", "select", "install", "import", "prepare-launch", "launch", "restart", "stop", "remove", "remove-preview", "repair", "launcher-update-check", "launcher-update-install", "login-admin-open", "language-get", "language-set", "login-follow-get", "login-follow-set", "login-stop", "login-start", "feedback-draft", "login-install"]
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
            try output(["schemaVersion": 1, "commands": ["docs", "run <operation> [arguments]", "start <operation> [arguments]", "task <id>", "events <id>", "logs <id> stdout|stderr", "cancel <id>", "pause <id>", "resume <id>"], "operations": operations, "entrypoint": documentationURL.deletingLastPathComponent().appendingPathComponent("idv").path, "documentationPath": documentationURL.path, "documentationAvailable": FileManager.default.isReadableFile(atPath: documentationURL.path)]); return 0
        }
        if command == "logs" {
            guard args.count == 3, ["stdout", "stderr"].contains(args[2]) else { throw failure("Expected logs <id> stdout|stderr") }
            let dir = try directory(args[1]); _ = try read(dir)
            let file = try FileHandle(forReadingFrom: dir.appendingPathComponent(args[2] + ".log")); defer { try? file.close() }
            let length = try file.seekToEnd(); try file.seek(toOffset: length > 65536 ? length - 65536 : 0)
            try output(["schemaVersion": 1, "taskId": args[1], "stream": args[2], "truncated": length > 65536, "text": scrub(String(decoding: file.readDataToEndOfFile(), as: UTF8.self))]); return 0
        }
        if ["pause", "resume"].contains(command) {
            guard args.count == 2 else { throw failure("Expected install task UUID") }
            let dir = try directory(args[1]); let record = try read(dir)
            guard (record["arguments"] as? [String])?.first == "install", record["state"] as? String == "running",
                  let updated = record["updatedAt"] as? Double, Date().timeIntervalSince1970 - updated <= 30 else {
                throw failure("active_install_required")
            }
            let lock = dir.appendingPathComponent("control.lock")
            let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw failure("control_lock_unavailable") }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor); throw failure("control_request_busy")
            }
            defer { flock(descriptor, LOCK_UN); close(descriptor) }
            let request = UUID().uuidString
            let requestURL = dir.appendingPathComponent("control-request.json")
            let replyURL = dir.appendingPathComponent("control-response-\(request).json")
            defer { try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: replyURL) }
            try data(["id": request, "action": command]).write(to: requestURL, options: .atomic)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let bytes = try? Data(contentsOf: replyURL),
                   let response = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                    try output(response)
                    return response["status"] as? String == "observed" ? 0 : 1
                }
                let current = try read(dir)
                if !["queued", "running", "awaiting_confirmation"].contains(current["state"] as? String ?? "") {
                    try output(["schemaVersion": 1, "taskId": args[1], "status": "unknown", "error": "task_ended"]); return 1
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            try output(["schemaVersion": 1, "taskId": args[1], "status": "unknown", "error": "control_timeout"]); return 1
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
        let admission: LauncherOperationLease?
        do { admission = operation == "launcher-update-install" ? nil : try LauncherOperationLease.admission(exclusive: false) }
        catch {
            record["errorCode"] = "launcher_update_busy"; record["error"] = error.localizedDescription
            record["exitCode"] = 1; try state("failed"); return 1
        }
        defer { admission?.release() }
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
        if operation == "login-install" {
            #if !AGENT_FIXTURE
            guard arguments.count == 1 else { record["error"] = "invalid_login_install_arguments"; record["exitCode"] = 1; try state("failed"); return 1 }
            #endif
            let resources = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            let manifest = resources.appendingPathComponent("idvLoginComponent.json")
            let installerPayload = resources.appendingPathComponent("InstallerPayload", isDirectory: true)
            let installer = installerPayload.appendingPathComponent("installIdentityVPasswordlessHelpers.command")
            let downloader = resources.appendingPathComponent("IdentityVIdvLoginDownloader")
            let manifestData = try? Data(contentsOf: manifest)
            let manifestObject = manifestData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            #if AGENT_FIXTURE
            let version = "fixture"
            let asset = "fixture-component"
            let cache = dir.appendingPathComponent("fixture-cache", isDirectory: true)
            #else
            guard let version = manifestObject?["version"] as? String,
                  version.range(of: "^[0-9][0-9A-Za-z.-]*$", options: .regularExpression) != nil,
                  let asset = manifestObject?["assetName"] as? String,
                  !asset.isEmpty, asset == URL(fileURLWithPath: asset).lastPathComponent,
                  FileManager.default.isExecutableFile(atPath: downloader.path),
                  FileManager.default.isExecutableFile(atPath: installer.path),
                  FileManager.default.fileExists(atPath: installerPayload.path) else {
                record["error"] = "login_install_resources_unavailable"; record["exitCode"] = 1; try state("failed"); return 1
            }
            let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/IdentityVOnMac/Components/IdvLoginDownload", isDirectory: true).appendingPathComponent(version, isDirectory: true)
            let installedMetadata = URL(fileURLWithPath: "/Library/Application Support/IdentityVOnMac/Components/idv-login/current/component.json")
            let installedData = try? Data(contentsOf: installedMetadata)
            let installedObject = installedData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let helper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/identityv-on-mac/start-idv-login.sh")
            let helperValues = try? helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let helperText = (helperValues?.isRegularFile == true && helperValues?.isSymbolicLink != true && (helperValues?.fileSize ?? 0) > 0 && (helperValues?.fileSize ?? 0) <= 262144) ? try? String(contentsOf: helper, encoding: .utf8) : nil
            if let installedVersion = installedObject?["version"] as? String, !installedVersion.isEmpty,
               installedVersion.compare(version, options: .numeric) != .orderedAscending,
               let helperText, [8, 9, 10].contains(where: { helperText.contains("readonly IDV_LOGIN_STATUS_CONTRACT=\"\($0)\"") }) {
                record["output"] = ["schemaVersion": 1, "installed": true, "alreadyInstalled": true]
                record["exitCode"] = 0; try state("succeeded"); try event("result", ["exitCode": 0]); return 0
            }
            #endif
            let expected = cache.appendingPathComponent(asset)
            let stageOutput = dir.appendingPathComponent("login-download.stdout")
            guard FileManager.default.createFile(atPath: stageOutput.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure("stage_stream_creation_failed") }
            let stageFile = try FileHandle(forWritingTo: stageOutput)
            let stageError = try FileHandle(forWritingTo: dir.appendingPathComponent("stderr.log"))
            defer { try? stageFile.close(); try? stageError.close() }
            let stage = Process()
            #if AGENT_FIXTURE
            stage.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let usesOfflinePayload = arguments.contains("--fixture-offline")
            stage.arguments = ["fixture-login-download", expected.path] + Array(arguments.dropFirst())
            #else
            stage.executableURL = downloader
            var downloadArgs = [manifest.path, cache.path]
            let image = resources.appendingPathComponent("OfflinePayloads/idv-login-\(version).dmg")
            let offlineManifest = resources.appendingPathComponent("OfflinePayloads/offlinePayloads.json")
            let usesOfflinePayload = FileManager.default.isReadableFile(atPath: image.path) && FileManager.default.isReadableFile(atPath: offlineManifest.path)
            if usesOfflinePayload { downloadArgs += ["--payload-image", image.path, "--payload-manifest", offlineManifest.path] }
            stage.arguments = downloadArgs
            #endif
            stage.standardInput = FileHandle.nullDevice; stage.standardOutput = stageFile; stage.standardError = stageError
            do { try stage.run() } catch { record["error"] = "login_download_launch_failed"; record["exitCode"] = 1; try state("failed"); return 1 }
            record["cancellable"] = true; try state("running")
            let stageReader = try FileHandle(forReadingFrom: dir.appendingPathComponent("stderr.log")); defer { try? stageReader.close() }
            var buffer = Data(), sentCancel = false
            var cancellationTime: Date?
            var forcedTermination = false
            func stageProgress() throws {
                buffer.append(stageReader.readDataToEndOfFile())
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if let payload = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { try event("progress", ["payload": payload]) }
                }
                if buffer.count > 1_048_576 { buffer.removeAll(keepingCapacity: false) }
            }
            while stage.isRunning {
                try stageProgress()
                if !sentCancel && FileManager.default.fileExists(atPath: cancel.path) {
                    sentCancel = true; cancellationTime = Date()
                    if !usesOfflinePayload { _ = kill(stage.processIdentifier, SIGTERM) }
                    try event("cancellation_requested", ["cleanupPending": usesOfflinePayload])
                }
                if sentCancel && !usesOfflinePayload && !forcedTermination,
                   let cancellationTime, Date().timeIntervalSince(cancellationTime) >= 4 {
                    forcedTermination = true
                    _ = kill(stage.processIdentifier, SIGKILL)
                }
                #if AGENT_FIXTURE
                let cancelTimeout: TimeInterval = arguments.contains("--fixture-cancel-timeout") ? 1 : 30
                #else
                let cancelTimeout: TimeInterval = 30
                #endif
                if let cancellationTime, Date().timeIntervalSince(cancellationTime) >= cancelTimeout {
                    record["error"] = "login_download_result_unknown"; record["errorCode"] = "login_download_result_unknown"
                    record["cancellationRequested"] = true; record["exitCode"] = 1; try state("unknown"); return 1
                }
                record["updatedAt"] = Date().timeIntervalSince1970; try save(record, dir)
                Thread.sleep(forTimeInterval: 0.2)
            }
            stage.waitUntilExit(); try stageProgress()
            record["downloadExitCode"] = stage.terminationStatus
            record["downloadTerminationReason"] = stage.terminationReason == .exit ? "exit" : "signal"
            if sentCancel || FileManager.default.fileExists(atPath: cancel.path) {
                record["cancellationRequested"] = true
                let endedSafely = (stage.terminationReason == .exit && stage.terminationStatus == 0)
                    || (!usesOfflinePayload && sentCancel && stage.terminationReason == .exit && stage.terminationStatus == 130)
                    || (!usesOfflinePayload && sentCancel && stage.terminationReason == .uncaughtSignal &&
                        (stage.terminationStatus == SIGTERM || (forcedTermination && stage.terminationStatus == SIGKILL)))
                guard endedSafely else {
                    record["error"] = "login_download_failed_during_cancellation"; record["childExitCode"] = stage.terminationStatus
                    record["exitCode"] = 1; try state("failed"); return 1
                }
                record["exitCode"] = 130; try state("cancelled"); return 130
            }
            guard stage.terminationReason == .exit, stage.terminationStatus == 0,
                  let output = try? String(contentsOf: stageOutput, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  URL(fileURLWithPath: output).standardizedFileURL.path == expected.standardizedFileURL.path,
                  let values = try? expected.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                record["error"] = "login_download_failed"; record["exitCode"] = 1; try state("failed"); return 1
            }
            #if !AGENT_FIXTURE
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any], session[kCGSessionOnConsoleKey as String] as? Bool == true else {
                record["error"] = "confirmation_unavailable"; record["exitCode"] = 1; try state("failed"); return 1
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = localized("idv-login 安装需要输入密码授权")
            alert.addButton(withTitle: localized("取消")); alert.addButton(withTitle: localized("继续安装"))
            if FileManager.default.fileExists(atPath: cancel.path) { record["exitCode"] = 130; record["cancellationRequested"] = true; try state("cancelled"); return 130 }
            try state("awaiting_confirmation")
            var alertError: Error?
            let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
                record["updatedAt"] = Date().timeIntervalSince1970
                do { try save(record, dir) } catch { alertError = error; app.abortModal() }
                if FileManager.default.fileExists(atPath: cancel.path) { app.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            let response = alert.runModal(); timer.invalidate(); alert.window.orderOut(nil)
            if let error = alertError { record["error"] = error.localizedDescription; record["exitCode"] = 1; try state("failed"); return 1 }
            guard response == .alertSecondButtonReturn, !FileManager.default.fileExists(atPath: cancel.path) else {
                record["exitCode"] = 130; record["cancellationRequested"] = FileManager.default.fileExists(atPath: cancel.path); try state("cancelled"); return 130
            }
            #endif
            #if AGENT_FIXTURE
            if arguments.contains("--fixture-confirm-wait") {
                try state("awaiting_confirmation")
                let waitUntil = Date().addingTimeInterval(3)
                while Date() < waitUntil && !FileManager.default.fileExists(atPath: cancel.path) {
                    record["updatedAt"] = Date().timeIntervalSince1970; try save(record, dir)
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            #endif
            var handoff = AgentPrivilegeHandoff()
            if FileManager.default.fileExists(atPath: cancel.path) { handoff.requestCancel() }
            guard handoff.commit() else { record["cancellationRequested"] = true; record["exitCode"] = 130; try state("cancelled"); return 130 }
            let fresh = !FileManager.default.isExecutableFile(atPath: "/Library/PrivilegedHelperTools/identityv-on-mac/start-idv-login.sh")
            record["cancellable"] = false; try state("running")
            let install = Process()
            #if AGENT_FIXTURE
            install.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            install.arguments = ["fixture-login-install"] + Array(arguments.dropFirst())
            #else
            install.executableURL = URL(fileURLWithPath: "/bin/zsh")
            install.arguments = [installer.path, "--payload-root", installerPayload.path, "--component", expected.path]
            #endif
            install.standardInput = FileHandle.nullDevice
            install.standardOutput = try FileHandle(forWritingTo: dir.appendingPathComponent("stdout.log"))
            install.standardError = stageError
            do { try install.run() } catch { record["error"] = "login_install_launch_failed"; record["exitCode"] = 1; try state("failed"); return 1 }
            #if AGENT_FIXTURE
            let deadline = Date().addingTimeInterval(arguments.contains("--fixture-install-timeout") ? 1 : 300)
            #else
            let deadline = Date().addingTimeInterval(300)
            #endif
            var lateCancel = false
            while install.isRunning {
                if !lateCancel && FileManager.default.fileExists(atPath: cancel.path) { lateCancel = true; handoff.requestCancel(); try event("cancellation_too_late") }
                if Date() >= deadline {
                    record["error"] = "privileged_result_unknown"; record["errorCode"] = "privileged_result_unknown"
                    record["exitCode"] = 1; record["cancellationRequested"] = lateCancel; try state("unknown"); return 1
                }
                record["updatedAt"] = Date().timeIntervalSince1970; try save(record, dir)
                Thread.sleep(forTimeInterval: 0.2)
            }
            install.waitUntilExit()
            if !lateCancel && FileManager.default.fileExists(atPath: cancel.path) { lateCancel = true; try event("cancellation_too_late") }
            record["cancellationRequested"] = lateCancel
            record["childExitCode"] = install.terminationStatus
            guard install.terminationReason == .exit else {
                record["error"] = "privileged_result_unknown"; record["errorCode"] = "privileged_result_unknown"; record["exitCode"] = 1; try state("unknown"); return 1
            }
            guard install.terminationStatus == 0 else { record["error"] = "login_install_failed"; record["exitCode"] = 1; try state("failed"); return 1 }
            #if !AGENT_FIXTURE
            let defaults = UserDefaults(suiteName: "com.fengyin.identityv.launcher") ?? .standard
            defaults.removeObject(forKey: "idvLoginCertificateTrustNoticeAcknowledged")
            if fresh { defaults.set(true, forKey: "idvLoginFollowGameLaunchEnabled") }
            #endif
            record["output"] = ["schemaVersion": 1, "installed": true]
            record["exitCode"] = 0; try state("succeeded"); try event("result", ["exitCode": 0]); return 0
        }
        if operation == "remove" {
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
            let alert = NSAlert(); alert.messageText = localized("你的 Agent 要卸载以下位置的游戏，是否继续？")
            let resourceDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            // Icon Services applies the same app-icon treatment as Finder.
            // Loading raw ICNS pixels here showed a square black backing.
            var bundle = resourceDirectory
            while bundle.path != "/" && bundle.pathExtension.lowercased() != "app" {
                bundle.deleteLastPathComponent()
            }
            if bundle.pathExtension.lowercased() == "app" {
                alert.icon = NSWorkspace.shared.icon(forFile: bundle.path)
            } else if let icon = NSImage(contentsOf: resourceDirectory.appendingPathComponent("IdentityVLauncher.icns")) {
                alert.icon = icon
            }
            let gamePath = preview["gamePath"] as? String ?? localized("当前游戏目录不可用")
            let ownership = preview["externalGameRoot"] as? Bool == true ? "\n" + localized("外部游戏文件将保留。") : ""
            alert.informativeText = gamePath + ownership
            alert.addButton(withTitle: localized("取消")); alert.addButton(withTitle: localized("确认卸载"))
            // The modal run loop must keep heartbeating and service API/signal
            // cancellation. Otherwise cancel writes a marker but leaves this
            // worker (and its dialog) blocked until a human clicks a button.
            if FileManager.default.fileExists(atPath: cancel.path) {
                record["exitCode"] = 130; record["cancellationRequested"] = true
                try state("cancelled"); return 130
            }
            // Publish readiness after preflight/Icon Services, immediately
            // before entering the serviced modal run loop.
            try state("awaiting_confirmation")
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
        #if !AGENT_FIXTURE
        if operation == "login-start" {
            let metadata = URL(fileURLWithPath: "/Library/Application Support/IdentityVOnMac/Components/idv-login/current/component.json")
            let helper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/identityv-on-mac/start-idv-login.sh")
            let data = try? Data(contentsOf: metadata)
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let helperValues = try? helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let helperText = (helperValues?.isRegularFile == true && helperValues?.isSymbolicLink != true && (helperValues?.fileSize ?? 0) > 0 && (helperValues?.fileSize ?? 0) <= 262144) ? try? String(contentsOf: helper, encoding: .utf8) : nil
            guard let version = object?["version"] as? String, !version.isEmpty,
                  FileManager.default.isExecutableFile(atPath: helper.path),
                  let helperText, [8, 9, 10].contains(where: { helperText.contains("readonly IDV_LOGIN_STATUS_CONTRACT=\"\($0)\"") }) else {
                record["error"] = "login_component_unavailable"; record["exitCode"] = 1
                try state("failed"); return 1
            }
            let defaults = UserDefaults(suiteName: "com.fengyin.identityv.launcher") ?? .standard
            if !defaults.bool(forKey: "idvLoginCertificateTrustNoticeAcknowledged") {
                guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
                      session[kCGSessionOnConsoleKey as String] as? Bool == true else {
                    record["error"] = "confirmation_unavailable"; record["exitCode"] = 1
                    try state("failed"); return 1
                }
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = localized("idv-login 首次启动需要系统授权")
                alert.addButton(withTitle: localized("取消")); alert.addButton(withTitle: localized("确认"))
                if FileManager.default.fileExists(atPath: cancel.path) {
                    record["exitCode"] = 130; record["cancellationRequested"] = true
                    try state("cancelled"); return 130
                }
                try state("awaiting_confirmation")
                var confirmationError: Error?
                let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
                    record["updatedAt"] = Date().timeIntervalSince1970
                    do { try save(record, dir) } catch { confirmationError = error; app.abortModal() }
                    if FileManager.default.fileExists(atPath: cancel.path) { app.abortModal() }
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                let response = alert.runModal()
                timer.invalidate(); alert.window.orderOut(nil)
                if let error = confirmationError {
                    record["error"] = error.localizedDescription; record["exitCode"] = 1
                    try state("failed"); return 1
                }
                guard response == .alertSecondButtonReturn,
                      !FileManager.default.fileExists(atPath: cancel.path) else {
                    record["exitCode"] = 130
                    record["cancellationRequested"] = FileManager.default.fileExists(atPath: cancel.path)
                    try state("cancelled"); return 130
                }
                defaults.set(true, forKey: "idvLoginCertificateTrustNoticeAcknowledged")
            }
        }
        #endif
        if FileManager.default.fileExists(atPath: cancel.path) { record["exitCode"] = 130; record["cancellationRequested"] = true; try state("cancelled"); return 130 }
        var executionArguments = arguments
        if operation == "remove", let preview = record["removalPreview"] as? [String: Any],
           let token = preview["removalToken"] as? String {
            executionArguments += ["--expected-removal-token", token]
        }
        let child = Process()
        let manager = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if operation.hasPrefix("launcher-update-") || operation == "login-admin-open" || operation.hasPrefix("language-") || operation.hasPrefix("login-follow-") || ["login-start", "login-stop", "feedback-draft"].contains(operation) {
            child.executableURL = manager.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacOS/IdentityVLauncher")
            child.arguments = ["--launcher-agent-operation"] + executionArguments
        } else {
            child.executableURL = manager; child.arguments = executionArguments
        }
        #if AGENT_FIXTURE
        if ["login-start", "login-stop", "feedback-draft"].contains(operation) { child.executableURL = manager; child.arguments = executionArguments }
        #endif
        var environment = ProcessInfo.processInfo.environment
        environment["IDENTITYV_AGENT_TASK_ID"] = record["taskId"] as? String
        child.environment = environment
        // Files avoid pipe backpressure and preserve complete output even when caller disconnects.
        let stdoutURL = dir.appendingPathComponent("stdout.log"), stderrURL = dir.appendingPathComponent("stderr.log")
        let out = try FileHandle(forWritingTo: stdoutURL), err = try FileHandle(forWritingTo: stderrURL)
        defer { try? out.close(); try? err.close() }
        child.standardInput = FileHandle.nullDevice; child.standardOutput = out; child.standardError = err
        var handoff = AgentPrivilegeHandoff()
        if ["login-start", "login-stop", "feedback-draft"].contains(operation) {
            if FileManager.default.fileExists(atPath: cancel.path) { handoff.requestCancel() }
            guard handoff.commit() else {
                record["exitCode"] = 130; record["cancellationRequested"] = true
                try state("cancelled"); return 130
            }
            record["cancellable"] = false
            try state("running")
        }
        do { try child.run() } catch { record["error"] = error.localizedDescription; record["exitCode"] = 1; try state("failed"); return 1 }
        if !["login-start", "login-stop", "feedback-draft"].contains(operation) { try state("running") }
        #if AGENT_FIXTURE
        let handoffDeadline = Date().addingTimeInterval(arguments.contains("--fixture-timeout") ? 1 : 300)
        #else
        let handoffDeadline = Date().addingTimeInterval(300)
        #endif
        let reader = try FileHandle(forReadingFrom: stderrURL); defer { try? reader.close() }
        var buffer = Data(), sentCancel = false
        var currentCoreState: String?
        var pendingControl: (id: String, action: String, started: Date)?
        func replyControl(_ id: String, status: String, error: String? = nil) throws {
            var response: [String: Any] = ["schemaVersion": 1, "taskId": record["taskId"] ?? "", "status": status]
            if let error { response["error"] = error }
            try data(response).write(to: dir.appendingPathComponent("control-response-\(id).json"), options: .atomic)
        }
        func progress() throws {
            buffer.append(reader.readDataToEndOfFile())
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if let payload = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    if (operation.hasPrefix("launcher-update-") || operation == "login-start"), payload["event"] as? String == "agent-state",
                       let value = payload["state"] as? String, ["awaiting_confirmation", "running"].contains(value) {
                        try state(value)
                    }
                    if let cancellable = payload["cancellable"] as? Bool { record["cancellable"] = cancellable }
                    if operation == "install", payload["event"] as? String == "progress",
                       let phase = payload["phase"] as? String, phase != "downloading" {
                        currentCoreState = nil
                        if let pending = pendingControl { try replyControl(pending.id, status: "unknown", error: "phase_changed"); pendingControl = nil }
                    }
                    if operation == "install", payload["phase"] as? String == "downloading", let state = payload["coreState"] as? String {
                        currentCoreState = state
                        if let pending = pendingControl {
                            let confirmed = pending.action == "pause" ? ["6", "7"].contains(state) : ["1", "2", "3", "4", "5"].contains(state)
                            if confirmed { try replyControl(pending.id, status: "observed"); pendingControl = nil }
                        }
                    }
                    try event("progress", ["payload": payload])
                }
            }
            // Plain diagnostics may have no newline; raw bytes remain in stderr.log.
            if buffer.count > 1_048_576 { buffer.removeAll(keepingCapacity: false) }
        }
        while child.isRunning {
            try progress()
            if operation == "install", pendingControl == nil {
                let requestURL = dir.appendingPathComponent("control-request.json")
                if let bytes = try? Data(contentsOf: requestURL), bytes.count <= 1024,
                   let request = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
                   let id = request["id"], UUID(uuidString: id) != nil,
                   let action = request["action"], ["pause", "resume"].contains(action) {
                    try? FileManager.default.removeItem(at: requestURL)
                    let activeState = currentCoreState.map { ["1", "2", "3", "4", "5", "6", "7"].contains($0) } ?? false
                    if FileManager.default.fileExists(atPath: cancel.path) || !activeState {
                        try replyControl(id, status: "failed", error: "download_not_controllable")
                    } else if let index = arguments.firstIndex(of: "--destination-parent"), index + 1 < arguments.count,
                              arguments[index + 1].hasPrefix("/"),
                              let productIndex = arguments.firstIndex(of: "--product"), productIndex + 1 < arguments.count,
                              ["mainland", "global"].contains(arguments[productIndex + 1]) {
                        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
                        let markerName = arguments[productIndex + 1] == "mainland" ? ".identityv-direct-install.json" : ".identityv-global-install.json"
                        // Pin the root and work directory by descriptor. The
                        // selected path may be renamed after validation; all
                        // subsequent I/O stays beneath these exact directories.
                        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                        guard rootFD >= 0 else { try replyControl(id, status: "failed", error: "install_control_unavailable"); continue }
                        defer { close(rootFD) }
                        let markerFD = openat(rootFD, markerName, O_RDONLY | O_NOFOLLOW)
                        guard markerFD >= 0 else { try replyControl(id, status: "failed", error: "install_control_unavailable"); continue }
                        defer { close(markerFD) }
                        var markerStat = stat()
                        guard fstat(markerFD, &markerStat) == 0, (markerStat.st_mode & S_IFMT) == S_IFREG,
                              markerStat.st_size > 0, markerStat.st_size <= 65536 else {
                            try replyControl(id, status: "failed", error: "install_control_unavailable"); continue
                        }
                        let markerData = FileHandle(fileDescriptor: markerFD, closeOnDealloc: false).readDataToEndOfFile()
                        let markerObject = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any]
                        let workFD = openat(rootFD, "work", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                        guard workFD >= 0 else { try replyControl(id, status: "failed", error: "install_control_unavailable"); continue }
                        defer { close(workFD) }
                        var controlStat = stat()
                        let controlStatus = fstatat(workFD, "download-control.json", &controlStat, AT_SYMLINK_NOFOLLOW)
                        let controlSafe = (controlStatus == -1 && errno == ENOENT) ||
                            (controlStatus == 0 && (controlStat.st_mode & S_IFMT) == S_IFREG)
                        guard markerObject?["schemaVersion"] as? Int == 1,
                              markerObject?["product"] as? String == arguments[productIndex + 1],
                              markerObject?["phase"] as? String == "downloading", controlSafe else {
                            try replyControl(id, status: "failed", error: "install_control_unavailable"); continue
                        }
                        do {
                            let sequence = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                            let temporary = ".download-control-\(UUID().uuidString)"
                            let descriptor = openat(workFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                            guard descriptor >= 0 else { throw failure("control_create_failed") }
                            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                            defer { try? handle.close(); _ = unlinkat(workFD, temporary, 0) }
                            try handle.write(contentsOf: data(["schemaVersion": 1, "sequence": sequence, "action": action]))
                            try handle.close()
                            guard renameat(workFD, temporary, workFD, "download-control.json") == 0 else { throw failure("control_publish_failed") }
                            pendingControl = (id, action, Date())
                        } catch { try replyControl(id, status: "failed", error: "control_write_failed") }
                    } else { try replyControl(id, status: "failed", error: "install_target_invalid") }
                }
            }
            #if AGENT_FIXTURE
            let controlTimeout: TimeInterval = arguments.contains("--fixture-no-ack") ? 1 : 25
            #else
            let controlTimeout: TimeInterval = 25
            #endif
            if let pending = pendingControl, Date().timeIntervalSince(pending.started) > controlTimeout {
                try replyControl(pending.id, status: "unknown", error: "control_timeout"); pendingControl = nil
            }
            if !sentCancel && FileManager.default.fileExists(atPath: cancel.path) {
                sentCancel = true
                if (operation == "launcher-update-install" || ["login-start", "login-stop", "feedback-draft"].contains(operation)), record["cancellable"] as? Bool == false {
                    if ["login-start", "login-stop", "feedback-draft"].contains(operation) { handoff.requestCancel() }
                    try event("cancellation_too_late")
                } else { child.terminate(); try event("cancellation_requested") }
            }
            if ["login-start", "login-stop", "feedback-draft"].contains(operation), Date() >= handoffDeadline {
                record["errorCode"] = "privileged_result_unknown"
                record["error"] = "Timed out waiting for privileged operation; inspect actual component state."
                record["cancellationRequested"] = sentCancel
                record["exitCode"] = 1
                try state("unknown")
                try event("result", ["exitCode": 1, "outcome": handoff.outcome(exitCode: nil)])
                return 1
            }
            record["updatedAt"] = Date().timeIntervalSince1970; try save(record, dir)
            Thread.sleep(forTimeInterval: 0.2)
        }
        child.waitUntilExit(); try progress()
        if ["login-start", "login-stop", "feedback-draft"].contains(operation), !sentCancel, FileManager.default.fileExists(atPath: cancel.path) {
            sentCancel = true; handoff.requestCancel()
            try event("cancellation_too_late")
        }
        record["cancellationRequested"] = sentCancel
        record["childExitCode"] = child.terminationStatus
        if ["login-start", "login-stop", "feedback-draft"].contains(operation), child.terminationReason != .exit {
            record["errorCode"] = "privileged_result_unknown"
            record["error"] = "The handoff process ended without a receipt; inspect actual component state."
            record["exitCode"] = 1
            try state("unknown")
            try event("result", ["exitCode": 1, "outcome": handoff.outcome(exitCode: nil)])
            return 1
        }
        let cancelled = !["login-start", "login-stop", "feedback-draft"].contains(operation) && ((sentCancel && child.terminationReason == .uncaughtSignal)
            || (child.terminationReason == .exit && child.terminationStatus == 130 && (sentCancel || operation == "launcher-update-install")))
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

/// Conservative handoff: once committed, cancellation is only recorded and
/// the owner must wait for a real receipt; absence of a receipt is unknown.
struct AgentPrivilegeHandoff {
    private(set) var committed = false
    private(set) var cancellationRequested = false
    mutating func requestCancel() { cancellationRequested = true }
    mutating func commit() -> Bool {
        guard !cancellationRequested, !committed else { return false }
        committed = true
        return true
    }
    func outcome(exitCode: Int32?) -> String {
        guard committed else { return cancellationRequested ? "cancelled" : "not_started" }
        guard let exitCode else { return "unknown" }
        return exitCode == 0 ? "succeeded" : "failed"
    }
}
