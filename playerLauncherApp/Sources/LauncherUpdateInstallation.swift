import AppKit
import CryptoKit
import Darwin
import Foundation

struct LauncherUpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct LauncherUpdatePlan: Codable {
    var schemaVersion = 1
    let token: String
    let root: URL
    let target: URL
    let staged: URL
    let backup: URL
    let expectedVersion: String
    let oldPID: Int32
    var otherOldPIDs: [Int32] = []
    var agentInitiated = false
    var currentVersion = ""
    var currentBuild = ""
    var oldPIDs: [Int32] { ([oldPID] + otherOldPIDs).filter { $0 > 1 } }
    var receipt: URL { root.appendingPathComponent("started.json") }
}

/// Shared by the running launcher and its first-party detached installer. No
/// privilege escalation, shell interpolation, arbitrary destination or payload
/// execution is involved. The only executable payload is an authenticated App.
enum LauncherUpdateInstallation {
    static let bundleID = "com.fengyin.identityv.launcher"
    static let teamID = "VNTCB2984V"
    static let appName = "第五人格启动器.app"
    static let maximumSize: Int64 = 1024 * 1024 * 1024

    static func asset(for release: LauncherGitHubRelease) throws -> LauncherReleaseAsset {
        guard !release.draft, release.published_at != nil, LauncherVersion(release.tag_name) != nil else {
            throw LauncherUpdateFailure(message: "更新版本信息无效。")
        }
        let version = normalized(release.tag_name)
        let name = "IdentityV-Launcher-\(version).dmg"
        let matches = release.assets.filter { $0.name == name && $0.state == "uploaded" }
        guard matches.count == 1, let asset = matches.first,
              asset.size > 0, asset.size <= maximumSize,
              let digest = asset.digest, digest.range(of: #"^sha256:[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
              asset.browser_download_url == "https://github.com/FengYinYH/IdentityV-Launcher/releases/download/\(release.tag_name)/\(name)" else {
            throw LauncherUpdateFailure(message: "发布版本缺少唯一且可校验的 macOS 安装包。")
        }
        return asset
    }

    static func normalized(_ version: String) -> String { version.hasPrefix("v") ? String(version.dropFirst()) : version }

    /// A fresh process group and regular output file avoid inherited-pipe EOF
    /// hangs. A timed-out owned group gets TERM, then KILL; wait only its PID.
    static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> Data {
        let fm = FileManager.default
        let output = LauncherOperationLease.realUserTemporaryDirectory.appendingPathComponent("IdentityVUpdateCommand-" + UUID().uuidString)
        let fd = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LauncherUpdateFailure(message: "无法创建更新命令输出。") }
        defer { close(fd); try? fm.removeItem(at: output) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let strings = ([executable] + arguments).map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
        defer { strings.forEach { free($0) }; environment.forEach { free($0) } }
        var argv = strings + [nil], envp = environment + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        guard result == 0 else { throw LauncherUpdateFailure(message: "更新校验或安装命令未能启动。") }
        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        var status: Int32 = 0, interrupted = false, outputExceeded = false
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 {
                if errno == EINTR { continue }
                throw LauncherUpdateFailure(message: "无法确认更新命令退出状态。")
            }
            var metadata = stat()
            outputExceeded = fstat(fd, &metadata) == 0 && metadata.st_size > 8 * 1024 * 1024
            if Date() >= deadline || outputExceeded { interrupted = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if interrupted {
            kill(-pid, SIGTERM)
            // Do not reap the leader before escalation: its reserved PID also
            // prevents a recycled process group from being signalled by mistake.
            Thread.sleep(forTimeInterval: 0.5)
            kill(-pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0 && errno == EINTR { }
            throw LauncherUpdateFailure(message: outputExceeded ? "更新命令输出超出限制。" : "更新命令超时，已停止本次命令。")
        }
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else {
            throw LauncherUpdateFailure(message: "更新校验或安装失败；原有用户数据未修改。")
        }
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 8 * 1024 * 1024 else { throw LauncherUpdateFailure(message: "更新命令输出超出限制。") }
        return try Data(contentsOf: output)
    }

    static func verifyPackage(_ url: URL, asset: LauncherReleaseAsset) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == asset.size else {
            throw LauncherUpdateFailure(message: "安装包大小不匹配，已停止更新。")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard asset.digest?.lowercased() == "sha256:" + digest else {
            throw LauncherUpdateFailure(message: "安装包校验失败，已停止更新。")
        }
    }

    static func verifyApp(_ app: URL, expectedVersion: String, gatekeeper: Bool = true) throws {
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["IdentityVReleaseVersion"] as? String == normalized(expectedVersion),
              info["CFBundleExecutable"] as? String == "IdentityVLauncher" else {
            throw LauncherUpdateFailure(message: "新版应用的身份或版本不匹配，已停止更新。")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let minimums = info["LSMinimumSystemVersionByArchitecture"] as? [String: String]
        try validateMinimumSystemVersion(minimums?[architecture] ?? info["LSMinimumSystemVersion"] as? String,
            current: ProcessInfo.processInfo.operatingSystemVersion)
        let requirement = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        // A leading = selects literal requirement source, rather than a file.
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path])
        if gatekeeper { _ = try command("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) }
        let executable = app.appendingPathComponent("Contents/MacOS/IdentityVLauncher")
        let arches = String(decoding: try command("/usr/bin/lipo", ["-archs", executable.path]), as: UTF8.self).split(whereSeparator: \.isWhitespace)
        #if arch(arm64)
        let required = "arm64"
        #else
        let required = "x86_64"
        #endif
        guard arches.contains(Substring(required)) else { throw LauncherUpdateFailure(message: "新版应用不支持此 Mac 的处理器。") }
    }

    static func validateMinimumSystemVersion(_ raw: String?, current: OperatingSystemVersion) throws {
        guard let raw else { return }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { throw LauncherUpdateFailure(message: "新版应用的系统版本要求无效。") }
        let required = parts.compactMap { Int($0) } + Array(repeating: 0, count: 3 - parts.count)
        let actual = [current.majorVersion, current.minorVersion, current.patchVersion]
        for (a, b) in zip(actual, required) where a != b {
            guard a > b else { throw LauncherUpdateFailure(message: "新版应用不支持当前 macOS 版本。") }
            return
        }
    }

    static func mountedPaths() throws -> [URL] {
        let data = try command("/usr/bin/hdiutil", ["info", "-plist"], timeout: 10)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { throw LauncherUpdateFailure(message: "无法确认更新映像挂载状态，临时目录已保留。") }
        return images.flatMap { ($0["system-entities"] as? [[String: Any]]) ?? [] }.compactMap {
            ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        }
    }

    /// Inventory is checked even when attach failed or timed out after mounting.
    /// Unknown mounts or a failed detach preserve the root; never recurse into it.
    static func cleanupRoot(_ root: URL, inventory: () throws -> [URL] = mountedPaths,
        detach: (URL) throws -> Void = { _ = try command("/usr/bin/hdiutil", ["detach", $0.path], timeout: 10) },
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        try validateRoot(root)
        let expected = root.appendingPathComponent("Mount", isDirectory: true).standardizedFileURL.path
        func owned(_ mounts: [URL]) -> [URL] { mounts.filter { $0.path == root.path || $0.path.hasPrefix(root.path + "/") } }
        let mounts = owned(try inventory())
        guard mounts.allSatisfy({ $0.path == expected }) else { throw LauncherUpdateFailure(message: "更新目录中存在未知挂载，已保留临时目录。") }
        for mount in mounts { try detach(mount) }
        guard owned(try inventory()).isEmpty else { throw LauncherUpdateFailure(message: "更新映像尚未卸载，临时目录已保留。") }
        try remove(root)
    }

    static func cleanupPrepared(_ plan: LauncherUpdatePlan, ownsStage: Bool = true) throws {
        try validatePlan(plan)
        if ownsStage, FileManager.default.fileExists(atPath: plan.staged.path) {
            try FileManager.default.removeItem(at: plan.staged)
        }
        try cleanupRoot(plan.root)
    }

    static func validateRoot(_ root: URL) throws {
        let prefix = "IdentityVLauncherUpdate-"
        guard root.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              root.deletingLastPathComponent().resolvingSymlinksInPath().path == LauncherOperationLease.realUserTemporaryDirectory.path,
              root.resolvingSymlinksInPath().path == root.standardizedFileURL.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            throw LauncherUpdateFailure(message: "更新临时目录身份无效。")
        }
    }

    static func validateInstalledBase(_ plan: LauncherUpdatePlan, metadata: NSDictionary?) throws {
        guard metadata?["IdentityVReleaseVersion"] as? String == plan.currentVersion,
              metadata?["CFBundleVersion"] as? String == plan.currentBuild,
              let old = LauncherVersion(plan.currentVersion), let new = LauncherVersion(plan.expectedVersion), new > old else {
            throw LauncherUpdateFailure(message: "已安装版本发生变化，请重新检查更新。")
        }
    }

    static func validateTarget(_ target: URL) throws {
        let canonical = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(appName)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true).appendingPathComponent(appName)
        guard target.standardizedFileURL == canonical || target.standardizedFileURL == home,
              target.resolvingSymlinksInPath() == target.standardizedFileURL,
              getuid() != 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw LauncherUpdateFailure(message: "自动更新需要将启动器安装在可写的“应用程序”目录中；不会自动请求管理员权限。")
        }
    }

    static func ensureNoGame() throws {
        let snapshot = String(decoding: try command("/bin/ps", ["-axo", "command="]), as: UTF8.self)
        // Conservative on purpose: don't relocate embedded runner resources
        // while a Wine game may still reference their installed paths.
        guard !hasActiveOperation(snapshot) else {
            throw LauncherUpdateFailure(message: "请先结束游戏或等待当前安装、下载完成，再更新启动器。")
        }
    }

    static func hasActiveOperation(_ snapshot: String) -> Bool {
        let lower = snapshot.lowercased()
        return ["dwrg.exe", "identityvdownloadsupervisor", "identityvidvlogindownloader", "installidentityvpasswordlesshelpers.command"].contains { lower.contains($0) }
    }

    static func validatePlan(_ plan: LauncherUpdatePlan) throws {
        try validateRoot(plan.root)
        guard plan.schemaVersion == 1, UUID(uuidString: plan.token) != nil,
              plan.root.lastPathComponent == "IdentityVLauncherUpdate-" + plan.token,
              plan.root.deletingLastPathComponent().resolvingSymlinksInPath() == LauncherOperationLease.realUserTemporaryDirectory,
              plan.root.resolvingSymlinksInPath() == plan.root.standardizedFileURL,
              let owner = try? FileManager.default.attributesOfItem(atPath: plan.root.path)[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              plan.staged == plan.target.deletingLastPathComponent().appendingPathComponent(".IdentityVLauncher.update-\(plan.token).app"),
              plan.backup == plan.target.deletingLastPathComponent().appendingPathComponent(".IdentityVLauncher.rollback-\(plan.token).app"),
              plan.oldPID != 1, plan.oldPID >= 0, plan.otherOldPIDs.allSatisfy({ $0 > 1 }),
              Set(plan.oldPIDs).count == plan.oldPIDs.count, LauncherVersion(plan.expectedVersion) != nil else {
            throw LauncherUpdateFailure(message: "更新事务信息无效，已停止安装。")
        }
    }

    /// Paths have already been constrained by validatePlan/validateTarget.
    /// Kept separate so real filesystem failures and rollback can be tested
    /// entirely under a temporary fixture, without touching an installed App.
    static func swap(_ plan: LauncherUpdatePlan, verify: (URL) throws -> Void) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: plan.backup.path) else { throw LauncherUpdateFailure(message: "回退目录已存在，已停止安装。") }
        try fm.moveItem(at: plan.target, to: plan.backup)
        var installed = false
        do {
            try fm.moveItem(at: plan.staged, to: plan.target)
            installed = true
            try verify(plan.target)
        } catch {
            if installed { try fm.removeItem(at: plan.target) }
            guard !fm.fileExists(atPath: plan.target.path) else {
                throw LauncherUpdateFailure(message: "安装目标发生变化，旧版备份已保留。")
            }
            try fm.moveItem(at: plan.backup, to: plan.target)
            throw error
        }
    }

