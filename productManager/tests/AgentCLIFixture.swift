import Foundation
@main enum Fixture {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "agent" { exit(AgentCLI.main(Array(args.dropFirst()))) }
        if args.contains("--fixture-slow") {
            fputs("{\"event\":\"progress\",\"bytesWritten\":42}\n", stderr)
            fflush(stderr)
            Thread.sleep(forTimeInterval: 20)
        }
        if args.contains("--fixture-fail") { fputs("phase=fixture error=E42 token=private-value\n", stderr); exit(7) }
        print("{\"schemaVersion\":1,\"fixture\":true}")
    }
}
