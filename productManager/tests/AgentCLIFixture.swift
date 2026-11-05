import Foundation
@main enum Fixture {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "agent" { exit(AgentCLI.main(Array(args.dropFirst()))) }
        if args.first == "remove-preview" {
            print("{\"schemaVersion\":1,\"productId\":\"global\",\"gamePath\":\"/fixture/TEST-ONLY-game\",\"externalGameRoot\":false,\"removalToken\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"targets\":[{\"kind\":\"gameRoot\",\"path\":\"/fixture/TEST-ONLY-game\"}]}")
            return
        }
        if args.contains("--fixture-slow") {
            fputs("{\"event\":\"progress\",\"bytesWritten\":42}\n", stderr)
            fflush(stderr)
            Thread.sleep(forTimeInterval: 20)
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
