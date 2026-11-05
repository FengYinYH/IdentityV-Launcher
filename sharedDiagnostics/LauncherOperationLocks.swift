import Foundation
import Darwin
import CryptoKit

/// Live kernel leases, not task.json/PID guesses. Order is admission, then
/// product mutation. Updater install transport must not hold a shared lease
/// while its helper waits for the exclusive lease.
final class LauncherOperationLease {
    private var descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static var supportDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/IdentityVOnMac", isDirectory: true)
    }
    static func acquire(_ name: String, exclusive: Bool, directory: URL = supportDirectory) throws -> LauncherOperationLease {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(name).path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0, flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd); throw failure()
        }
        return LauncherOperationLease(fd)
    }
    static var realUserTemporaryDirectory: URL {
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 0 else { return FileManager.default.temporaryDirectory.resolvingSymlinksInPath() }
        var buffer = [CChar](repeating: 0, count: count)
        _ = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, count)
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).resolvingSymlinksInPath()
    }
    static func admissionDirectory(application: URL? = nil) -> URL {
        var identity = application ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if application == nil {
            while identity.path != "/" && identity.pathExtension.lowercased() != "app" { identity.deleteLastPathComponent() }
            if identity.path == "/" { identity = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent() }
        }
        // Foundation deliberately shortens /private/tmp and /private/var;
        // POSIX realpath provides one physical identity for App aliases and
        // non-Foundation callers computing the same resource key.
        let canonical: String
        if let resolved = realpath(identity.path, nil) { canonical = String(cString: resolved); free(resolved) }
        else { canonical = identity.standardizedFileURL.path }
        let key = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return realUserTemporaryDirectory.appendingPathComponent("IdentityVLauncherLeases", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }
    static func admission(exclusive: Bool, application: URL? = nil) throws -> LauncherOperationLease {
        try acquire("launcher-operation-admission.lock", exclusive: exclusive, directory: admissionDirectory(application: application))
    }
    static func mutation() throws -> LauncherOperationLease { try acquire("product-manager.lock", exclusive: true) }
    static func failure() -> NSError {
        NSError(domain: "IdentityVOperationLock", code: 1, userInfo: [NSLocalizedDescriptionKey: "另一个安装、更新或游戏操作仍在进行，请稍后重试。"])
    }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
