import Foundation

@main
struct LegacyDefaultPathMigrationSelfTestMain {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rawRoot = env["IDV_RC1_MIGRATION_FIXTURE_ROOT"],
              let expectedUUID = env["IDV_RC1_MIGRATION_VOLUME_UUID"] else {
            throw NSError(domain: "LegacyDefaultPathMigrationSelfTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "set IDV_RC1_MIGRATION_FIXTURE_ROOT and IDV_RC1_MIGRATION_VOLUME_UUID"])
        }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
        guard let actualUUID = try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              actualUUID.caseInsensitiveCompare(expectedUUID) == .orderedSame else {
            throw NSError(domain: "LegacyDefaultPathMigrationSelfTest", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "fixture volume UUID does not match the caller's expected volume"])
        }
        try LegacyDefaultPathMigrationSelfTest.run(
            migrate: LegacyDefaultPathMigration.run,
            restore: { request, backup in try LegacyDefaultPathMigration.restoreCompletedMigration(request, backup: backup) },
            at: root
        )
    }
}
