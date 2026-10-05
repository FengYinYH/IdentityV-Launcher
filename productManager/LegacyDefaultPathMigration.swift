import Foundation
import Darwin

/// Performs the one-time RC1 default-root rename. The operation only follows
/// game roots whose current manager records point at `<oldRoot>/{CN,Global}/game`
/// and whose game executable has the expected PE header. It never searches for
/// installations and never copies game data.
enum LegacyDefaultPathMigration {
    enum FailurePoint: Equatable {
        case afterRootRename
        case afterFirstLink
        case afterFirstRecord
        /// Models process death: leave the durable journal and partially moved
        /// tree intact so the next invocation exercises recovery.
        case interruptedAfterRootRename
    }

    enum Outcome: Equatable {
        case migrated
        case noLegacyRoot
        case notManagerOwned
        case recoveredInterruptedMigration
        case alreadyMigrated
    }

    enum MigrationError: LocalizedError, Equatable {
        case gameRunning
        case targetConflict
        case lockUnavailable
        case invalid(String)
        case transaction(String)
        var errorDescription: String? {
            switch self {
            case .gameRunning: return "游戏仍在运行；请正常退出游戏后再迁移默认目录。"
            case .targetConflict: return "新游戏目录已存在；为避免覆盖现有数据，已拒绝迁移。"
            case .lockUnavailable: return "无法取得默认目录迁移锁。"
            case .invalid(let text), .transaction(let text): return text
            }
        }
    }

    struct Request {
        let oldRoot: URL
        let newRoot: URL
        let supportDirectory: URL
        let recordFiles: [URL]
        let mountedVolume: (String) -> URL?
        let isGameRunning: () -> Bool
        let failurePoint: FailurePoint?

        init(
            oldRoot: URL,
            newRoot: URL,
            supportDirectory: URL,
            recordFiles: [URL],
            mountedVolume: @escaping (String) -> URL?,
            isGameRunning: @escaping () -> Bool,
            failurePoint: FailurePoint? = nil
        ) {
            self.oldRoot = oldRoot
            self.newRoot = newRoot
            self.supportDirectory = supportDirectory
            self.recordFiles = recordFiles
            self.mountedVolume = mountedVolume
            self.isGameRunning = isGameRunning
            self.failurePoint = failurePoint
        }
    }

    private struct FileSnapshot: Codable {
        let path: String
        let original: Data
        let updated: Data
        let permissions: Int
    }

    private struct LinkSnapshot: Codable {
        let path: String
        let originalTarget: String
        let updatedTarget: String
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        let oldRoot: String
        let newRoot: String
        let backupPath: String
        let recordFiles: [FileSnapshot]
        let links: [LinkSnapshot]
        var phase: String
    }

    private struct ManagedLocation {
        let volumeUUID: String
        let relativePath: String
    }

    private struct OwnedGame {
        let product: String
        let root: URL
        let prefix: URL?
    }

    private struct PlannedRecord {
        let url: URL
        let original: Data
        let updated: Data
        let permissions: Int
    }

    private struct PlannedLink {
        let path: URL
        let originalTarget: String
        let updatedTarget: String
    }

    private static let fileManager = FileManager.default
    private static let journalName = ".legacy-default-path-migration.json"
    private static let lockName = ".legacy-default-path-migration.lock"
    private static let supportedRecordNames: Set<String> = ["products.json", "installation.json"]
    private static let maxRecordBytes = 1_048_576

    /// Lets status refresh decide whether it needs the product-manager mutation
    /// lock before invoking `run`. It deliberately includes an interrupted
    /// transaction even when the old root has already been renamed.
    static func needsMigration(_ request: Request) -> Bool {
        pathExists(request.oldRoot) || pathExists(request.supportDirectory.appendingPathComponent(journalName))
    }

