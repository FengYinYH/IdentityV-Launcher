import Foundation

@main
enum LauncherUpdateResultSelfTest {
    static func main() throws {
        let plan = LauncherUpdatePlan(token: UUID().uuidString, root: URL(fileURLWithPath: "/fixture/transaction"),
            target: URL(fileURLWithPath: "/fixture/Launcher.app"), staged: URL(fileURLWithPath: "/fixture/stage"),
            backup: URL(fileURLWithPath: "/fixture/backup"), expectedVersion: "1.0.0", oldPID: 123)
        var preSwap = LauncherUpdateResult(ownsTransaction: true)
        preSwap.verifiedOriginal()
        let pre = preSwap.fields(cleanupComplete: true, plan: plan, error: "pre-swap failure")
        precondition(pre["targetReplaced"] as? Bool == false && pre["startupConfirmed"] as? Bool == false)
        precondition(pre["recoveryRequired"] as? Bool == false && pre["installed"] as? Bool == false)
        var noAck = preSwap
        noAck.replacedTarget()
        let live = noAck.fields(cleanupComplete: false, plan: plan, backupPresent: true, error: "live without receipt")
        precondition(live["targetReplaced"] as? Bool == true && live["startupConfirmed"] as? Bool == false)
        precondition(live["installed"] as? Bool == false && live["recoveryRequired"] as? Bool == true)
        precondition(live["transactionPath"] as? String == plan.root.path && live["backupPath"] as? String == plan.backup.path)
        var acknowledged = noAck
        acknowledged.confirmedStartup()
        let cleanupFailure = acknowledged.fields(cleanupComplete: false, plan: plan, backupPresent: false)
        precondition(cleanupFailure["targetReplaced"] as? Bool == true && cleanupFailure["startupConfirmed"] as? Bool == true)
        precondition(cleanupFailure["recoveryRequired"] as? Bool == true && cleanupFailure["backupPath"] == nil)
        let success = acknowledged.fields(cleanupComplete: true, plan: plan)
        precondition(success["installed"] as? Bool == true && success["recoveryRequired"] as? Bool == false)
        var restored = noAck
        restored.verifiedRollback()
        let rollback = restored.fields(cleanupComplete: true, plan: plan)
        precondition(rollback["targetReplaced"] as? Bool == false && rollback["startupConfirmed"] as? Bool == false)
        precondition(rollback["recoveryRequired"] as? Bool == false)
        var uncertain = noAck
        uncertain.failedRollback()
        let failed = uncertain.fields(cleanupComplete: false, plan: plan, backupPresent: true)
        precondition(failed["targetReplaced"] is NSNull && failed["targetState"] as? String == "unknown")
        precondition(failed["recoveryRequired"] as? Bool == true && failed["backupPath"] as? String == plan.backup.path)
        let early = LauncherUpdateResult().fields(cleanupComplete: false, error: "invalid invocation")
        precondition(early["targetReplaced"] is NSNull && early["startupConfirmed"] as? Bool == false)
        precondition(early["recoveryRequired"] as? Bool == false)
        _ = try JSONSerialization.data(withJSONObject: failed)
        print("Updater result states passed: pre-swap, live/no-ack, acknowledged cleanup failure, verified rollback and uncertain rollback; no App touched.")
    }
}
