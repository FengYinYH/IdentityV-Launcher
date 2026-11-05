import Foundation
@main enum Fixture {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "fixture-login-download", args.count >= 2 {
            if args.contains("--fixture-download-fail") { exit(7) }
            if args.contains("--fixture-download-slow") { Thread.sleep(forTimeInterval: 10) }
            if args.contains("--fixture-download-short") { Thread.sleep(forTimeInterval: 2) }
            if args.contains("--fixture-download-late-fail") { Thread.sleep(forTimeInterval: 5); exit(7) }
            if args.contains("--fixture-download-late-130") { Thread.sleep(forTimeInterval: 5); exit(130) }
            if args.contains("--fixture-download-late-crash") {
                signal(SIGTERM, SIG_IGN)
                fputs("{\"phase\":\"fixture-ready\"}\n", stderr); fflush(stderr)
                Thread.sleep(forTimeInterval: 2); raise(SIGKILL)
            }
            let output = URL(fileURLWithPath: args[1])
            try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data("fixture".utf8).write(to: output)
            fputs("{\"schemaVersion\":1,\"phase\":\"verifying\",\"bytesWritten\":1,\"totalBytesExpected\":1}\n", stderr); fflush(stderr)
            print(output.path)
            return
        }
        if args.first == "fixture-login-install" {
            if args.contains("--fixture-install-crash") { raise(SIGKILL) }
            if args.contains("--fixture-install-fail") { exit(7) }
            if args.contains("--fixture-install-timeout") { Thread.sleep(forTimeInterval: 3) }
            if args.contains("--fixture-install-slow") { Thread.sleep(forTimeInterval: 2) }
            return
        }
        if args.first == "handoff-self-test" {
            var before = AgentPrivilegeHandoff()
            before.requestCancel()
            precondition(!before.commit() && before.outcome(exitCode: nil) == "cancelled")
            var after = AgentPrivilegeHandoff()
            precondition(after.commit())
            after.requestCancel()
            precondition(after.cancellationRequested && after.outcome(exitCode: nil) == "unknown")
            precondition(after.outcome(exitCode: 0) == "succeeded")
            precondition(after.outcome(exitCode: 1) == "failed")
            precondition(!after.commit())
            print("Conservative privilege handoff state tests passed")
            return
        }
        if args.first == "agent" { exit(AgentCLI.main(Array(args.dropFirst()))) }
        if args.first == "remove-preview" {
            print("{\"schemaVersion\":1,\"productId\":\"global\",\"gamePath\":\"/fixture/TEST-ONLY-game\",\"externalGameRoot\":false,\"removalToken\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"targets\":[{\"kind\":\"gameRoot\",\"path\":\"/fixture/TEST-ONLY-game\"}]}")
            return
        }
        if args.contains("--fixture-control"), let index = args.firstIndex(of: "--destination-parent"), index + 1 < args.count {
            let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            let work = root.appendingPathComponent("work", isDirectory: true)
            if args.contains("--fixture-work-symlink") {
                let other = root.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString, isDirectory: true)
                try! FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                try! FileManager.default.createSymbolicLink(at: work, withDestinationURL: other)
            } else {
                try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            }
            let markerProduct = args.contains("--fixture-bad-marker") ? "global" : "mainland"
            _ = FileManager.default.createFile(atPath: root.appendingPathComponent(".identityv-direct-install.json").path, contents: Data("{\"schemaVersion\":1,\"product\":\"\(markerProduct)\",\"phase\":\"downloading\"}".utf8))
            let control = work.appendingPathComponent("download-control.json")
            func emit(_ state: String) { fputs("{\"event\":\"progress\",\"phase\":\"downloading\",\"coreState\":\"\(state)\"}\n", stderr); fflush(stderr) }
            emit("2")
            var last: UInt64 = 0
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if let data = try? Data(contentsOf: control), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sequence = value["sequence"] as? UInt64, sequence > last, let action = value["action"] as? String {
                    last = sequence
                    if !args.contains("--fixture-no-ack") { emit(action == "pause" ? "6" : "2") }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return
        }
        if args.contains("--fixture-timeout") { Thread.sleep(forTimeInterval: 3) }
        if args.contains("--fixture-crash") { raise(SIGKILL) }
        if args.contains("--fixture-slow") {
            fputs("{\"event\":\"progress\",\"bytesWritten\":42}\n", stderr)
            fflush(stderr)
            Thread.sleep(forTimeInterval: args.contains("--fixture-short") ? 2 : 20)
        }
        if args.contains("--fixture-cooperative-cancel") {
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler { exit(130) }; source.resume()
            fputs("{\"event\":\"progress\",\"bytesWritten\":42}\n", stderr); fflush(stderr)
            dispatchMain()
        }
        if args.contains("--fixture-unrequested-130") { exit(130) }
        if args.contains("--fixture-fail") { fputs("phase=fixture error=E42 token=private-value\n", stderr); exit(7) }
        print("{\"schemaVersion\":1,\"fixture\":true}")
    }
}
