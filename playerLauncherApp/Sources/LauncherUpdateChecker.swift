import Foundation

/// SemVer precedence, without integer conversion (arbitrarily large components).
/// GitHub tags may have the project's conventional leading `v`.
struct LauncherVersion: Comparable {
    let core: [String]
    let prerelease: [String]

    init?(_ tag: String) {
        let raw = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        guard raw.range(of: pattern, options: .regularExpression) == raw.startIndex..<raw.endIndex else { return nil }
        let precedence = raw.split(separator: "+", maxSplits: 1)[0]
        let parts = precedence.split(separator: "-", maxSplits: 1)
        core = parts[0].split(separator: ".").map(String.init)
        prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
        guard !prerelease.contains(where: { Self.numeric($0) && $0.count > 1 && $0.hasPrefix("0") }) else { return nil }
    }

    private static func numeric(_ value: String) -> Bool { value.utf8.allSatisfy { (48...57).contains($0) } }
    private static func numberLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for (a, b) in zip(lhs.core, rhs.core) where a != b { return numberLess(a, b) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = numeric(a), bn = numeric(b)
            if an != bn { return an }
            return an ? numberLess(a, b) : a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct LauncherReleaseAsset: Decodable {
    let name: String
    let size: Int64
    let digest: String?
    let state: String
    let browser_download_url: String
}

struct LauncherGitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    var assets: [LauncherReleaseAsset] = []

    enum CodingKeys: String, CodingKey { case tag_name, draft, prerelease, published_at, assets }
    init(tag_name: String, draft: Bool, prerelease: Bool, published_at: String?, assets: [LauncherReleaseAsset] = []) {
        self.tag_name = tag_name; self.draft = draft; self.prerelease = prerelease; self.published_at = published_at; self.assets = assets
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tag_name = try values.decode(String.self, forKey: .tag_name)
        draft = try values.decode(Bool.self, forKey: .draft)
        prerelease = try values.decode(Bool.self, forKey: .prerelease)
        published_at = try values.decodeIfPresent(String.self, forKey: .published_at)
        assets = try values.decodeIfPresent([LauncherReleaseAsset].self, forKey: .assets) ?? []
    }

    var pageURL: URL? {
        guard LauncherVersion(tag_name) != nil else { return nil }
        return URL(string: "https://github.com/FengYinYH/IdentityV-Launcher/releases/tag/\(tag_name)")
    }
}

enum LauncherUpdateOutcome {
    case available(LauncherGitHubRelease)
    case current
    case noReleases
}

enum LauncherUpdateError: Error, Equatable {
    case invalidVersion, network, invalidResponse, incomplete, busy
    case retryAfter(Date)
}

/// No startup polling, credentials, settings writes, downloads or installation.
/// Cache lifetime is one process. Only a complete successful traversal commits
/// page bodies/ETags, so a failed later page cannot certify a stale newest version.
actor LauncherUpdateChecker {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct Page { let data: Data; let etag: String?; let hasNext: Bool }
    private var pages: [Int: Page] = [:]
    private var lastSuccess: (Date, [LauncherGitHubRelease])?
    private var nextAttempt = Date.distantPast
    private var isChecking = false
    private let transport: Transport
    private let now: () -> Date
    private let maxPages: Int

    init(maxPages: Int = 10, now: @escaping () -> Date = Date.init, transport: Transport? = nil) {
        self.maxPages = max(1, maxPages)
        self.now = now
        if let transport { self.transport = transport }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw LauncherUpdateError.invalidResponse }
                return (data, response)
            }
        }
    }

    static func select(_ releases: [LauncherGitHubRelease], current: LauncherVersion) -> LauncherUpdateOutcome {
        let candidates = releases.compactMap { release -> (LauncherGitHubRelease, LauncherVersion)? in
            guard !release.draft, release.published_at != nil,
                  let version = LauncherVersion(release.tag_name), release.pageURL != nil else { return nil }
            return (release, version)
        }
        guard let latest = candidates.max(by: { $0.1 < $1.1 }) else { return .noReleases }
        return latest.1 > current ? .available(latest.0) : .current
    }

    func check(currentVersion: String) async throws -> LauncherUpdateOutcome {
        guard let current = LauncherVersion(currentVersion) else { throw LauncherUpdateError.invalidVersion }
        guard !isChecking else { throw LauncherUpdateError.busy }
        let start = now()
        // A short successful cache prevents repeated manual clicks consuming
        // the shared anonymous-IP quota. No stale success is returned on error.
        if let success = lastSuccess, start.timeIntervalSince(success.0) < 60 {
            return Self.select(success.1, current: current)
        }
        guard start >= nextAttempt else { throw LauncherUpdateError.retryAfter(nextAttempt) }
        isChecking = true
        nextAttempt = start.addingTimeInterval(60)
        defer { isChecking = false }
        var collected: [LauncherGitHubRelease] = []
        var replacement: [Int: Page] = [:]
        do {
            for page in 1...maxPages {
                try Task.checkCancellation()
                let url = URL(string: "https://api.github.com/repos/FengYinYH/IdentityV-Launcher/releases?per_page=100&page=\(page)")!
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("IdentityV-Launcher", forHTTPHeaderField: "User-Agent")
                if let etag = pages[page]?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                let (received, response) = try await transport(request)
                try Task.checkCancellation()
                if response.statusCode == 403 || response.statusCode == 429 {
                    let retry = Self.retryDate(response, now: now())
                    nextAttempt = max(nextAttempt, retry)
                    throw LauncherUpdateError.retryAfter(nextAttempt)
                }
                let body: Data
                switch response.statusCode {
                case 200: body = received
                case 304:
                    guard let cached = pages[page] else { throw LauncherUpdateError.invalidResponse }
                    body = cached.data
                default: throw LauncherUpdateError.network
                }
                guard body.count <= 8 * 1024 * 1024,
                      let releases = try? JSONDecoder().decode([LauncherGitHubRelease].self, from: body) else {
                    throw LauncherUpdateError.invalidResponse
                }
                collected.append(contentsOf: releases)
                // Follow our own bounded page numbers, never server-supplied
                // URLs. Link is authoritative, including an exactly full page.
                let hasNext = (response.value(forHTTPHeaderField: "Link") ?? "").split(separator: ",").contains { $0.contains("rel=\"next\"") }
                // A 304 may omit Link; cached body length tells us whether a
                // following page must be revalidated before declaring success.
                let needsNext = hasNext || releases.count == 100 || (response.statusCode == 304 && pages[page]?.hasNext == true)
                replacement[page] = Page(data: body, etag: response.value(forHTTPHeaderField: "ETag") ?? (response.statusCode == 304 ? pages[page]?.etag : nil), hasNext: needsNext)
                if !needsNext {
                    pages = replacement
                    lastSuccess = (now(), collected)
                    return Self.select(collected, current: current)
                }
            }
            throw LauncherUpdateError.incomplete
        } catch let error as LauncherUpdateError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw LauncherUpdateError.network }
    }

    static func retryDate(_ response: HTTPURLResponse, now: Date) -> Date {
        var retry = now.addingTimeInterval(60)
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(raw), seconds.isFinite { retry = max(retry, now.addingTimeInterval(seconds)) }
            else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                if let date = formatter.date(from: raw) { retry = max(retry, date) }
            }
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
           let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let seconds = TimeInterval(raw), seconds.isFinite {
            retry = max(retry, Date(timeIntervalSince1970: seconds))
        }
        return retry
    }
}