    /// Reverses a committed one-time rename only when the new tree, affected
    /// records, and recorded links still exactly match the migration output.
    /// The snapshot is small config/link metadata; the game tree is renamed in
    /// place and never copied or deleted.
    static func restoreCompletedMigration(_ request: Request, backup: URL) throws {
        try validateRequestPaths(request)
        return try withMigrationLock(request.supportDirectory) {
            try validateRequestPaths(request)
            guard !request.isGameRunning() else { throw MigrationError.gameRunning }
            let journalURL = request.supportDirectory.appendingPathComponent(journalName)
            guard !pathExists(journalURL) else { throw error("存在未恢复迁移事务；请先运行迁移恢复。") }
            try requireRegularFile(backup, message: "迁移备份不是普通文件。")
            let data = try Data(contentsOf: backup)
            guard data.count < 4_000_000,
                  let journal = try? JSONDecoder().decode(Journal.self, from: data),
                  journal.schemaVersion == 1,
                  journal.phase == "committed",
                  journal.oldRoot == request.oldRoot.path,
                  journal.newRoot == request.newRoot.path,
                  backupURL(journal, request: request)?.path == backup.standardizedFileURL.path,
                  !pathExists(request.oldRoot), pathExists(request.newRoot) else {
                throw error("已完成迁移快照与当前目录不匹配；未修改数据。")
            }
            for snapshot in journal.recordFiles {
                let file = URL(fileURLWithPath: snapshot.path)
                guard isDirectChild(file, of: request.supportDirectory),
                      (try? Data(contentsOf: file)) == snapshot.updated else {
                    throw error("状态记录已在迁移后变化；为避免覆盖新状态，未回退。")
                }
            }
            for snapshot in journal.links {
                let link = URL(fileURLWithPath: snapshot.path)
                guard try fileManager.destinationOfSymbolicLink(atPath: link.path) == snapshot.updatedTarget else {
                    throw error("prefix 链接已在迁移后变化；为避免覆盖新状态，未回退。")
                }
            }
            var rollback = journal
            rollback.phase = "prepared"
            try writeJournal(rollback, at: journalURL)
            try recover(journalURL: journalURL, request: request)
        }
    }

    static func run(_ request: Request) throws -> Outcome {
        // Validate the support directory before open(O_CREAT): even a rejected
        // symlink must not receive a lock-file write through its target.
        try validateRequestPaths(request)
        return try withMigrationLock(request.supportDirectory) {
            try validateRequestPaths(request)

            let journalURL = request.supportDirectory.appendingPathComponent(journalName)
            if fileManager.fileExists(atPath: journalURL.path) {
                guard !request.isGameRunning() else {
                    throw MigrationError.gameRunning
                }
                try recover(journalURL: journalURL, request: request)
                return .recoveredInterruptedMigration
            }

            guard pathExists(request.oldRoot) else { return .noLegacyRoot }
            try requireRealDirectory(request.oldRoot, message: "旧游戏根目录不是普通目录。")
            guard !request.isGameRunning() else {
                throw MigrationError.gameRunning
            }
            try requireSameDevice(request.oldRoot, request.newRoot.deletingLastPathComponent())

            let recordURLs = try validatedRecordURLs(request)
            var ownedGames: [OwnedGame] = []
            var plannedRecords: [PlannedRecord] = []
            for recordURL in recordURLs {
                guard pathExists(recordURL) else { continue }
                try requireRegularFile(recordURL, message: "状态记录不是普通文件：\(recordURL.lastPathComponent)")
                let original = try Data(contentsOf: recordURL)
                guard original.count <= maxRecordBytes else { throw error("状态记录超过允许大小。") }
                var json = try parseJSON(original, file: recordURL)
                let found = try transformRecord(
                    json: &json,
                    fileName: recordURL.lastPathComponent,
                    request: request
                )
                ownedGames.append(contentsOf: found.games)
                if found.changed {
                    let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                    let attributes = try fileManager.attributesOfItem(atPath: recordURL.path)
                    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
                    plannedRecords.append(PlannedRecord(url: recordURL, original: original, updated: updated, permissions: permissions))
                }
            }

            guard !ownedGames.isEmpty else { return .notManagerOwned }
            guard !pathExists(request.newRoot) else { throw MigrationError.targetConflict }
            let uniqueGames = deduplicateGames(ownedGames)
            let plannedLinks = try planLinks(for: uniqueGames, request: request)
            let journal = Journal(
                schemaVersion: 1,
                oldRoot: request.oldRoot.path,
                newRoot: request.newRoot.path,
                backupPath: request.supportDirectory.appendingPathComponent("MigrationBackups/rc1-default-root-migration-\(UUID().uuidString).json").path,
                recordFiles: plannedRecords.map {
                    FileSnapshot(path: $0.url.path, original: $0.original, updated: $0.updated, permissions: $0.permissions)
                },
                links: plannedLinks.map {
                    LinkSnapshot(path: $0.path.path, originalTarget: $0.originalTarget, updatedTarget: $0.updatedTarget)
                },
                phase: "prepared"
            )
            try writeJournal(journal, at: journalURL)

            do {
                try renameDirectory(request.oldRoot, to: request.newRoot)
                if request.failurePoint == .interruptedAfterRootRename {
                    throw InterruptedMigrationError()
                }
                if request.failurePoint == .afterRootRename { throw error("测试故障：旧根目录已重命名。") }

                for (index, link) in plannedLinks.enumerated() {
                    try replaceSymlink(at: link.path, with: link.updatedTarget)
                    if index == 0, request.failurePoint == .afterFirstLink {
                        throw error("测试故障：首个受管链接已更新。")
                    }
                }
                for (index, record) in plannedRecords.enumerated() {
                    try atomicWrite(record.updated, to: record.url, permissions: record.permissions)
                    if index == 0, request.failurePoint == .afterFirstRecord {
                        throw error("测试故障：首条受管记录已更新。")
                    }
                }

                var committed = journal
                committed.phase = "committed"
                try writeJournal(committed, at: journalURL)
                try writeCommittedBackup(committed, request: request)
                try fileManager.removeItem(at: journalURL)
                return .migrated
            } catch is InterruptedMigrationError {
                throw MigrationError.transaction("迁移已按故障注入中断；下次调用会先恢复事务。")
            } catch {
                do {
                    try recover(journalURL: journalURL, request: request)
                } catch {
                    throw MigrationError.transaction("迁移失败且自动回滚未完成，保留恢复日志：\(error.localizedDescription)")
                }
                throw error
            }
        }
    }