    static func rollback(_ plan: LauncherUpdatePlan) throws {
        let fm = FileManager.default
        // Called only for a target installed by our successful swap, after
        // proving the new process has exited or never launched.
        try fm.removeItem(at: plan.target)
        try fm.moveItem(at: plan.backup, to: plan.target)
    }

    static func boundedRecord(_ url: URL, limit: Int = 65536) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else {
            throw LauncherUpdateFailure(message: "更新记录格式无效。")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw LauncherUpdateFailure(message: "更新记录超出限制。") }
        return data
    }
    static func startupReceipt(_ plan: LauncherUpdatePlan, pid: Int32, bundle: URL, version: String) throws -> Data {
        guard pid > 1, bundle.standardizedFileURL.path == plan.target.standardizedFileURL.path,
              version == normalized(plan.expectedVersion) else { throw LauncherUpdateFailure(message: "更新启动回执身份不匹配。") }
        return try JSONSerialization.data(withJSONObject: ["token": plan.token, "pid": pid, "target": plan.target.standardizedFileURL.path, "version": version])
    }
    static func receiptMatches(_ data: Data, plan: LauncherUpdatePlan, pid: Int32) -> Bool {
        guard data.count <= 65536, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return value["token"] as? String == plan.token && (value["pid"] as? NSNumber)?.int32Value == pid
            && value["target"] as? String == plan.target.standardizedFileURL.path
            && value["version"] as? String == normalized(plan.expectedVersion)
    }
    static func acknowledgeStartup() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard args.count == 3, args[1] == "--launcher-update-receipt" else { return false }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        guard (try? validateRoot(root)) != nil,
              let data = try? boundedRecord(root.appendingPathComponent("plan.json")),
              let plan = try? JSONDecoder().decode(LauncherUpdatePlan.self, from: data),
              (try? validatePlan(plan)) != nil, plan.root.path == root.path,
              let version = Bundle.main.object(forInfoDictionaryKey: "IdentityVReleaseVersion") as? String,
              let receipt = try? startupReceipt(plan, pid: getpid(), bundle: Bundle.main.bundleURL, version: version) else { return false }
        do { try receipt.write(to: plan.receipt, options: .atomic); return true }
        catch { return false }
    }

}

