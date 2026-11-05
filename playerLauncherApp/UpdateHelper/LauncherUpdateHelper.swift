import AppKit
import Darwin
import Foundation

#if !LAUNCHER_UPDATE_RESULT_SELF_TEST
@main
#endif
enum LauncherUpdateHelper {
    static func main() async {
        // CLI transport uses dispatch signal sources; do not inherit its
        // ignored TERM disposition into this independently owned helper.
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_IGN)
        exit(await execute())
    }
    static func execute() async -> Int32 {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apply-update" else {
            emit(LauncherUpdateResult().fields(cleanupComplete: false, error: "invalid_update_arguments")); return 64
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard (try? LauncherUpdateInstallation.validateRoot(root)) != nil,
              let data = try? LauncherUpdateInstallation.boundedRecord(root.appendingPathComponent("plan.json")),
              let plan = try? JSONDecoder().decode(LauncherUpdatePlan.self, from: data), plan.root.path == root.path,
              (try? LauncherUpdateInstallation.validatePlan(plan)) != nil else {
            emit(LauncherUpdateResult().fields(cleanupComplete: false, error: "invalid_update_plan")); return 65
        }
        let planLease: LauncherOperationLease
        do { planLease = try LauncherOperationLease.acquire("helper.lock", exclusive: true, directory: root) }
        catch {
            // Another helper owns this transaction: its physical target state
            // is unknown to this invocation, and we must not clean its files.
            emit(LauncherUpdateResult().fields(cleanupComplete: false, plan: plan, error: "update_transaction_in_use")); return 73
        }
        defer { planLease.release() }
        var ownsStage = false, mayClean = true
        var outcome = LauncherUpdateResult(ownsTransaction: true)
        defer {
            if ownsStage { try? FileManager.default.removeItem(at: plan.staged) }
            if mayClean { try? LauncherUpdateInstallation.cleanupRoot(root) }
        }
        do {
            try LauncherUpdateInstallation.verifyApp(plan.staged, expectedVersion: plan.expectedVersion, gatekeeper: false)
            ownsStage = true
            // Admission prevents new Agent/direct-manager operations starting;
            // the existing mutation lock also serializes legacy GUI mutations.
            let admission = try LauncherOperationLease.admission(exclusive: true, application: plan.target)
            defer { admission.release() }
            let mutation = try LauncherOperationLease.mutation()
            defer { mutation.release() }
            try LauncherUpdateInstallation.validateTarget(plan.target)
            try LauncherUpdateInstallation.verifyApp(plan.staged, expectedVersion: plan.expectedVersion, gatekeeper: false)
            let lockPath = plan.target.deletingLastPathComponent().appendingPathComponent(".IdentityVLauncher.update.lock").path
            let lock = open(lockPath, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw LauncherUpdateFailure(message: "无法锁定更新目标，已停止安装。") }
            defer { close(lock) }
            var attributes = stat()
            guard fstat(lock, &attributes) == 0, attributes.st_uid == getuid(), attributes.st_nlink == 1,
                  (attributes.st_mode & S_IFMT) == S_IFREG, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                throw LauncherUpdateFailure(message: "另一个更新正在进行，请稍后重试。")
            }
            // Own this stage only after obtaining all transaction locks. A
            // duplicate helper must never clean the first helper's live stage.
            ownsStage = true
            let info = NSDictionary(contentsOf: plan.target.appendingPathComponent("Contents/Info.plist"))
            try LauncherUpdateInstallation.validateInstalledBase(plan, metadata: info)
            try LauncherUpdateInstallation.verifyApp(plan.target, expectedVersion: plan.currentVersion, gatekeeper: false)
            outcome.verifiedOriginal()
            try Data(plan.token.utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
            let deadline = Date().addingTimeInterval(30)
            while (try? String(contentsOf: root.appendingPathComponent("commit"), encoding: .utf8)) != plan.token || plan.oldPIDs.contains(where: { kill($0, 0) == 0 }) {
                guard Date() < deadline else { throw LauncherUpdateFailure(message: "启动器尚未退出，已停止安装。") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try LauncherUpdateInstallation.ensureNoGame()
            try LauncherUpdateInstallation.validateTarget(plan.target)
            let fm = FileManager.default
            do {
                try LauncherUpdateInstallation.swap(plan) { try LauncherUpdateInstallation.verifyApp($0, expectedVersion: plan.expectedVersion, gatekeeper: false) }
            } catch {
                // swap may have restored the old app, or its own rollback may
                // have failed. Only a verified original resolves that ambiguity.
                do {
                    try LauncherUpdateInstallation.verifyApp(plan.target, expectedVersion: plan.currentVersion, gatekeeper: false)
                    try LauncherUpdateInstallation.validateInstalledBase(plan, metadata: NSDictionary(contentsOf: plan.target.appendingPathComponent("Contents/Info.plist")))
                    outcome.verifiedRollback()
                } catch { outcome.failedRollback(); mayClean = false }
                if fm.fileExists(atPath: plan.backup.path) { mayClean = false }
                throw error
            }
            outcome.replacedTarget()
            ownsStage = false
            do {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.arguments = ["--launcher-update-receipt", root.path]
                let app = try await NSWorkspace.shared.openApplication(at: plan.target, configuration: config)
                let deadline = Date().addingTimeInterval(30)
                var acknowledged = false
                while Date() < deadline, !app.isTerminated {
                    if let bytes = try? LauncherUpdateInstallation.boundedRecord(plan.receipt),
                       LauncherUpdateInstallation.receiptMatches(bytes, plan: plan, pid: app.processIdentifier),
                       app.bundleURL?.standardizedFileURL.path == plan.target.standardizedFileURL.path {
                        acknowledged = true; break
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard acknowledged else {
                    if !app.isTerminated {
                        mayClean = false
                        throw LauncherUpdateFailure(message: "新版仍在运行，但未确认启动完成；旧版备份已保留，未自动回退。")
                    }
                    throw LauncherUpdateFailure(message: "新版未能启动，正在恢复原版本。")
                }
                outcome.confirmedStartup()
                // Once a live app acknowledged, cleanup failure must not cause
                // rollback under that process. Keep the transaction for recovery.
                mayClean = false
                try fm.removeItem(at: plan.backup)
                try LauncherUpdateInstallation.cleanupRoot(root)
                var result = outcome.fields(cleanupComplete: true, plan: plan)
                result["version"] = LauncherUpdateInstallation.normalized(plan.expectedVersion)
                emit(result)
                return 0
            } catch {
                if mayClean {
                    var restored = false
                    do {
                        try LauncherUpdateInstallation.rollback(plan)
                        try LauncherUpdateInstallation.verifyApp(plan.target, expectedVersion: plan.currentVersion, gatekeeper: false)
                        try LauncherUpdateInstallation.validateInstalledBase(plan, metadata: NSDictionary(contentsOf: plan.target.appendingPathComponent("Contents/Info.plist")))
                        outcome.verifiedRollback(); restored = true
                    } catch { outcome.failedRollback(); mayClean = false }
                    if restored { _ = try? await NSWorkspace.shared.openApplication(at: plan.target, configuration: NSWorkspace.OpenConfiguration()) }
                }
                throw error
            }
        } catch {
            var cleanupComplete = false
            if mayClean {
                do {
                    if ownsStage, FileManager.default.fileExists(atPath: plan.staged.path) { try FileManager.default.removeItem(at: plan.staged) }
                    ownsStage = false
                    try LauncherUpdateInstallation.cleanupRoot(root)
                    mayClean = false; cleanupComplete = true
                } catch { mayClean = false; ownsStage = false }
            }
            emit(outcome.fields(cleanupComplete: cleanupComplete, plan: plan,
                backupPresent: FileManager.default.fileExists(atPath: plan.backup.path), error: error.localizedDescription))
            if !plan.agentInitiated {
                let recovery = cleanupComplete ? "" : "\n" + localized("事务目录：", plan: plan) + root.path
                let backup = FileManager.default.fileExists(atPath: plan.backup.path) ? "\n" + localized("旧版备份：", plan: plan) + plan.backup.path : ""
                let detail = localized(error.localizedDescription, plan: plan) + recovery + backup
                await MainActor.run {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    let alert = NSAlert()
                    alert.messageText = localized("启动器更新未完成", plan: plan)
                    alert.informativeText = detail
                    alert.addButton(withTitle: localized("好的", plan: plan))
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
            return 1
        }
    }
    static func localized(_ key: String, plan: LauncherUpdatePlan) -> String {
        let defaults = UserDefaults(suiteName: LauncherUpdateInstallation.bundleID) ?? .standard
        let code = LauncherLanguage.configured(from: defaults).locale.identifier
        for app in [plan.target, plan.backup] {
            if let bundle = Bundle(url: app.appendingPathComponent("Contents/Resources/" + code + ".lproj")) {
                let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
                if value != key { return value }
            }
        }
        return key
    }
    static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
}


/// Physical target and startup protocol are independent observations. Unknown
/// is encoded as null, never as false evidence that the original is intact.
struct LauncherUpdateResult {
    enum TargetState: String { case unknown, original, replacement }
    private(set) var targetState: TargetState = .unknown
    private(set) var startupConfirmed = false
    private(set) var rollbackUncertain = false
    var ownsTransaction = false

    mutating func verifiedOriginal() { targetState = .original; startupConfirmed = false }
    mutating func replacedTarget() { targetState = .replacement; startupConfirmed = false }
    mutating func confirmedStartup() { startupConfirmed = true }
    mutating func verifiedRollback() { targetState = .original; startupConfirmed = false; rollbackUncertain = false }
    mutating func failedRollback() { targetState = .unknown; startupConfirmed = false; rollbackUncertain = true }

    func fields(cleanupComplete: Bool, plan: LauncherUpdatePlan? = nil,
                backupPresent: Bool = false, error: String? = nil) -> [String: Any] {
        let recovery = rollbackUncertain || (ownsTransaction && !cleanupComplete)
        let replaced: Any = targetState == .unknown ? NSNull() : targetState == .replacement
        var value: [String: Any] = [
            "installed": startupConfirmed, // Compatibility alias, not physical state.
            "targetState": targetState.rawValue, "targetReplaced": replaced,
            "startupConfirmed": startupConfirmed, "recoveryRequired": recovery,
            "cleanupComplete": cleanupComplete
        ]
        if let error { value["error"] = error }
        if let plan {
            value["targetPath"] = plan.target.path
            if recovery {
                value["transactionPath"] = plan.root.path
                if backupPresent { value["backupPath"] = plan.backup.path }
            }
        }
        return value
    }
}