    private struct InterruptedMigrationError: Error {}

    private static func transformRecord(
        json: inout Any,
        fileName: String,
        request: Request
    ) throws -> (games: [OwnedGame], changed: Bool) {
        guard var root = json as? [String: Any] else { throw error("状态记录顶层不是 JSON object。") }
        var games: [OwnedGame] = []
        var changed = false

        switch fileName {
        case "products.json":
            guard number(root["schemaVersion"]) == 1 else { throw error("products.json 版本不受支援。") }
            guard let rawInstallations = root["installations"] else { return ([], false) }
            if var keyed = rawInstallations as? [String: Any] {
                for product in ["mainland", "global"] {
                    guard var installation = keyed[product] as? [String: Any] else { continue }
                    if let game = try ownedGame(product: product, installation: &installation, request: request) {
                        games.append(game)
                        keyed[product] = installation
                        changed = true
                    }
                }
                if changed { root["installations"] = keyed }
            } else if var pairs = rawInstallations as? [Any] {
                guard pairs.count.isMultiple(of: 2) else { throw error("products.json installations 数组不完整。") }
                var seen = Set<String>()
                for index in stride(from: 0, to: pairs.count, by: 2) {
                    guard let product = pairs[index] as? String,
                          var installation = pairs[index + 1] as? [String: Any],
                          seen.insert(product).inserted else {
                        throw error("products.json installations 数组键值无效或重复。")
                    }
                    guard product == "mainland" || product == "global" else { continue }
                    if let game = try ownedGame(product: product, installation: &installation, request: request) {
                        games.append(game)
                        pairs[index + 1] = installation
                        changed = true
                    }
                }
                if changed { root["installations"] = pairs }
            } else {
                throw error("products.json installations 类型不受支援。")
            }

        case "installation.json":
            guard number(root["schemaVersion"]) == 1 else { throw error("installation.json 版本不受支援。") }
            guard var engines = root["engines"] as? [String: Any] else { throw error("installation.json 缺少 engines object。") }
            for engineID in engines.keys.sorted() {
                guard var engine = engines[engineID] as? [String: Any] else { throw error("installation.json engine 记录无效。") }
                guard let rawLocation = engine["gameRoot"] else { continue }
                guard let location = location(from: rawLocation) else { throw error("installation.json gameRoot 位置无效。") }
                guard let product = try productForOwnedRoot(location, request: request) else { continue }
                let gameRoot = gameRoot(for: product, request: request)
                try validateOwnedGameRoot(gameRoot)
                engine["gameRoot"] = try updatedLocation(rawLocation, location: location, request: request)
                if let prefixValue = engine["prefix"] {
                    let prefix = try resolvePrefix(prefixValue, request: request)
                    games.append(OwnedGame(product: product, root: gameRoot, prefix: prefix))
                } else {
                    games.append(OwnedGame(product: product, root: gameRoot, prefix: nil))
                }
                engines[engineID] = engine
                changed = true
            }
            if changed { root["engines"] = engines }

        default:
            throw error("不支持的状态文件：\(fileName)")
        }

        json = root
        return (games, changed)
    }