final class LauncherUpdateDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let expected: Int64
    let progress: @Sendable (Double) -> Void
    init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) { self.expected = expected; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expected || totalBytesExpectedToWrite > expected { downloadTask.cancel(); return }
        progress(min(1, Double(totalBytesWritten) / Double(expected)))
    }
}

actor LauncherUpdatePreparer {
    func prepare(_ release: LauncherGitHubRelease, target: URL, oldPIDs: [Int32]? = nil, agentInitiated: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws -> LauncherUpdatePlan {
        let fm = FileManager.default
        try LauncherUpdateInstallation.validateTarget(target)
        try LauncherUpdateInstallation.ensureNoGame()
        let installedVersion = Bundle.main.object(forInfoDictionaryKey: "IdentityVReleaseVersion") as? String ?? ""
        try LauncherUpdateInstallation.verifyApp(target, expectedVersion: installedVersion)
        let asset = try LauncherUpdateInstallation.asset(for: release)
        let token = UUID().uuidString
        let root = LauncherOperationLease.realUserTemporaryDirectory.appendingPathComponent("IdentityVLauncherUpdate-" + token, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let parent = target.deletingLastPathComponent()
        var plan = LauncherUpdatePlan(token: token, root: root, target: target,
                                     staged: parent.appendingPathComponent(".IdentityVLauncher.update-\(token).app"),
                                     backup: parent.appendingPathComponent(".IdentityVLauncher.rollback-\(token).app"),
                                     expectedVersion: release.tag_name, oldPID: oldPIDs?.first ?? (agentInitiated ? 0 : getpid()))
        plan.otherOldPIDs = Array((oldPIDs ?? []).dropFirst())
        plan.agentInitiated = agentInitiated
        plan.currentVersion = installedVersion
        plan.currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        var ownsStage = false
        let mount = root.appendingPathComponent("Mount", isDirectory: true)
        do {
        // Record recovery paths before mounting/copying can create partial state.
        try JSONEncoder().encode(plan).write(to: root.appendingPathComponent("plan.json"), options: .atomic)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let delegate = LauncherUpdateDownloadProgress(expected: asset.size, progress: progress)
        let (download, response) = try await session.download(from: URL(string: asset.browser_download_url)!, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LauncherUpdateFailure(message: "安装包下载失败，请稍后重试。") }
        defer { try? fm.removeItem(at: download) }
        let package = root.appendingPathComponent("release.dmg")
        try fm.moveItem(at: download, to: package)
        try Task.checkCancellation()
        try LauncherUpdateInstallation.verifyPackage(package, asset: asset)
        progress(1)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try LauncherUpdateInstallation.command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, package.path])
        let source = mount.appendingPathComponent(LauncherUpdateInstallation.appName, isDirectory: true)
        try LauncherUpdateInstallation.verifyApp(source, expectedVersion: release.tag_name)
        try LauncherUpdateInstallation.ensureNoGame()
        try Task.checkCancellation()
        guard !fm.fileExists(atPath: plan.staged.path), !fm.fileExists(atPath: plan.backup.path) else { throw LauncherUpdateFailure(message: "更新暂存目录已存在，已停止安装。") }
        try fm.createDirectory(at: plan.staged, withIntermediateDirectories: false)
        ownsStage = true
        _ = try LauncherUpdateInstallation.command("/usr/bin/ditto", [source.path, plan.staged.path], timeout: 180)
        try LauncherUpdateInstallation.verifyApp(plan.staged, expectedVersion: release.tag_name)
        _ = try LauncherUpdateInstallation.command("/usr/bin/hdiutil", ["detach", mount.path])
        try JSONEncoder().encode(plan).write(to: root.appendingPathComponent("plan.json"), options: .atomic)
        guard let helper = Bundle.main.url(forResource: "IdentityVUpdateHelper", withExtension: nil) else { throw LauncherUpdateFailure(message: "启动器缺少更新助手，请重新安装启动器。") }
        let detached = root.appendingPathComponent("IdentityVUpdateHelper")
        try fm.copyItem(at: helper, to: detached)
        return plan
        } catch {
            let original = error
            do { try LauncherUpdateInstallation.cleanupPrepared(plan, ownsStage: ownsStage) }
            catch { throw LauncherUpdateFailure(message: "更新临时文件未能清理，已保留：" + root.path) }
            throw original
        }
    }
}


enum LauncherUpdateTransaction {
    static func start(_ plan: LauncherUpdatePlan, output: FileHandle = .nullDevice) throws -> Process {
        let process = Process()
        process.executableURL = plan.root.appendingPathComponent("IdentityVUpdateHelper")
        process.arguments = ["--apply-update", plan.root.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        return process
    }
    static func waitUntilReady(_ process: Process, plan: LauncherUpdatePlan) async throws {
        for _ in 0..<300 {
            if (try? String(contentsOf: plan.root.appendingPathComponent("ready"), encoding: .utf8)) == plan.token { return }
            guard process.isRunning else { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LauncherUpdateFailure(message: "更新助手未能准备就绪；原版本保持不变。")
    }
    static func authorize(_ plan: LauncherUpdatePlan) throws {
        try LauncherUpdateInstallation.validatePlan(plan)
        try Data(plan.token.utf8).write(to: plan.root.appendingPathComponent("commit"), options: .atomic)
    }
    static func waitForExit(_ process: Process) async -> Int32 {
        await Task.detached { process.waitUntilExit(); return process.terminationStatus }.value
    }
}
