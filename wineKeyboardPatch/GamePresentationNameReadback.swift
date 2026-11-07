import AppKit

// Read another, explicitly supplied probe PID. No activation or window APIs
// that change state; owner metadata is not a screenshot or pixel capture.
guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid) else { exit(2) }
let expected = CommandLine.arguments[2]
let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
let owners = windows.compactMap { $0[kCGWindowOwnerName as String] as? String }
let result: [String: Any] = ["pid": pid, "localizedName": app.localizedName ?? "", "ownerNames": owners, "active": app.isActive]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
// Existing WindowServer owner labels may remain cached after LS changes.
// Preserve them as evidence; do not claim the LS update refreshed that cache.
guard app.localizedName == expected, !app.isActive, !owners.isEmpty else { exit(1) }
