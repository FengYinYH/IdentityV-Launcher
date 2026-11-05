import Foundation

private final class Clock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

private actor Responses {
    var queue: [(Int, Data, [String: String])] = []
    var requests: [URLRequest] = []
    func add(_ status: Int = 200, _ body: Data, _ headers: [String: String] = [:]) {
        queue.append((status, body, headers))
    }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
        let (status, data, headers) = queue.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private actor Gate {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main
enum LauncherUpdateCheckerSelfTest {
    static func release(_ tag: String, draft: Bool = false, pre: Bool = false, published: Bool = true) -> LauncherGitHubRelease {
        LauncherGitHubRelease(tag_name: tag, draft: draft, prerelease: pre, published_at: published ? "2026-11-05T00:00:00Z" : nil)
    }
    static func body(_ tags: [String]) -> Data {
        let rows = tags.map { ["tag_name": $0, "draft": false, "prerelease": $0.contains("-"), "published_at": "2026-11-05T00:00:00Z"] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: rows)
    }
    static func available(_ outcome: LauncherUpdateOutcome, _ tag: String) {
        guard case .available(let release) = outcome, release.tag_name == tag else { fatalError("Expected \(tag)") }
        precondition(release.pageURL?.host == "github.com")
    }
    static func current(_ outcome: LauncherUpdateOutcome) {
        guard case .current = outcome else { fatalError("Expected no newer release") }
    }
    static func failure(_ expected: LauncherUpdateError, _ operation: () async throws -> LauncherUpdateOutcome) async {
        do { _ = try await operation(); fatalError("Expected error \(expected)") }
        catch let error as LauncherUpdateError { precondition(error == expected, "Got \(error), expected \(expected)") }
        catch { fatalError("Unexpected error \(error)") }
    }
    static func main() async throws {
        let order = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for pair in zip(order, order.dropFirst()) { precondition(LauncherVersion(pair.0)! < LauncherVersion(pair.1)!) }
        precondition(LauncherVersion("v1.0.0-rc.9")! < LauncherVersion("1.0.0-rc.10")!)
        precondition(LauncherVersion("999999999999999999999.0.0")! > LauncherVersion("99999999999999999999.0.0")!)
        precondition(LauncherVersion("1.0.0+first") == LauncherVersion("v1.0.0+second"))
        for invalid in ["1.2", "01.2.3", "1.2.3-01", "1.2.3-", "1.2.3\n", "x1.2.3", "1.2.3/path", "1.2.3+", "1.2.3+hello/world"] {
            precondition(LauncherVersion(invalid) == nil, invalid)
        }
        let rc = LauncherVersion("1.0.0-rc.5")!
        let stable = LauncherVersion("1.0.0")!
        available(LauncherUpdateChecker.select([release("v1.0.0-rc.10", pre: true), release("v1.0.0-rc.6", pre: true)], current: rc), "v1.0.0-rc.10")
        available(LauncherUpdateChecker.select([release("v1.0.0"), release("v1.0.0-rc.99", pre: true)], current: rc), "v1.0.0")
        available(LauncherUpdateChecker.select([release("v1.0.0"), release("v2.0.0-rc.1", pre: true)], current: stable), "v2.0.0-rc.1")
        available(LauncherUpdateChecker.select([release("v2.0.0", pre: true)], current: stable), "v2.0.0")
        available(LauncherUpdateChecker.select([release("v1.1.0"), release("v1.2.0", draft: true), release("v1.3.0", published: false), release("invalid")], current: stable), "v1.1.0")
        current(LauncherUpdateChecker.select([release("v1.0.0-rc.4", pre: true)], current: rc))
        if case .noReleases = LauncherUpdateChecker.select([], current: rc) {} else { fatalError("Empty list") }

        let clock = Clock(), responses = Responses()
        let checker = LauncherUpdateChecker(now: { clock.date }, transport: { try await responses.send($0) })
        await responses.add(200, body(["v1.0.0-rc.6"]), ["ETag": "first", "Link": "<https://api.github.com/ignored>; rel=\"next\""])
        await responses.add(200, body(["v1.0.0-rc.10"]), ["ETag": "second"])
        available(try await checker.check(currentVersion: "1.0.0-rc.5"), "v1.0.0-rc.10")
        available(try await checker.check(currentVersion: "1.0.0-rc.5"), "v1.0.0-rc.10")
        let firstRequestCount = await responses.requests.count
        precondition(firstRequestCount == 2, "Success cache should suppress repeated clicks")
        clock.date.addTimeInterval(61)
        // Both 304s deliberately omit Link and ETag. Cached next-page metadata
        // and ETags must survive, including for short pages with explicit Link.
        await responses.add(304, Data())
        await responses.add(304, Data())
        available(try await checker.check(currentVersion: "1.0.0-rc.5"), "v1.0.0-rc.10")
        let requests = await responses.requests
        precondition(requests[2].value(forHTTPHeaderField: "If-None-Match") == "first")
        precondition(requests[3].value(forHTTPHeaderField: "If-None-Match") == "second")
        precondition(requests[3].url!.absoluteString.hasSuffix("page=2"))
        clock.date.addTimeInterval(61)
        // A failed refresh must not return the formerly successful RC10.
        await responses.add(200, body(["v1.0.0-rc.11"]), ["ETag": "new", "Link": "<ignored>; rel=\"next\""])
        await responses.add(500, Data())
        await failure(.network) { try await checker.check(currentVersion: "1.0.0-rc.5") }
        clock.date.addTimeInterval(61)
        await responses.add(304, Data())
        await responses.add(304, Data())
        available(try await checker.check(currentVersion: "1.0.0-rc.5"), "v1.0.0-rc.10")

        let freshResponses = Responses()
        let fresh = LauncherUpdateChecker(now: { clock.date }, transport: { try await freshResponses.send($0) })
        await freshResponses.add(304, Data())
        await failure(.invalidResponse) { try await fresh.check(currentVersion: "1.0.0") }
        clock.date.addTimeInterval(61)
        await freshResponses.add(200, Data("broken".utf8))
        await failure(.invalidResponse) { try await fresh.check(currentVersion: "1.0.0") }
        clock.date.addTimeInterval(61)
        await failure(.network) { try await fresh.check(currentVersion: "1.0.0") }
        clock.date.addTimeInterval(61)
        await freshResponses.add(429, Data(), ["Retry-After": "120"])
        let until = clock.date.addingTimeInterval(120)
        await failure(.retryAfter(until)) { try await fresh.check(currentVersion: "1.0.0") }
        await failure(.retryAfter(until)) { try await fresh.check(currentVersion: "1.0.0") }
        let failedRequestCount = await freshResponses.requests.count
        precondition(failedRequestCount == 4)

        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 403, httpVersion: nil,
                                      headerFields: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(clock.date.addingTimeInterval(3600).timeIntervalSince1970)])!
        precondition(LauncherUpdateChecker.retryDate(response, now: clock.date) == clock.date.addingTimeInterval(3600))
        let dateResponse = HTTPURLResponse(url: response.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "Fri, 15 Jan 2027 09:00:00 GMT"])!
        precondition(LauncherUpdateChecker.retryDate(dateResponse, now: Date(timeIntervalSince1970: 0)).timeIntervalSince1970 == 1_800_003_600)

        let boundedResponses = Responses()
        let bounded = LauncherUpdateChecker(maxPages: 1, transport: { try await boundedResponses.send($0) })
        await boundedResponses.add(200, body(Array(repeating: "v1.0.0", count: 100)))
        await failure(.incomplete) { try await bounded.check(currentVersion: "1.0.0") }
        await failure(.invalidVersion) { try await bounded.check(currentVersion: "unknown") }

        let gate = Gate()
        let slow = LauncherUpdateChecker(transport: { request in
            await gate.wait()
            return (body([]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let inFlight = Task { try await slow.check(currentVersion: "1.0.0") }
        while await !gate.started { await Task.yield() }
        await failure(.busy) { try await slow.check(currentVersion: "1.0.0") }
        await gate.release()
        _ = try await inFlight.value

        let offline = LauncherUpdateChecker(transport: { _ in throw URLError(.timedOut) })
        await failure(.network) { try await offline.check(currentVersion: "1.0.0") }
        let missing = LauncherUpdateChecker(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        await failure(.network) { try await missing.check(currentVersion: "1.0.0") }
        let empty = LauncherUpdateChecker(transport: { request in
            (body([]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        if case .noReleases = try await empty.check(currentVersion: "1.0.0") {} else { fatalError("Empty response") }
        print("Launcher update checker tests passed")
    }
}