    private static func ownedGame(
        product: String,
        installation: inout [String: Any],
        request: Request
    ) throws -> OwnedGame? {
        guard let rawGameRoot = installation["gameRoot"] else { return nil }
        guard let gameLocation = location(from: rawGameRoot) else { throw error("products.json gameRoot 位置无效。") }
        guard let recordedProduct = try productForOwnedRoot(gameLocation, request: request) else { return nil }
        guard recordedProduct == product else { return nil }
        let root = gameRoot(for: product, request: request)
        try validateOwnedGameRoot(root)
        installation["gameRoot"] = try updatedLocation(rawGameRoot, location: gameLocation, request: request)
        let prefix: URL?
        if let rawPrefix = installation["prefix"] {
            prefix = try resolvePrefix(rawPrefix, request: request)
        } else {
            prefix = nil
        }
        return OwnedGame(product: product, root: root, prefix: prefix)
    }

    private static func productForOwnedRoot(_ location: ManagedLocation, request: Request) throws -> String? {
        guard let volume = request.mountedVolume(location.volumeUUID) else { return nil }
        let volumeRoot = volume.standardizedFileURL
        guard let actualUUID = try? volumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              actualUUID.caseInsensitiveCompare(location.volumeUUID) == .orderedSame,
              isDescendant(request.oldRoot, of: volumeRoot) else { return nil }
        let oldRelative = relativePath(from: volumeRoot, to: request.oldRoot)
        let product: String
        if location.relativePath == oldRelative + "/CN/game" { product = "mainland" }
        else if location.relativePath == oldRelative + "/Global/game" { product = "global" }
        else { return nil }
        let resolved = try resolve(location, request: request)
        let expected = request.oldRoot.appendingPathComponent(product == "mainland" ? "CN/game" : "Global/game")
        guard resolved.path == expected.standardizedFileURL.path else { return nil }
        return product
    }

    private static func validateOwnedGameRoot(_ root: URL) throws {
        try requireRealDirectory(root, message: "记录的 CN/Global/game 不是普通目录。")
        let executables = ["dwrg.exe", "DWRG/dwrg.exe", "IdentityV/dwrg.exe"]
        guard executables.contains(where: { hasMZHeader(root.appendingPathComponent($0)) }) else {
            throw error("记录的游戏目录缺少有效 MZ 游戏文件；已拒绝迁移。")
        }
    }

    private static func gameRoot(for product: String, request: Request) -> URL {
        request.oldRoot.appendingPathComponent(product == "mainland" ? "CN" : "Global", isDirectory: true)
            .appendingPathComponent("game", isDirectory: true)
    }

