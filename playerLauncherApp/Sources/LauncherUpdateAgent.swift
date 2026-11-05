import AppKit
import Foundation
import Darwin

/// Only the explicit flag enters this backend. Ordinary launches, including
/// --launcher-update-receipt, always enter the SwiftUI application.
enum LauncherEntryRouting {
    static func isAgentOperation(_ args: [String]) -> Bool { args.first == "--launcher-agent-operation" }
    static func operation(_ args: [String]) -> String? {
        guard args.count >= 2, args[0] == "--launcher-agent-operation" else { return nil }
        return args[1]
    }
}

private final class LauncherUpdateCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var committed = false
    private var requestedValue = false
    var cancelTask: (() -> Void)?
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return requestedValue }
    func request() {
        lock.lock(); requestedValue = true; let callback = committed ? nil : cancelTask; lock.unlock()
        callback?()
    }
    func commit() throws {
        lock.lock(); defer { lock.unlock() }
        guard !requestedValue else { throw CancellationError() }
        committed = true
    }
}

@MainActor
enum LauncherUpdateAgent {
    static let operations = ["launcher-update-check", "launcher-update-install"]
    static func emit(_ value: [String: Any], to handle: FileHandle = .standardError) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            handle.write(data); handle.write(Data([10]))
        }
    }
    static func run(_ args: [String]) async -> Int32 {
        guard args.count == 1, let operation = args.first, operations.contains(operation) else {
            emit(["error": "invalid_launcher_update_operation"]); return 64
        }
        let cancellation = LauncherUpdateCancellation()
        let task = Task { try await perform(operation, cancellation: cancellation) }
        cancellation.cancelTask = { task.cancel() }
        let oldTerm = signal(SIGTERM, SIG_IGN), oldInt = signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { DispatchSource.makeSignalSource(signal: $0, queue: .global()) }
        for source in sources { source.setEventHandler { cancellation.request() }; source.resume() }
        defer { sources.forEach { $0.cancel() }; signal(SIGTERM, oldTerm); signal(SIGINT, oldInt) }
        do { return try await task.value }
        catch is CancellationError { emit(["error": "launcher_update_cancelled"]); return 130 }
        catch {
            if task.isCancelled, let network = error as? URLError, network.code == .cancelled {
                emit(["error": "launcher_update_cancelled"]); return 130
            }
            emit(["error": "launcher_update_failed", "message": error.localizedDescription]); return 1
        }
    }
    private static func perform(_ operation: String, cancellation: LauncherUpdateCancellation) async throws -> Int32 {
        let current = Bundle.main.object(forInfoDictionaryKey: "IdentityVReleaseVersion") as? String ?? ""
        emit(["event": "progress", "phase": "checking"])
        let outcome = try await LauncherUpdateChecker().check(currentVersion: current)
        guard case .available(let release) = outcome else {
            emit(["schemaVersion": 1, "available": false, "currentVersion": current], to: .standardOutput); return 0
        }
        if operation == "launcher-update-check" {
            emit(["schemaVersion": 1, "available": true, "currentVersion": current,
                  "version": release.tag_name, "pageURL": release.pageURL?.absoluteString ?? ""], to: .standardOutput)
            return 0
        }
        try Task.checkCancellation()
        emit(["event": "agent-state", "state": "awaiting_confirmation"])
        try confirm(release, current: current, cancellation: cancellation)
        emit(["event": "agent-state", "state": "running"])
        let target = Bundle.main.bundleURL
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: LauncherUpdateInstallation.bundleID).filter {
            $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL.path == target.standardizedFileURL.path
        }
        var prepared: LauncherUpdatePlan?
        var helper: Process?
        var handedOff = false
        do {
            let plan = try await LauncherUpdatePreparer().prepare(release, target: target,
                oldPIDs: applications.map(\.processIdentifier), agentInitiated: true) { fraction in
                    emitNonisolated(["event": "progress", "phase": "downloading", "fraction": fraction])
                }
            prepared = plan
            try Task.checkCancellation()
            // After handoff, only the transaction helper decides success or
            // rollback. A late cancel request cannot kill it or fake rollback.
            try cancellation.commit()
            emit(["event": "progress", "phase": "applying", "cancellable": false])
            let outputURL = plan.root.appendingPathComponent("helper-result.jsonl")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LauncherUpdateFailure(message: "无法创建更新结果记录。")
            }
            let output = try FileHandle(forWritingTo: outputURL), read = try FileHandle(forReadingFrom: outputURL)
            defer { try? output.close(); try? read.close() }
            let process = try LauncherUpdateTransaction.start(plan, output: output)
            helper = process
            try await LauncherUpdateTransaction.waitUntilReady(process, plan: plan)
            for app in applications where !app.isTerminated {
                guard app.terminate() else { throw LauncherUpdateFailure(message: "启动器尚未退出，已停止安装。") }
            }
            try LauncherUpdateTransaction.authorize(plan)
            handedOff = true
            let code = await LauncherUpdateTransaction.waitForExit(process)
            let bytes = read.readDataToEndOfFile()
            guard bytes.count <= 65536,
                  let last = String(decoding: bytes, as: UTF8.self).split(separator: "\n").last,
                  let result = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else {
                throw LauncherUpdateFailure(message: "更新助手未返回有效结果；请检查保留的事务。")
            }
            emit(result, to: .standardOutput)
            guard code == 0, result["installed"] as? Bool == true, result["cleanupComplete"] as? Bool == true else {
                throw LauncherUpdateFailure(message: result["error"] as? String ?? "更新未完成。")
            }
            return 0
        } catch {
            if !handedOff {
                if let process = helper, process.isRunning { process.terminate(); _ = await LauncherUpdateTransaction.waitForExit(process) }
                if let plan = prepared {
                    if FileManager.default.fileExists(atPath: plan.root.path) {
                        do { try LauncherUpdateInstallation.cleanupPrepared(plan) }
                        catch { throw LauncherUpdateFailure(message: "更新临时文件未能清理，已保留：" + plan.root.path) }
                    }
                }
            }
            throw error
        }
    }
    nonisolated private static func emitNonisolated(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10]))
        }
    }
    private static func confirm(_ release: LauncherGitHubRelease, current: String, cancellation: LauncherUpdateCancellation) throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any], session[kCGSessionOnConsoleKey as String] as? Bool == true else {
            throw LauncherUpdateFailure(message: "confirmation_unavailable")
        }
        let language = LauncherLanguage.current
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        alert.messageText = language.localized("已检测到新版本，是否更新？")
        alert.informativeText = String(format: language.localized("当前版本：%@\n最新版本：%@"), current, LauncherUpdateInstallation.normalized(release.tag_name))
        alert.addButton(withTitle: language.localized("更新")); alert.addButton(withTitle: language.localized("取消"))
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in if cancellation.requested { app.abortModal() } }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal(); timer.invalidate(); alert.window.orderOut(nil)
        guard response == .alertFirstButtonReturn, !cancellation.requested else { throw CancellationError() }
    }
}
