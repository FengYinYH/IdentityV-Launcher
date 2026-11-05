import CryptoKit
import Foundation

@main
enum LauncherUpdateInstallationSelfTest {
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected rejection") } catch { }
    }
    static func identity(_ app: URL, _ expected: String) throws {
        let actual = try String(contentsOf: app.appendingPathComponent("identity"), encoding: .utf8)
        precondition(actual == expected)
    }
    static func main() async throws {
        precondition(LauncherUpdateInstallation.hasActiveOperation("/path/dwrg.exe --argument"))
        precondition(LauncherUpdateInstallation.hasActiveOperation("/Applications/Launcher.app/Contents/Resources/IdentityVDownloadSupervisor"))
        precondition(!LauncherUpdateInstallation.hasActiveOperation("/Applications/Launcher.app/Contents/MacOS/IdentityVLauncher"))
        let fm = FileManager.default
        let token = UUID().uuidString
        let root = LauncherOperationLease.realUserTemporaryDirectory.appendingPathComponent("IdentityVLauncherUpdate-" + token)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let bytes = Data("a package fixture".utf8)
        let package = root.appendingPathComponent("release.dmg")
        try bytes.write(to: package)
        let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let name = "IdentityV-Launcher-1.0.0-rc.10.dmg"
        let url = "https://github.com/FengYinYH/IdentityV-Launcher/releases/download/v1.0.0-rc.10/" + name
        let asset = LauncherReleaseAsset(name: name, size: Int64(bytes.count), digest: digest, state: "uploaded", browser_download_url: url)
        let release = LauncherGitHubRelease(tag_name: "v1.0.0-rc.10", draft: false, prerelease: true, published_at: "now", assets: [asset])
        _ = try LauncherUpdateInstallation.asset(for: release)
        try LauncherUpdateInstallation.verifyPackage(package, asset: asset)
        var duplicate = release; duplicate.assets.append(asset)
        rejects { _ = try LauncherUpdateInstallation.asset(for: duplicate) }
        for bad in [
            LauncherReleaseAsset(name: name, size: 0, digest: digest, state: "uploaded", browser_download_url: url),
            LauncherReleaseAsset(name: name, size: 2_000_000_000, digest: digest, state: "uploaded", browser_download_url: url),
            LauncherReleaseAsset(name: name, size: 10, digest: nil, state: "uploaded", browser_download_url: url),
            LauncherReleaseAsset(name: name, size: 10, digest: digest, state: "uploaded", browser_download_url: "https://example.com/" + name),
            LauncherReleaseAsset(name: "wrong.dmg", size: 10, digest: digest, state: "uploaded", browser_download_url: url)
        ] {
            var invalid = release; invalid.assets = [bad]
            rejects { _ = try LauncherUpdateInstallation.asset(for: invalid) }
        }
        try Data("tampered payload!".utf8).write(to: package)
        rejects { try LauncherUpdateInstallation.verifyPackage(package, asset: asset) }
        try Data(repeating: 1, count: bytes.count).write(to: package)
        rejects { try LauncherUpdateInstallation.verifyPackage(package, asset: asset) }
        rejects { try LauncherUpdateInstallation.validateTarget(root.appendingPathComponent("Fake.app")) }

        let target = root.appendingPathComponent("old.app"), staged = root.appendingPathComponent("new.app"), backup = root.appendingPathComponent("backup.app")
        func setup() throws {
            for url in [target, staged, backup] { try? fm.removeItem(at: url) }
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try Data("old".utf8).write(to: target.appendingPathComponent("identity"))
            try fm.createDirectory(at: staged, withIntermediateDirectories: false)
            try Data("new".utf8).write(to: staged.appendingPathComponent("identity"))
        }
        let plan = LauncherUpdatePlan(token: token, root: root, target: target, staged: staged, backup: backup, expectedVersion: "1.0.0-rc.10", oldPID: 100)
        try setup()
        try LauncherUpdateInstallation.swap(plan) { _ in }
        try identity(target, "new")
        try identity(backup, "old")
        try LauncherUpdateInstallation.rollback(plan)
        try identity(target, "old")
        try setup()
        rejects { try LauncherUpdateInstallation.swap(plan) { _ in throw LauncherUpdateFailure(message: "rejected signature") } }
        try identity(target, "old")
        precondition(!fm.fileExists(atPath: backup.path))
        try setup(); try fm.removeItem(at: staged)
        rejects { try LauncherUpdateInstallation.swap(plan) { _ in fatalError("Must never verify missing stage") } }
        try identity(target, "old")
        try setup(); try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        rejects { try LauncherUpdateInstallation.swap(plan) { _ in fatalError("Must not replace existing backup") } }
        try identity(target, "old")

        // A superficially correct bundle with an ad-hoc signature must fail
        // the pinned Developer ID requirement even when Gatekeeper is omitted.
        let app = root.appendingPathComponent("Fixture.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": LauncherUpdateInstallation.bundleID, "IdentityVReleaseVersion": "1.0.0-rc.10", "CFBundleExecutable": "IdentityVLauncher", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: app.appendingPathComponent("Contents/MacOS/IdentityVLauncher"))
        _ = try LauncherUpdateInstallation.command("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", LauncherUpdateInstallation.bundleID, app.path])
        rejects { try LauncherUpdateInstallation.verifyApp(app, expectedVersion: "1.0.0-rc.10", gatekeeper: false) }
        rejects { try LauncherUpdateInstallation.verifyApp(app, expectedVersion: "2.0.0", gatekeeper: false) }
        rejects { try LauncherUpdateInstallation.validatePlan(plan) }
        let realTarget = URL(fileURLWithPath: "/Applications/第五人格启动器.app")
        let valid = LauncherUpdatePlan(token: token, root: root, target: realTarget,
                                       staged: realTarget.deletingLastPathComponent().appendingPathComponent(".IdentityVLauncher.update-\(token).app"),
                                       backup: realTarget.deletingLastPathComponent().appendingPathComponent(".IdentityVLauncher.rollback-\(token).app"),
                                       expectedVersion: "1.0.0-rc.10", oldPID: 100)
        try LauncherUpdateInstallation.validatePlan(valid)
        let encoded = try JSONEncoder().encode(valid)
        try LauncherUpdateInstallation.validatePlan(JSONDecoder().decode(LauncherUpdatePlan.self, from: encoded))
        var future = valid; future.schemaVersion = 2
        rejects { try LauncherUpdateInstallation.validatePlan(future) }
        let link = root.appendingPathComponent("linked.dmg")
        try fm.createSymbolicLink(at: link, withDestinationURL: package)
        rejects { try LauncherUpdateInstallation.verifyPackage(link, asset: asset) }
        // Entrypoint routing must never consume the GUI startup receipt.
        precondition(LauncherEntryRouting.operation(["--launcher-update-receipt", root.path]) == nil)
        precondition(LauncherEntryRouting.operation([]) == nil)
        precondition(LauncherEntryRouting.isAgentOperation(["--launcher-agent-operation"]))
        precondition(!LauncherEntryRouting.isAgentOperation(["--launcher-update-receipt", root.path]))
        precondition(LauncherEntryRouting.operation(["--launcher-agent-operation", "launcher-update-check"]) == "launcher-update-check")
        let receipt = try LauncherUpdateInstallation.startupReceipt(valid, pid: 123, bundle: valid.target, version: "1.0.0-rc.10")
        precondition(LauncherUpdateInstallation.receiptMatches(receipt, plan: valid, pid: 123))
        precondition(!LauncherUpdateInstallation.receiptMatches(receipt, plan: valid, pid: 124))
        var different = valid; different = LauncherUpdatePlan(token: UUID().uuidString, root: root, target: valid.target,
            staged: valid.staged, backup: valid.backup, expectedVersion: valid.expectedVersion, oldPID: 100)
        precondition(!LauncherUpdateInstallation.receiptMatches(receipt, plan: different, pid: 123))
        rejects { _ = try LauncherUpdateInstallation.startupReceipt(valid, pid: 123, bundle: target, version: "1.0.0-rc.10") }
        rejects { _ = try LauncherUpdateInstallation.startupReceipt(valid, pid: 123, bundle: valid.target, version: "1.0.0-rc.9") }
        try LauncherUpdateInstallation.validateMinimumSystemVersion("15.1", current: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0))
        rejects { try LauncherUpdateInstallation.validateMinimumSystemVersion("16.0", current: OperatingSystemVersion(majorVersion: 15, minorVersion: 9, patchVersion: 0)) }
        rejects { try LauncherUpdateInstallation.validateMinimumSystemVersion("15.bad", current: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) }
        let oversized = root.appendingPathComponent("oversized-record")
        try Data(repeating: 65, count: 65537).write(to: oversized)
        rejects { _ = try LauncherUpdateInstallation.boundedRecord(oversized) }
        let linkedRecord = root.appendingPathComponent("linked-record")
        try fm.createSymbolicLink(at: linkedRecord, withDestinationURL: package)
        rejects { _ = try LauncherUpdateInstallation.boundedRecord(linkedRecord) }
        let leaseDirectory = root.appendingPathComponent("leases")
        let shared = try LauncherOperationLease.acquire("admission", exclusive: false, directory: leaseDirectory)
        let shared2 = try LauncherOperationLease.acquire("admission", exclusive: false, directory: leaseDirectory)
        rejects { _ = try LauncherOperationLease.acquire("admission", exclusive: true, directory: leaseDirectory) }
        shared.release(); shared2.release()
        let exclusive = try LauncherOperationLease.acquire("admission", exclusive: true, directory: leaseDirectory)
        rejects { _ = try LauncherOperationLease.acquire("admission", exclusive: false, directory: leaseDirectory) }
        exclusive.release()
        try fm.createSymbolicLink(at: leaseDirectory.appendingPathComponent("bad-lock"), withDestinationURL: package)
        rejects { _ = try LauncherOperationLease.acquire("bad-lock", exclusive: false, directory: leaseDirectory) }
        // A failed attach may still have a mounted directory. These injected
        // inventories model that state without attaching any real image.
        func cleanupFixture() throws -> URL {
            let url = LauncherOperationLease.realUserTemporaryDirectory.appendingPathComponent("IdentityVLauncherUpdate-" + UUID().uuidString)
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("owned fixture".utf8).write(to: url.appendingPathComponent("sentinel"))
            return url
        }
        let partial = try cleanupFixture()
        var mounted = [partial.appendingPathComponent("Mount", isDirectory: true)]
        var detached = false
        try LauncherUpdateInstallation.cleanupRoot(partial, inventory: { mounted }, detach: { mount in
            precondition(mount.path == partial.appendingPathComponent("Mount").path); detached = true; mounted = []
        })
        precondition(detached && !fm.fileExists(atPath: partial.path))
        let retained = try cleanupFixture(); defer { try? fm.removeItem(at: retained) }
        let retainedMount = retained.appendingPathComponent("Mount", isDirectory: true)
        rejects { try LauncherUpdateInstallation.cleanupRoot(retained, inventory: { [retainedMount] }, detach: { _ in throw LauncherUpdateFailure(message: "detach failed") }) }
        precondition(fm.fileExists(atPath: retained.appendingPathComponent("sentinel").path))
        var removed = false
        rejects { try LauncherUpdateInstallation.cleanupRoot(retained, inventory: { [retained.appendingPathComponent("UnknownMount")] }, detach: { _ in fatalError("must not detach unknown mount") }, remove: { _ in removed = true }) }
        precondition(!removed)
        rejects { try LauncherUpdateInstallation.cleanupRoot(retained, inventory: { throw LauncherUpdateFailure(message: "inventory unavailable") }, remove: { _ in removed = true }) }
        precondition(!removed)
        var base = valid
        base.currentVersion = "1.0.0-rc.5"; base.currentBuild = "18"
        try LauncherUpdateInstallation.validateInstalledBase(base, metadata: ["IdentityVReleaseVersion": "1.0.0-rc.5", "CFBundleVersion": "18"])
        rejects { try LauncherUpdateInstallation.validateInstalledBase(base, metadata: ["IdentityVReleaseVersion": "1.0.0-rc.6", "CFBundleVersion": "18"]) }
        rejects { try LauncherUpdateInstallation.validateInstalledBase(base, metadata: ["IdentityVReleaseVersion": "1.0.0-rc.5", "CFBundleVersion": "19"]) }
        // A mock helper must not finish just because it is ready, even when
        // there is no old GUI PID. Explicit commit is a separate handshake.
        let mock = Process()
        mock.executableURL = URL(fileURLWithPath: "/bin/sh")
        mock.arguments = ["-c", "printf '%s' \"$2\" > \"$1/ready\"; while [ ! -f \"$1/commit\" ]; do sleep 0.01; done", "mock", root.path, valid.token]
        mock.standardOutput = FileHandle.nullDevice; mock.standardError = FileHandle.nullDevice
        try mock.run()
        try await LauncherUpdateTransaction.waitUntilReady(mock, plan: valid)
        precondition(mock.isRunning)
        try LauncherUpdateTransaction.authorize(valid)
        let mockResult = await LauncherUpdateTransaction.waitForExit(mock)
        precondition(mockResult == 0)
        let start = Date()
        rejects { _ = try LauncherUpdateInstallation.command("/bin/sh", ["-c", "trap '' TERM; sleep 30 & wait"], timeout: 0.15) }
        precondition(Date().timeIntervalSince(start) < 3)
        print("Launcher update installation tests passed: mock swap/rollback, receipt routing/identity, OS, live locks, failed-attach cleanup and bounded timeout; no real App update")
    }
}