    private static func hasMZHeader(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2), data.count == 2 else { return false }
        return data[data.startIndex] == 0x4d && data[data.startIndex + 1] == 0x5a
    }

    private static func resolvePrefix(_ value: Any, request: Request) throws -> URL {
        guard let loc = location(from: value) else { throw error("受管 prefix 位置无效。") }
        let prefix = try resolve(loc, request: request)
        try requireRealDirectory(prefix, message: "受管 prefix 不是普通目录。")
        return prefix
    }

    private static func resolve(_ location: ManagedLocation, request: Request) throws -> URL {
        let parts = location.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !location.volumeUUID.isEmpty, !location.relativePath.hasPrefix("/"), !parts.isEmpty,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let volume = request.mountedVolume(location.volumeUUID) else {
            throw error("受管位置无法解析；已拒绝迁移。")
        }
        let volumeURL = volume.standardizedFileURL
        guard let actualUUID = try? volumeURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              actualUUID.caseInsensitiveCompare(location.volumeUUID) == .orderedSame else {
            throw error("受管位置的磁盘身份与记录不符。")
        }
        let candidate = volumeURL.appendingPathComponent(location.relativePath).standardizedFileURL
        guard isDescendant(candidate, of: volumeURL), pathExists(candidate) else {
            throw error("受管位置越界或不存在；已拒绝迁移。")
        }
        return candidate
    }

    private static func planLinks(for games: [OwnedGame], request: Request) throws -> [PlannedLink] {
        var planned: [String: PlannedLink] = [:]
        let groups = Dictionary(grouping: games.compactMap { game -> (URL, OwnedGame)? in
            guard let prefix = game.prefix else { return nil }
            return (prefix, game)
        }, by: { $0.0.path })
        for entries in groups.values {
            guard let prefix = entries.first?.0 else { continue }
            let associatedGames = entries.map(\.1)
            for game in associatedGames {
                let cName = game.product == "mainland" ? "IdentityV" : "IdentityVGlobal"
                let cLink = prefix.appendingPathComponent("drive_c/Games/\(cName)")
                try considerLink(at: cLink, allowedRoots: [game.root], request: request, into: &planned)
            }

            let gameRoots = associatedGames.map(\.root)
            let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
            guard pathExists(dosdevices) else { continue }
            try requireRealDirectory(dosdevices, message: "prefix 的 dosdevices 不是普通目录。")
            for name in try fileManager.contentsOfDirectory(atPath: dosdevices.path).sorted() {
                let link = dosdevices.appendingPathComponent(name)
                let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
                guard let target else { continue }
                let absolute = targetURL(target, link: link)
                guard isDescendant(absolute, of: request.oldRoot) else { continue }
                if name.lowercased() == "d:" {
                    throw error("dosdevices D: 指向旧游戏根，但归属不明；已拒绝迁移。")
                }
                var allowed: [URL] = gameRoots
                if name.lowercased() == "y:" { allowed.append(contentsOf: gameRoots.map { $0.deletingLastPathComponent() }) }
                try addLink(at: link, target: target, resolvedTarget: absolute, allowedRoots: allowed, request: request, into: &planned)
            }
        }
        return planned.values.sorted { $0.path.path < $1.path.path }
    }

    private static func considerLink(
        at path: URL,
        allowedRoots: [URL],
        request: Request,
        into planned: inout [String: PlannedLink]
    ) throws {
        guard pathExists(path) else { return }
        guard isSymlink(path) else { return }
        let target = try fileManager.destinationOfSymbolicLink(atPath: path.path)
        let resolved = targetURL(target, link: path)
        guard isDescendant(resolved, of: request.oldRoot) else { return }
        try addLink(at: path, target: target, resolvedTarget: resolved, allowedRoots: allowedRoots, request: request, into: &planned)
    }

    private static func addLink(
        at path: URL,
        target: String,
        resolvedTarget: URL,
        allowedRoots: [URL],
        request: Request,
        into planned: inout [String: PlannedLink]
    ) throws {
        guard allowedRoots.contains(where: { isDescendant(resolvedTarget, of: $0) }) else {
            throw error("发现指向旧游戏根但无法证明归属的 prefix 链接：\(path.lastPathComponent)")
        }
        let updatedResolved = replacingPrefix(resolvedTarget.path, old: request.oldRoot.path, new: request.newRoot.path)
        let updatedTarget: String
        if target.hasPrefix("/") {
            updatedTarget = updatedResolved
        } else {
            updatedTarget = relativePath(from: path.deletingLastPathComponent(), to: URL(fileURLWithPath: updatedResolved))
        }
        let item = PlannedLink(path: path, originalTarget: target, updatedTarget: updatedTarget)
        if let old = planned[path.path], old.originalTarget != target {
            throw error("prefix 链接快照重复且不一致。")
        }
        planned[path.path] = item
    }

    private static func recover(journalURL: URL, request: Request) throws {
        try requireRegularFile(journalURL, message: "迁移恢复日志不是普通文件。")
        let data = try Data(contentsOf: journalURL)
        guard data.count < 4_000_000,
              let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.schemaVersion == 1,
              journal.oldRoot == request.oldRoot.path,
              journal.newRoot == request.newRoot.path,
              journal.recordFiles.allSatisfy({ supportedRecordNames.contains(URL(fileURLWithPath: $0.path).lastPathComponent) && isDirectChild(URL(fileURLWithPath: $0.path), of: request.supportDirectory) }) else {
            throw error("迁移恢复日志身份或结构无效；未修改任何状态。")
        }
        guard journal.phase == "prepared" || journal.phase == "committed" else {
            throw error("迁移恢复日志阶段无效；未修改任何状态。")
        }
        guard backupURL(journal, request: request) != nil else {
            throw error("迁移恢复日志的备份路径越界。")
        }

        guard !request.isGameRunning() else { throw MigrationError.gameRunning }
        // A journal is durable input and may be stale or corrupted. Validate
        // every affected path and its current before/after value before the
        // first rename, so recovery never changes the game-root name and only
        // then discovers that a link or record was not ours.
        try validateJournalState(journal, request: request)
        let oldExists = pathExists(request.oldRoot)
        let newExists = pathExists(request.newRoot)
        if journal.phase == "committed" {
            guard !oldExists, newExists else { throw error("已完成事务的目录状态冲突；未清理恢复日志。") }
            try writeCommittedBackup(journal, request: request)
            try fileManager.removeItem(at: journalURL)
            return
        }
        guard oldExists != newExists else {
            throw error("中断事务的旧/新目录同时存在或同时缺失；未覆盖数据。")
        }
        if newExists { try renameDirectory(request.newRoot, to: request.oldRoot) }

        for snapshot in journal.links {
            let path = URL(fileURLWithPath: snapshot.path)
            let current = try fileManager.destinationOfSymbolicLink(atPath: path.path)
            if current == snapshot.updatedTarget {
                try replaceSymlink(at: path, with: snapshot.originalTarget)
            } else if current != snapshot.originalTarget {
                throw error("受管链接在恢复过程中被外部更改；保留恢复日志并停止。")
            }
        }
        for snapshot in journal.recordFiles {
            let url = URL(fileURLWithPath: snapshot.path)
            guard isDirectChild(url, of: request.supportDirectory), pathExists(url) else {
                throw error("恢复日志记录路径缺失或越界。")
            }
            let current = try Data(contentsOf: url)
            guard current == snapshot.original || current == snapshot.updated else {
                throw error("受管状态文件在事务中被外部更改；保留恢复日志并停止。")
            }
            if current == snapshot.updated { try atomicWrite(snapshot.original, to: url, permissions: snapshot.permissions) }
        }
        try fileManager.removeItem(at: journalURL)
    }

    private static func validateJournalState(_ journal: Journal, request: Request) throws {
        var prefixRoots = Set<String>()
        for snapshot in journal.recordFiles {
            let file = URL(fileURLWithPath: snapshot.path).standardizedFileURL
            guard supportedRecordNames.contains(file.lastPathComponent), isDirectChild(file, of: request.supportDirectory) else {
                throw error("恢复日志记录路径越界。")
            }
            let current = try Data(contentsOf: file)
            guard current == snapshot.original || current == snapshot.updated else {
                throw error("受管状态文件在事务中被外部更改；保留恢复日志并停止。")
            }
            let originalObject = try parseJSON(snapshot.original, file: file)
            let prefixes = try prefixLocations(in: originalObject, fileName: file.lastPathComponent, request: request)
            for prefix in prefixes {
                try requireRealDirectory(prefix, message: "恢复日志关联的 prefix 已不可用。")
                prefixRoots.insert(prefix.standardizedFileURL.path)
            }
        }
        for snapshot in journal.links {
            let link = URL(fileURLWithPath: snapshot.path).standardizedFileURL
            try validateJournalLinkPath(link, prefixes: prefixRoots)
            guard isSymlink(link) else {
                throw error("事务链接缺失或不再是符号链接；保留恢复日志并停止。")
            }
            let current = try fileManager.destinationOfSymbolicLink(atPath: link.path)
            guard current == snapshot.originalTarget || current == snapshot.updatedTarget else {
                throw error("受管链接在事务中被外部更改；保留恢复日志并停止。")
            }
            let originalResolved = targetURL(snapshot.originalTarget, link: link)
            let updatedResolved = targetURL(snapshot.updatedTarget, link: link)
            guard isDescendant(originalResolved, of: request.oldRoot),
                  updatedResolved.path == replacingPrefix(originalResolved.path, old: request.oldRoot.path, new: request.newRoot.path) else {
                throw error("恢复日志链接目标不匹配新旧迁移根；未修改状态。")
            }
        }
    }

    private static func prefixLocations(in json: Any, fileName: String, request: Request) throws -> [URL] {
        guard let root = json as? [String: Any] else { throw error("恢复日志中的原始记录格式无效。") }
        var values: [Any] = []
        if fileName == "products.json" {
            guard let raw = root["installations"] else { return [] }
            if let keyed = raw as? [String: Any] {
                for product in ["mainland", "global"] {
                    if let installation = keyed[product] as? [String: Any], let prefix = installation["prefix"] { values.append(prefix) }
                }
            } else if let pairs = raw as? [Any], pairs.count.isMultiple(of: 2) {
                for index in stride(from: 0, to: pairs.count, by: 2) {
                    guard let product = pairs[index] as? String else { throw error("恢复日志中的 products.json 键无效。") }
                    if (product == "mainland" || product == "global"),
                       let installation = pairs[index + 1] as? [String: Any],
                       let prefix = installation["prefix"] { values.append(prefix) }
                }
            } else { throw error("恢复日志中的 products.json installations 无效。") }
        } else {
            guard let engines = root["engines"] as? [String: Any] else { throw error("恢复日志中的 installation.json engines 无效。") }
            for engine in engines.values {
                guard let object = engine as? [String: Any] else { throw error("恢复日志中的 engine 无效。") }
                if let prefix = object["prefix"] { values.append(prefix) }
            }
        }
        var result: [URL] = []
        for value in values {
            guard let location = location(from: value) else { throw error("恢复日志中的 prefix 位置无效。") }
            let prefix = try resolve(location, request: request)
            guard isDescendant(prefix, of: request.supportDirectory) else { throw error("恢复日志 prefix 不在管理器状态目录下。") }
            result.append(prefix)
        }
        return result
    }

    private static func validateJournalLinkPath(_ link: URL, prefixes: Set<String>) throws {
        for prefixPath in prefixes {
            let prefix = URL(fileURLWithPath: prefixPath, isDirectory: true)
            let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
            let games = prefix.appendingPathComponent("drive_c/Games", isDirectory: true)
            let dos = prefix.appendingPathComponent("dosdevices", isDirectory: true)
            if link.deletingLastPathComponent().path == games.path,
               ["IdentityV", "IdentityVGlobal"].contains(link.lastPathComponent) {
                try requireRealDirectory(driveC, message: "恢复日志的 C: 链接父目录无效。")
                try requireRealDirectory(games, message: "恢复日志的 C: 链接父目录无效。")
                return
            }
            if link.deletingLastPathComponent().path == dos.path,
               link.lastPathComponent.lowercased() != "d:" {
                try requireRealDirectory(dos, message: "恢复日志的 DOS 链接父目录无效。")
                return
            }
        }
        throw error("恢复日志中的链接路径不属于已记录 prefix。")
    }

    private static func writeJournal(_ journal: Journal, at url: URL) throws {
        let data = try JSONEncoder().encode(journal)
        try atomicWrite(data, to: url, permissions: 0o600)
    }

    private static func writeCommittedBackup(_ journal: Journal, request: Request) throws {
        guard journal.phase == "committed", let backup = backupURL(journal, request: request) else {
            throw error("迁移备份路径无效。")
        }
        let directory = backup.deletingLastPathComponent()
        if pathExists(directory) {
            try requireRealDirectory(directory, message: "迁移备份目录不是普通目录。")
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let owner = try fileManager.attributesOfItem(atPath: directory.path)[.ownerAccountID] as? NSNumber
        guard owner?.uint32Value == geteuid() else { throw error("迁移备份目录归属异常；已拒绝写入。") }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let bytes = try JSONEncoder().encode(journal)
        if pathExists(backup) {
            try requireRegularFile(backup, message: "迁移备份目标不是普通文件。")
            guard try Data(contentsOf: backup) == bytes else { throw error("迁移备份目标已存在且内容不同；未覆盖既有快照。") }
            return
        }
        try atomicWrite(bytes, to: backup, permissions: 0o600)
    }

    private static func backupURL(_ journal: Journal, request: Request) -> URL? {
        let candidate = URL(fileURLWithPath: journal.backupPath).standardizedFileURL
        let directory = request.supportDirectory.appendingPathComponent("MigrationBackups", isDirectory: true).standardizedFileURL
        guard isDirectChild(candidate, of: directory),
              candidate.lastPathComponent.hasPrefix("rc1-default-root-migration-") else { return nil }
        return candidate
    }

    private static func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func replaceSymlink(at path: URL, with target: String) throws {
        let temporary = path.deletingLastPathComponent().appendingPathComponent(".\(path.lastPathComponent).migration-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
        let status = temporary.path.withCString { source in path.path.withCString { destination in rename(source, destination) } }
        guard status == 0 else { throw error("无法原子更新 prefix 链接：\(path.lastPathComponent)") }
    }

    private static func renameDirectory(_ source: URL, to destination: URL) throws {
        // EXCL closes the guard-then-rename race: a concurrently created
        // destination is never replaced, even when it is an empty directory.
        let status = source.path.withCString { from in destination.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) } }
        guard status == 0 else { throw error("无法原子重命名游戏目录（errno \(errno)）。") }
    }

    private static func validateRequestPaths(_ request: Request) throws {
        let old = request.oldRoot.standardizedFileURL
        let new = request.newRoot.standardizedFileURL
        let support = request.supportDirectory.standardizedFileURL
        guard old.path == request.oldRoot.path, new.path == request.newRoot.path, support.path == request.supportDirectory.path,
              old.deletingLastPathComponent().path == new.deletingLastPathComponent().path,
              old.lastPathComponent == "第五人格", new.lastPathComponent == "IdentityV" else {
            throw error("迁移根目录必须是同级的第五人格和 IdentityV。")
        }
        try requireRealDirectory(support, message: "启动器状态目录不是普通目录。")
        let recordURLs = try validatedRecordURLs(request)
        guard !recordURLs.isEmpty else { throw error("迁移需要明确传入 products.json 或 installation.json。") }
        for path in [old, new] where pathExists(path) { try rejectSymlink(path) }
    }

    private static func validatedRecordURLs(_ request: Request) throws -> [URL] {
        var result: [URL] = []
        for url in request.recordFiles {
            let normalized = url.standardizedFileURL
            guard isDirectChild(normalized, of: request.supportDirectory),
                  supportedRecordNames.contains(normalized.lastPathComponent),
                  !result.contains(where: { $0.path == normalized.path }) else {
                throw error("迁移记录文件必须是状态目录内明确的 products.json/installation.json。")
            }
            result.append(normalized)
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func withMigrationLock<T>(_ support: URL, body: () throws -> T) throws -> T {
        let lockURL = support.appendingPathComponent(lockName)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw MigrationError.lockUnavailable }
        defer { close(descriptor) }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        guard flock(descriptor, LOCK_EX) == 0 else { throw MigrationError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func parseJSON(_ data: Data, file: URL) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data, options: [.mutableContainers, .fragmentsAllowed]) }
        catch { throw MigrationError.invalid("无法读取受管状态 \(file.lastPathComponent)：\(error.localizedDescription)") }
    }

    private static func location(from value: Any) -> ManagedLocation? {
        guard let object = value as? [String: Any],
              let uuid = object["volumeUUID"] as? String,
              let relative = object["relativePath"] as? String else { return nil }
        return ManagedLocation(volumeUUID: uuid, relativePath: relative)
    }

    private static func updatedLocation(_ original: Any, location: ManagedLocation, request: Request) throws -> [String: Any] {
        var object = original as? [String: Any] ?? [:]
        guard let volume = request.mountedVolume(location.volumeUUID) else { throw error("无法更新受管位置。") }
        let volumePath = volume.standardizedFileURL.path
        guard request.oldRoot.path.hasPrefix(volumePath == "/" ? "/" : volumePath + "/"),
              request.newRoot.path.hasPrefix(volumePath == "/" ? "/" : volumePath + "/") else { throw error("迁移目录不在受管卷内。") }
        let oldRelative = relativePath(from: volume, to: request.oldRoot)
        let newRelative = relativePath(from: volume, to: request.newRoot)
        let updated = replacingPrefix(location.relativePath, old: oldRelative, new: newRelative)
        guard updated != location.relativePath else { throw error("受管 gameRoot 无法相对迁移根目录更新。") }
        object["relativePath"] = updated
        return object
    }

    private static func deduplicateGames(_ games: [OwnedGame]) -> [OwnedGame] {
        var seen = Set<String>()
        return games.filter { seen.insert("\($0.product)|\($0.root.path)|\($0.prefix?.path ?? "")").inserted }
    }

    private static func targetURL(_ target: String, link: URL) -> URL {
        if target.hasPrefix("/") { return URL(fileURLWithPath: target).standardizedFileURL }
        return URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
    }

    private static func relativePath(from base: URL, to target: URL) -> String {
        let baseParts = base.standardizedFileURL.pathComponents
        let targetParts = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseParts.count, targetParts.count), baseParts[common] == targetParts[common] { common += 1 }
        let ups = Array(repeating: "..", count: baseParts.count - common)
        return (ups + Array(targetParts.dropFirst(common))).joined(separator: "/")
    }

    private static func replacingPrefix(_ value: String, old: String, new: String) -> String {
        guard value == old || value.hasPrefix(old + "/") else { return value }
        return new + value.dropFirst(old.count)
    }

    private static func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let c = child.standardizedFileURL.path
        let p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }

    private static func isDirectChild(_ child: URL, of parent: URL) -> Bool {
        child.standardizedFileURL.deletingLastPathComponent().path == parent.standardizedFileURL.path
    }

    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) == 0 }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func rejectSymlink(_ url: URL) throws {
        guard !isSymlink(url) else { throw error("迁移根目录是符号链接；已拒绝跟随。") }
    }

    private static func requireRealDirectory(_ url: URL, message: String) throws {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else { throw error(message) }
    }

    private static func requireRegularFile(_ url: URL, message: String) throws {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { throw error(message) }
    }

    private static func requireSameDevice(_ source: URL, _ destinationParent: URL) throws {
        var sourceInfo = stat(); var parentInfo = stat()
        guard source.path.withCString({ stat($0, &sourceInfo) }) == 0,
              destinationParent.path.withCString({ stat($0, &parentInfo) }) == 0,
              sourceInfo.st_dev == parentInfo.st_dev else {
            throw error("旧根和新根不在同一文件系统；原子迁移不可用。")
        }
    }

    private static func error(_ message: String) -> MigrationError { .invalid(message) }
}
