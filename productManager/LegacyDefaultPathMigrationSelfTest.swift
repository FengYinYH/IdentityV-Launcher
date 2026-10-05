import Foundation

/// Shared isolation suite. The manager's own self-test can pass the exact
/// `migrateDefaultPathIfNeeded` entry point, while the standalone harness passes
/// `LegacyDefaultPathMigration.run` directly.
enum LegacyDefaultPathMigrationSelfTest {
    private enum ProductID: String, Codable { case mainland, global }
    private struct Location: Codable {
        let volumeUUID: String
        let relativePath: String
    }
    private struct Installation: Codable {
        var gameRoot: Location?
        var prefix: Location?
        var installedVersion: String?
    }
    private struct ProductState: Codable {
        var schemaVersion = 1
        var selectedProductId: ProductID = .mainland
        var installations: [ProductID: Installation] = [:]
    }

    private struct Scenario {
        let root: URL
        let volumeRoot: URL
        let oldRoot: URL
        let newRoot: URL
        let support: URL
        let mainlandGame: URL
        let globalGame: URL
        let mainlandPrefix: URL
        let globalPrefix: URL
        let productsURL: URL
        let installationURL: URL
        let volumeUUID: String
    }

    static func run(
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome,
        restore: ((LegacyDefaultPathMigration.Request, URL) throws -> Void)? = nil,
        recoveryCompletesMigration: Bool = false,
        at fixtureRoot: URL
    ) throws {
        try requireDirectory(fixtureRoot)
        let volumeRoot = try volumeRoot(of: fixtureRoot)
        let scenario = try makeScenario(at: fixtureRoot.appendingPathComponent("rc1-shape", isDirectory: true), volumeRoot: volumeRoot)
        try testRecordShapeAndSuccessfulMigration(scenario, migrate: migrate, restore: restore)
        try testTargetConflict(at: fixtureRoot.appendingPathComponent("target-conflict", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate)
        try testActiveGameRefusal(at: fixtureRoot.appendingPathComponent("active-game", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate)
        try testNoOwnershipNoOp(at: fixtureRoot.appendingPathComponent("not-owned", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate)
        try testUnknownLinkRefusal(at: fixtureRoot.appendingPathComponent("unknown-link", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate)
        try testRollbackAfterPartialLink(at: fixtureRoot.appendingPathComponent("rollback-link", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate)
        try testRollbackAfterPartialRecord(at: fixtureRoot.appendingPathComponent("rollback-record", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate)
        try testInterruptedJournalRecovery(at: fixtureRoot.appendingPathComponent("journal-recovery", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate, recoveryCompletesMigration: recoveryCompletesMigration)
        try testSymlinkRootRefusal(at: fixtureRoot.appendingPathComponent("symlink-root", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate)
        try testSymlinkSupportRefusalBeforeLockWrite(at: fixtureRoot.appendingPathComponent("symlink-support", isDirectory: true), volumeRoot: volumeRoot, migrate: migrate)
        print("RC1 默认根迁移合成自检通过：真实 JSON 编码形态、记录/链接更新、幂等、冲突/运行保护、恢复和路径拒绝均通过。")
    }

    private static func testRecordShapeAndSuccessfulMigration(
        _ s: Scenario,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome,
        restore: ((LegacyDefaultPathMigration.Request, URL) throws -> Void)?
    ) throws {
        let originalInode = try inode(s.oldRoot)
        let originalProducts = try Data(contentsOf: s.productsURL)
        let raw = try JSONSerialization.jsonObject(with: originalProducts) as! [String: Any]
        guard let pairForm = raw["installations"] as? [Any], pairForm.first as? String != nil else {
            throw failure("ProductState Codable fixture is not the actual alternating installations array shape.")
        }
        let first = try migrate(request(s, migrateFailure: nil))
        guard first == .migrated, !exists(s.oldRoot), exists(s.newRoot), try inode(s.newRoot) == originalInode else {
            throw failure("successful migration did not rename the same game tree exactly once")
        }
        guard linkTarget(s.mainlandPrefix.appendingPathComponent("drive_c/Games/IdentityV")) == s.newRoot.appendingPathComponent("CN/game").path,
              linkTarget(s.mainlandPrefix.appendingPathComponent("dosdevices/y:")) == s.newRoot.appendingPathComponent("CN").path,
              linkTarget(s.mainlandPrefix.appendingPathComponent("dosdevices/x:")) == s.newRoot.appendingPathComponent("CN/game/dwrg.exe").path,
              linkTarget(s.globalPrefix.appendingPathComponent("drive_c/Games/IdentityVGlobal")) == s.newRoot.appendingPathComponent("Global/game").path,
              linkTarget(s.globalPrefix.appendingPathComponent("dosdevices/y:")) == s.newRoot.appendingPathComponent("Global").path else {
            throw failure("C: or managed DOS links did not follow the renamed root")
        }
        guard linkTarget(s.mainlandPrefix.appendingPathComponent("dosdevices/d:")) == s.root.appendingPathComponent("unrelated-D").path else {
            throw failure("unrelated D: link changed")
        }
        try assertRecordPaths(s, expectedBase: s.newRoot)
        try assertUnknownFieldsPreserved(s)

        let afterFirst = try Data(contentsOf: s.productsURL)
        guard try migrate(request(s, migrateFailure: nil)) == .noLegacyRoot,
              try Data(contentsOf: s.productsURL) == afterFirst,
              try inode(s.newRoot) == originalInode else {
            throw failure("repeated migration was not an idempotent no-op")
        }
        if let restore {
            let backups = try FileManager.default.contentsOfDirectory(at: s.support.appendingPathComponent("MigrationBackups"), includingPropertiesForKeys: nil)
            guard backups.count == 1 else { throw failure("committed migration did not retain one small recovery snapshot") }
            let permissions = (try FileManager.default.attributesOfItem(atPath: backups[0].path)[.posixPermissions] as? NSNumber)?.intValue
            guard permissions == 0o600 else { throw failure("migration recovery snapshot is not owner-only") }
            try restore(request(s, migrateFailure: nil), backups[0])
            guard exists(s.oldRoot), !exists(s.newRoot), try inode(s.oldRoot) == originalInode,
                  try Data(contentsOf: s.productsURL) == originalProducts,
                  linkTarget(s.mainlandPrefix.appendingPathComponent("drive_c/Games/IdentityV")) == s.oldRoot.appendingPathComponent("CN/game").path else {
                throw failure("committed snapshot did not safely restore the original tree, records, and links")
            }
        }
    }

    private static func testTargetConflict(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        try FileManager.default.createDirectory(at: s.newRoot, withIntermediateDirectories: true)
        let before = try Data(contentsOf: s.productsURL)
        do {
            _ = try migrate(request(s, migrateFailure: nil))
            throw failure("existing destination was accepted")
        } catch LegacyDefaultPathMigration.MigrationError.targetConflict {}
        guard exists(s.oldRoot), exists(s.newRoot), try Data(contentsOf: s.productsURL) == before else {
            throw failure("target conflict changed a source or record")
        }
    }

    private static func testActiveGameRefusal(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        let before = try Data(contentsOf: s.productsURL)
        do {
            _ = try migrate(request(s, active: true, migrateFailure: nil))
            throw failure("active game was accepted")
        } catch LegacyDefaultPathMigration.MigrationError.gameRunning {}
        guard exists(s.oldRoot), !exists(s.newRoot), try Data(contentsOf: s.productsURL) == before,
              !exists(s.support.appendingPathComponent(".legacy-default-path-migration.json")) else {
            throw failure("active-game refusal mutated migration state")
        }
    }

    private static func testNoOwnershipNoOp(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: s.productsURL)) as! [String: Any]
        var pairs = object["installations"] as! [Any]
        let location = ["volumeUUID": s.volumeUUID, "relativePath": relative(s.root, s.root.appendingPathComponent("unrelated-game"))]
        for index in stride(from: 0, to: pairs.count, by: 2) {
            var item = pairs[index + 1] as! [String: Any]
            item["gameRoot"] = location
            pairs[index + 1] = item
        }
        object["installations"] = pairs
        try writeJSON(object, to: s.productsURL)
        var installation = try JSONSerialization.jsonObject(with: Data(contentsOf: s.installationURL)) as! [String: Any]
        var engines = installation["engines"] as! [String: [String: Any]]
        var engine = engines["rc1-engine"]!
        engine["gameRoot"] = location
        engines["rc1-engine"] = engine
        installation["engines"] = engines
        try writeJSON(installation, to: s.installationURL)
        try FileManager.default.createDirectory(at: s.newRoot, withIntermediateDirectories: true)
        let before = try Data(contentsOf: s.productsURL)
        let beforeInstallation = try Data(contentsOf: s.installationURL)
        guard try migrate(request(s, migrateFailure: nil)) == .notManagerOwned,
              exists(s.oldRoot), exists(s.newRoot), try Data(contentsOf: s.productsURL) == before,
              try Data(contentsOf: s.installationURL) == beforeInstallation else {
            throw failure("unowned path was migrated or records changed")
        }
    }

    private static func testUnknownLinkRefusal(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        let unknown = s.mainlandPrefix.appendingPathComponent("dosdevices/u:")
        try FileManager.default.createSymbolicLink(atPath: unknown.path, withDestinationPath: s.oldRoot.appendingPathComponent("Unowned").path)
        do {
            _ = try migrate(request(s, migrateFailure: nil))
            throw failure("unowned link into old root was accepted")
        } catch let error as LegacyDefaultPathMigration.MigrationError {
            guard case .invalid = error else { throw error }
        }
        guard exists(s.oldRoot), !exists(s.newRoot), linkTarget(unknown) == s.oldRoot.appendingPathComponent("Unowned").path else {
            throw failure("unknown-link refusal changed source state")
        }
    }

    private static func testRollbackAfterPartialLink(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        let before = try Data(contentsOf: s.productsURL)
        var failed = false
        do {
            _ = try migrate(request(s, migrateFailure: .afterFirstLink))
        } catch { failed = true }
        guard failed else { throw failure("link failure injection did not fail") }
        guard exists(s.oldRoot), !exists(s.newRoot), try Data(contentsOf: s.productsURL) == before,
              linkTarget(s.mainlandPrefix.appendingPathComponent("drive_c/Games/IdentityV")) == s.oldRoot.appendingPathComponent("CN/game").path,
              !exists(s.support.appendingPathComponent(".legacy-default-path-migration.json")) else {
            throw failure("partial link failure did not roll back the full transaction")
        }
        guard try migrate(request(s, migrateFailure: nil)) == .migrated else { throw failure("retry after rollback failed") }
    }

    private static func testRollbackAfterPartialRecord(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        let before = try Data(contentsOf: s.productsURL)
        var failed = false
        do {
            _ = try migrate(request(s, migrateFailure: .afterFirstRecord))
        } catch { failed = true }
        guard failed else { throw failure("record failure injection did not fail") }
        guard exists(s.oldRoot), !exists(s.newRoot), try Data(contentsOf: s.productsURL) == before,
              linkTarget(s.globalPrefix.appendingPathComponent("dosdevices/y:")) == s.oldRoot.appendingPathComponent("Global").path else {
            throw failure("partial record failure did not restore records, links, and root")
        }
    }

    private static func testInterruptedJournalRecovery(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome,
        recoveryCompletesMigration: Bool
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        var interrupted = false
        do {
            _ = try migrate(request(s, migrateFailure: .interruptedAfterRootRename))
        } catch { interrupted = true }
        guard interrupted else { throw failure("interruption injection did not leave an interrupted transaction") }
        let journal = s.support.appendingPathComponent(".legacy-default-path-migration.json")
        guard exists(s.newRoot), !exists(s.oldRoot), exists(journal) else { throw failure("interruption fixture did not create pending journal") }
        guard LegacyDefaultPathMigration.needsMigration(request(s, migrateFailure: nil)) else {
            throw failure("needsMigration omitted a pending journal after the old root was renamed")
        }
        let validJournal = try Data(contentsOf: journal)
        var tampered = try JSONSerialization.jsonObject(with: validJournal) as! [String: Any]
        var links = tampered["links"] as! [[String: Any]]
        links[0]["path"] = s.root.appendingPathComponent("unowned-link").path
        tampered["links"] = links
        try JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys]).write(to: journal)
        do {
            _ = try migrate(request(s, migrateFailure: nil))
            throw failure("recovery accepted a journal link outside its recorded prefix")
        } catch let error as LegacyDefaultPathMigration.MigrationError {
            guard case .invalid = error else { throw error }
        }
        guard exists(s.newRoot), !exists(s.oldRoot), exists(journal) else {
            throw failure("invalid journal caused a root rename before link-path validation")
        }
        try validJournal.write(to: journal)
        do {
            _ = try migrate(request(s, active: true, migrateFailure: nil))
            throw failure("recovery ran while game was active")
        } catch LegacyDefaultPathMigration.MigrationError.gameRunning {}
        guard exists(s.newRoot), exists(journal) else { throw failure("active recovery gate changed interrupted state") }
        let recoveryOutcome = try migrate(request(s, migrateFailure: nil))
        if recoveryCompletesMigration {
            guard recoveryOutcome == .migrated, !exists(s.oldRoot), exists(s.newRoot), !exists(journal) else {
                throw failure("manager recovery wrapper did not complete exactly one migration")
            }
        } else {
            guard recoveryOutcome == .recoveredInterruptedMigration,
                  exists(s.oldRoot), !exists(s.newRoot), !exists(journal) else {
                throw failure("next-run recovery did not roll the interrupted rename back")
            }
            guard try migrate(request(s, migrateFailure: nil)) == .migrated,
                  !exists(s.oldRoot), exists(s.newRoot) else {
                throw failure("recovered migration retry failed")
            }
        }
        guard try migrate(request(s, migrateFailure: nil)) == .noLegacyRoot,
              !exists(s.oldRoot), exists(s.newRoot) else {
            throw failure("recovered migration retry was not idempotent")
        }
    }

    private static func testSymlinkRootRefusal(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        let linkOld = s.oldRoot
        let actualOld = s.oldRoot.deletingLastPathComponent().appendingPathComponent("real-legacy", isDirectory: true)
        try FileManager.default.moveItem(at: linkOld, to: actualOld)
        try FileManager.default.createSymbolicLink(atPath: linkOld.path, withDestinationPath: actualOld.path)
        do {
            _ = try migrate(request(s, migrateFailure: nil))
            throw failure("symlink old root was accepted")
        } catch let error as LegacyDefaultPathMigration.MigrationError {
            guard case .invalid = error else { throw error }
        }
        guard exists(linkOld), exists(actualOld), !exists(s.newRoot) else { throw failure("symlink-root refusal moved data") }
    }

    private static func testSymlinkSupportRefusalBeforeLockWrite(
        at root: URL,
        volumeRoot: URL,
        migrate: (LegacyDefaultPathMigration.Request) throws -> LegacyDefaultPathMigration.Outcome
    ) throws {
        let s = try makeScenario(at: root, volumeRoot: volumeRoot)
        let support = s.support
        let realSupport = root.appendingPathComponent("real-support", isDirectory: true)
        try FileManager.default.moveItem(at: support, to: realSupport)
        try FileManager.default.createSymbolicLink(atPath: support.path, withDestinationPath: realSupport.path)
        do {
            _ = try migrate(request(s, migrateFailure: nil))
            throw failure("symlink support directory was accepted")
        } catch let error as LegacyDefaultPathMigration.MigrationError {
            guard case .invalid = error else { throw error }
        }
        guard !exists(realSupport.appendingPathComponent(".legacy-default-path-migration.lock")),
              exists(s.oldRoot), !exists(s.newRoot) else {
            throw failure("support symlink refusal wrote the lock through its target or moved the game tree")
        }
    }

    private static func makeScenario(at root: URL, volumeRoot: URL) throws -> Scenario {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let oldRoot = root.appendingPathComponent("Library/Application Support/第五人格", isDirectory: true)
        let newRoot = oldRoot.deletingLastPathComponent().appendingPathComponent("IdentityV", isDirectory: true)
        let support = root.appendingPathComponent("Library/Application Support/IdentityVOnMac", isDirectory: true)
        let mainlandGame = oldRoot.appendingPathComponent("CN/game", isDirectory: true)
        let globalGame = oldRoot.appendingPathComponent("Global/game", isDirectory: true)
        let mainlandPrefix = support.appendingPathComponent("Prefixes/mainland-fixture", isDirectory: true)
        let globalPrefix = support.appendingPathComponent("Prefixes/global-fixture", isDirectory: true)
        for directory in [mainlandGame, globalGame,
                          mainlandPrefix.appendingPathComponent("drive_c/Games", isDirectory: true),
                          mainlandPrefix.appendingPathComponent("dosdevices", isDirectory: true),
                          globalPrefix.appendingPathComponent("drive_c/Games", isDirectory: true),
                          globalPrefix.appendingPathComponent("dosdevices", isDirectory: true)] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for game in [mainlandGame, globalGame] {
            try Data([0x4d, 0x5a, 0x00, 0x00]).write(to: game.appendingPathComponent("dwrg.exe"))
        }
        let unrelated = root.appendingPathComponent("unrelated-D", isDirectory: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)

        // All fixtures stay below the actual mounted-volume root, matching the
        // manager's ManagedLocation rather than a synthetic subdirectory root.
        let uuid = try volumeUUID(of: volumeRoot)
        func loc(_ url: URL) -> Location { Location(volumeUUID: uuid, relativePath: relative(volumeRoot, url)) }
        let state = ProductState(installations: [
            .mainland: Installation(gameRoot: loc(mainlandGame), prefix: loc(mainlandPrefix), installedVersion: "fixture-cn"),
            .global: Installation(gameRoot: loc(globalGame), prefix: loc(globalPrefix), installedVersion: "fixture-global")
        ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stateData = try encoder.encode(state)
        var stateObject = try JSONSerialization.jsonObject(with: stateData) as! [String: Any]
        stateObject["fixtureExtra"] = ["preserve": true]
        if var pairs = stateObject["installations"] as? [Any] {
            for index in stride(from: 0, to: pairs.count, by: 2) {
                if var item = pairs[index + 1] as? [String: Any] {
                    item["fixtureInstallationExtra"] = "preserve-\(pairs[index])"
                    pairs[index + 1] = item
                }
            }
            stateObject["installations"] = pairs
        }
        let productsURL = support.appendingPathComponent("products.json")
        try writeJSON(stateObject, to: productsURL)

        let installationObject: [String: Any] = [
            "schemaVersion": 1,
            "selectedEngineId": "rc1-engine",
            "lastKnownGoodEngineId": "rc1-engine",
            "fixtureExtra": "preserve-installation",
            "engines": ["rc1-engine": [
                "gameRoot": ["volumeUUID": uuid, "relativePath": loc(mainlandGame).relativePath, "futureLocationField": "keep"],
                "prefix": ["volumeUUID": uuid, "relativePath": loc(mainlandPrefix).relativePath],
                "runtime": ["volumeUUID": uuid, "relativePath": relative(volumeRoot, root.appendingPathComponent("Runtime"))],
                "fixtureEngineExtra": "preserve-engine"
            ]]
        ]
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let installationURL = support.appendingPathComponent("installation.json")
        try writeJSON(installationObject, to: installationURL)

        try fm.createSymbolicLink(atPath: mainlandPrefix.appendingPathComponent("drive_c/Games/IdentityV").path, withDestinationPath: mainlandGame.path)
        try fm.createSymbolicLink(atPath: mainlandPrefix.appendingPathComponent("dosdevices/y:").path, withDestinationPath: mainlandGame.deletingLastPathComponent().path)
        try fm.createSymbolicLink(atPath: mainlandPrefix.appendingPathComponent("dosdevices/x:").path, withDestinationPath: mainlandGame.appendingPathComponent("dwrg.exe").path)
        try fm.createSymbolicLink(atPath: mainlandPrefix.appendingPathComponent("dosdevices/d:").path, withDestinationPath: unrelated.path)
        try fm.createSymbolicLink(atPath: globalPrefix.appendingPathComponent("drive_c/Games/IdentityVGlobal").path, withDestinationPath: globalGame.path)
        try fm.createSymbolicLink(atPath: globalPrefix.appendingPathComponent("dosdevices/y:").path, withDestinationPath: globalGame.deletingLastPathComponent().path)

        return Scenario(root: root, volumeRoot: volumeRoot, oldRoot: oldRoot, newRoot: newRoot, support: support,
                        mainlandGame: mainlandGame, globalGame: globalGame,
                        mainlandPrefix: mainlandPrefix, globalPrefix: globalPrefix,
                        productsURL: productsURL, installationURL: installationURL, volumeUUID: uuid)
    }

    private static func request(
        _ s: Scenario,
        active: Bool = false,
        migrateFailure: LegacyDefaultPathMigration.FailurePoint?
    ) -> LegacyDefaultPathMigration.Request {
        return LegacyDefaultPathMigration.Request(
            oldRoot: s.oldRoot,
            newRoot: s.newRoot,
            supportDirectory: s.support,
            recordFiles: [s.productsURL, s.installationURL],
            mountedVolume: { uuid in uuid.caseInsensitiveCompare(s.volumeUUID) == .orderedSame ? s.volumeRoot : nil },
            isGameRunning: { active },
            failurePoint: migrateFailure
        )
    }

    private static func assertRecordPaths(_ s: Scenario, expectedBase: URL) throws {
        let products = try JSONSerialization.jsonObject(with: Data(contentsOf: s.productsURL)) as! [String: Any]
        guard let pairs = products["installations"] as? [Any], pairs.count == 4 else { throw failure("products.json Codable dictionary shape changed") }
        for index in stride(from: 0, to: pairs.count, by: 2) {
            let product = pairs[index] as! String
            let item = pairs[index + 1] as! [String: Any]
            let location = item["gameRoot"] as! [String: Any]
            let suffix = product == "mainland" ? "CN/game" : "Global/game"
            guard location["relativePath"] as? String == relative(s.volumeRoot, expectedBase.appendingPathComponent(suffix)),
                  location["volumeUUID"] as? String == s.volumeUUID else { throw failure("products.json gameRoot was not updated exactly") }
        }
        let legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: s.installationURL)) as! [String: Any]
        let engine = (legacy["engines"] as! [String: [String: Any]])["rc1-engine"]!
        let game = engine["gameRoot"] as! [String: Any]
        let expected = relative(s.volumeRoot, expectedBase.appendingPathComponent("CN/game"))
        guard game["relativePath"] as? String == expected, game["futureLocationField"] as? String == "keep" else {
            throw failure("installation.json gameRoot path or unknown field was not preserved")
        }
    }

    private static func assertUnknownFieldsPreserved(_ s: Scenario) throws {
        let products = try JSONSerialization.jsonObject(with: Data(contentsOf: s.productsURL)) as! [String: Any]
        guard (products["fixtureExtra"] as? [String: Bool])?["preserve"] == true,
              let pairs = products["installations"] as? [Any],
              pairs.contains(where: { ($0 as? String) == "mainland" }),
              pairs.contains(where: { (($0 as? [String: Any])?["fixtureInstallationExtra"] as? String) == "preserve-mainland" }) else {
            throw failure("products.json unknown fields were not preserved")
        }
        let legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: s.installationURL)) as! [String: Any]
        let engine = (legacy["engines"] as! [String: [String: Any]])["rc1-engine"]!
        guard legacy["fixtureExtra"] as? String == "preserve-installation",
              engine["fixtureEngineExtra"] as? String == "preserve-engine",
              (engine["runtime"] as? [String: String])?["relativePath"]?.hasSuffix("Runtime") == true else {
            throw failure("installation.json unrelated fields or runtime location changed")
        }
    }

    private static func volumeUUID(of url: URL) throws -> String {
        guard let uuid = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw failure("cannot resolve fixture volume UUID")
        }
        return uuid
    }

    private static func volumeRoot(of url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        guard values.volumeUUIDString != nil, let volume = values.volume else { throw failure("cannot resolve fixture volume root") }
        return volume.standardizedFileURL
    }

    private static func relative(_ root: URL, _ child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return String(childPath.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
    }

    private static func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private static func linkTarget(_ url: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func inode(_ url: URL) throws -> UInt64 {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0 else { throw failure("cannot stat fixture directory") }
        return UInt64(value.st_ino)
    }

    private static func requireDirectory(_ url: URL) throws {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
            throw failure("fixture root must be an existing real directory")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LegacyDefaultPathMigrationSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
