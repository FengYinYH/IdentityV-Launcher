import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Small POSIX-only primitives for diagnostic output.  FileManager's create
/// APIs follow an existing final-path symlink, which is unacceptable for
/// unattended capture output.
enum MonitorSecureFS {
    static func lstat(_ url: URL) -> stat? { var value = stat(); return Darwin.lstat(url.path, &value) == 0 ? value : nil }
    static func isPrivateDirectory(_ url: URL) -> Bool {
        guard let s = lstat(url), (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == getuid() else { return false }
        return (s.st_mode & 0o077) == 0 && (s.st_mode & 0o700) == 0o700
    }
    static func isPrivateRegularFile(_ url: URL, allowed: mode_t = 0o600) -> Bool {
        guard let s = lstat(url), (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid() else { return false }
        return (s.st_mode & 0o777) == allowed
    }
    static func isOwnedRegularFile(_ url: URL) -> Bool {
        guard let s = lstat(url), (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid() else { return false }
        return true
    }
    static func createDirectoryOneLevel(_ url: URL, raceHook: (() -> Void)? = nil) -> Bool {
        let existed = lstat(url) != nil
        raceHook?()
        if !existed {
            let result = mkdir(url.path, 0o700)
            guard result == 0 || errno == EEXIST else { return false }
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFDIR, before.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { return false }
        var after = stat()
        return fstat(fd, &after) == 0 && (after.st_mode & S_IFMT) == S_IFDIR && after.st_uid == getuid() && (after.st_mode & 0o777) == 0o700
    }
    static func createExclusiveFile(_ url: URL, mode: mode_t = 0o600) -> FileHandle? {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { return nil }
        guard fchmod(fd, mode) == 0, isPrivateRegularFile(url, allowed: mode) else { Darwin.close(fd); return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func canonical(_ url: URL) -> URL? {
        guard let result = Darwin.realpath(url.path, nil) else { return nil }; defer { free(result) }
        return URL(fileURLWithPath: String(cString: result), isDirectory: true)
    }
    static func isDirectChild(_ child: URL, of root: URL) -> Bool {
        child.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
    }
}

struct VisualMetrics: Codable, Equatable {
    var timestamp: TimeInterval
    var status: String
    var captureFPS: Double?
    var sampleChangedFPS: Double?
    var perceptualVisualFPS: Double?
    var meanSampleDelta: Double?
    var changedSampleRatio: Double?
    var currentUnchangedRunMs: Double?
    var maxUnchangedRunMs: Double?
    var targetPID: Int32
    var isUsable: Bool { status == "capturing" && perceptualVisualFPS != nil }
    var localizedDescription: String {
        guard isUsable else { return "画面变化率：\(status == "未启动" ? "未采集" : status)" }
        return String(format: "画面变化 %.0f 次/秒 · 采样 %.0f 次/秒 · 静止 %.0fms", perceptualVisualFPS ?? 0, captureFPS ?? 0, currentUnchangedRunMs ?? 0)
    }
}

struct VisualFinishResult { let succeeded: Bool; let message: String }

/// Pure, intentionally low-resolution frame comparison. Exact hashes remain
/// diagnostic only; perceptual cadence ignores ordinary TAA/noise shimmer.
enum VisualFrameAnalyzer {
    static func perceptuallyChanged(previous: [UInt8], current: [UInt8]) -> (changed: Bool, mean: Double, ratio: Double) {
        guard previous.count == current.count, !current.isEmpty else { return (true, 255, 1) }
        let deltas = zip(previous, current).map { abs(Int($0) - Int($1)) }
        let mean = Double(deltas.reduce(0, +)) / Double(deltas.count)
        let ratio = Double(deltas.filter { $0 >= 12 }.count) / Double(deltas.count)
        return (mean >= 4.0 && ratio >= 0.045, mean, ratio)
    }
    static func fixtureChecks() -> [Bool] {
        let still = Array(repeating: UInt8(80), count: 64)
        let noise = still.enumerated().map { UInt8(80 + ($0.offset % 3) - 1) }
        let moving = still.enumerated().map { $0.offset % 2 == 0 ? UInt8(160) : UInt8(20) }
        let same = perceptuallyChanged(previous: still, current: still)
        let tiny = perceptuallyChanged(previous: still, current: noise)
        let motion = perceptuallyChanged(previous: still, current: moving)
        return [!same.changed, !tiny.changed, motion.changed, motion.mean > tiny.mean, motion.ratio > tiny.ratio]
    }
}

private func sceneSamples(_ pixel: CVPixelBuffer) -> (exact: UInt64, grid: [UInt8]) {
    CVPixelBufferLockBaseAddress(pixel, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixel) else { return (0, []) }
    let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), stride = CVPixelBufferGetBytesPerRow(pixel)
    let x0 = width * 14 / 100, xs = max(1, width * 68 / 100), y0 = height * 18 / 100, ys = max(1, height * 60 / 100)
    var hash: UInt64 = 1469598103934665603; var grid: [UInt8] = []; grid.reserveCapacity(32 * 18)
    for sy in 0..<18 { let y = min(height - 1, y0 + (sy * ys + ys / 36) / 18); let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for sx in 0..<32 { let x = min(width - 1, x0 + (sx * xs + xs / 64) / 32); let p = x * 4; let b = row[p], g = row[p + 1], r = row[p + 2]; let luma = UInt8((Int(r) * 54 + Int(g) * 183 + Int(b) * 19) >> 8); grid.append(luma); hash ^= UInt64(r) << 16 | UInt64(g) << 8 | UInt64(b); hash &*= 1099511628211 }
    }
    return (hash, grid)
}

/// The ScreenCaptureKit owner stays in the regular toolbox process.  A tiny
/// display-only accessory executable is deliberately separate: AppKit will
/// otherwise remove a regular app's auxiliary window when Wine moves to its
/// own full-screen Space.  The helper reads this value-only stream from stdin;
/// it has no capture framework, entitlement, preferences, or TCC request path.
final class DisplayOverlayHelper {
    private let executableURL: URL
    private var process: Process?
    private var writer: FileHandle?
    init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/IdentityVOverlayDisplay")
    }
    var isRunning: Bool { process?.isRunning == true }
    @discardableResult func show() -> Bool {
        if isRunning { return true }
        stop()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }
        let pipe = Pipe(), child = Process()
        child.executableURL = executableURL
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self, weak child] _ in
            DispatchQueue.main.async {
                guard self?.process === child else { return }
                self?.writer = nil
                self?.process = nil
            }
        }
        do {
            try child.run()
            process = child
            writer = pipe.fileHandleForWriting
            return true
        } catch {
            try? pipe.fileHandleForWriting.close()
            return false
        }
    }
    func publish(_ snapshot: OverlayDisplaySnapshot) {
        guard isRunning, let writer, let data = try? JSONEncoder().encode(snapshot) else { return }
        do { try writer.write(contentsOf: data); try writer.write(contentsOf: Data([10])) }
        catch { stop() }
    }
    func stop() {
        // Closing stdin is the normal ownership boundary: the display helper
        // exits on EOF. A bounded terminate is only fallback cleanup.
        let oldWriter = writer; writer = nil
        try? oldWriter?.close()
        guard let child = process else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
            if child.isRunning { child.terminate() }
        }
        process = nil
    }
    static func fixtureChecks() -> [Bool] {
        let value = OverlayDisplaySnapshot(cpuLine: "CPU 2%", gpuLine: "GPU 50%  70%", targetPID: 1234, hasLiveData: true)
        let roundTrip = (try? JSONDecoder().decode(OverlayDisplaySnapshot.self, from: JSONEncoder().encode(value))) == value
        let unavailable = DisplayOverlayHelper(executableURL: URL(fileURLWithPath: "/private/tmp/IdentityVOverlayDisplay-does-not-exist"))
        return [roundTrip, !unavailable.show(), !unavailable.isRunning]
    }
}

final class VisualCaptureControllerNative: NSObject, SCStreamOutput, SCStreamDelegate {
    var onUpdate: ((VisualMetrics) -> Void)?
    /// Lifecycle and SCStream callbacks share the main queue, avoiding a
    /// capture-callback/start-stop data race. The ROI is only 576 samples.
    private let queue = DispatchQueue.main
    private struct OutputSession {
        let generation: UInt64; let url: URL; let handle: FileHandle
        var writes: Int; var numericWrites: Int; var failed: Bool
        // A start/status row proves the file opened, not that SCK delivered a
        // usable frame. Keep evidence per record, including reused streams.
        var succeeded: Bool { numericWrites > 0 && !failed }
    }
    private struct CaptureStream {
        let native: SCStream?
        let windowID: CGWindowID?
        let isOnScreen: Bool
        let start: @MainActor () async throws -> Void
        let stop: @MainActor () async -> Void
    }
    private var pendingStop: Task<Void, Never>?
#if MONITOR_PROCESS_SELF_TEST
    private var testPermission: (() -> Bool)?
    private var testStream: (@MainActor (Int32) async throws -> CaptureStream)?
#endif
    private var stream: CaptureStream?; private var activePID: Int32?; private var output: OutputSession?; private var frames: [Double] = []; private var exact: [Double] = []; private var perceptual: [Double] = []; private var lastHash: UInt64?; private var lastGrid: [UInt8]?; private var lastTime: Double?; private var unchangedStart: Double?; private var maxUnchanged: Double = 0; private var lastEmit: Double = 0; private var generation: UInt64 = 0; private var pendingStart: Task<Void, Never>?; private var numericSamples = 0; private var currentMetrics = VisualMetrics(timestamp: 0, status: "未启动", captureFPS: nil, sampleChangedFPS: nil, perceptualVisualFPS: nil, meanSampleDelta: nil, changedSampleRatio: nil, currentUnchangedRunMs: nil, maxUnchangedRunMs: nil, targetPID: 0); private let freezeStacks = FreezeStackCaptureController(); private var targetWindowID: CGWindowID?; private var targetWindowVisible = false; private var lastVisibilityCheck: Double = 0; private var targetVisibilityConfirmedAt: Double?; private var visibilityRefreshInFlight = false
    private var overlay = DisplayOverlayHelper()
    func publishOverlay(_ snapshot: OverlayDisplaySnapshot) { overlay.publish(snapshot) }
    var statusDescription: String { currentMetrics.localizedDescription }
    @discardableResult func showOverlay() -> Bool { overlay.show() }
    // The display helper never owns a capture lease. Closing it must neither
    // stop an explicit record nor keep a completed record's screen stream alive.
    func hideOverlay() { overlay.stop() }

    func beginStart(targetPID: Int32, outputURL: URL, automaticFreezeStacks: Bool = false) {
        // A private, exclusive record output is mandatory. No overlay-only or
        // permission-only caller can start sampling without a real record.
        guard output == nil, stream == nil, pendingStart == nil else { return }
        generation &+= 1
        let token = generation
        let previousStop = pendingStop
        pendingStart = Task { @MainActor [weak self] in
            guard let self else { return }
            await previousStop?.value
            await self.performStart(targetPID: targetPID, outputURL: outputURL, automaticFreezeStacks: automaticFreezeStacks, token: token)
            if self.generation == token { self.pendingStart = nil }
        }
    }

    /// Invalidate callbacks synchronously before Dense/ps can re-enter the main
    /// loop. Await both an in-flight start and stop before reporting completion.
    func stopRecording() {
        freezeStacks.disarm()
        generation &+= 1
        let starting = pendingStart
        pendingStart = nil
        starting?.cancel()
        let old = stream
        stream = nil
        activePID = nil
        targetWindowID = nil
        targetWindowVisible = false
        targetVisibilityConfirmedAt = nil
        let previousStop = pendingStop
        pendingStop = Task { @MainActor in
            await previousStop?.value
            await starting?.value
            if let old { await old.stop() }
        }
        publishStatus("未采集")
    }
    @MainActor private func performStart(targetPID: Int32, outputURL: URL, automaticFreezeStacks: Bool, token: UInt64) async {
        guard token == generation, !Task.isCancelled else { return }
        var authorized = CGPreflightScreenCaptureAccess()
#if MONITOR_PROCESS_SELF_TEST
        if let testPermission { authorized = testPermission() }
#endif
        guard authorized else { emit(status: "screen-recording-denied"); return }
        guard prepareOutput(outputURL, token: token) else { emit(status: "output-failed"); return }
        reset(pid: targetPID)
        if automaticFreezeStacks { freezeStacks.arm(captureDirectory: outputURL.deletingLastPathComponent(), targetPID: targetPID) }
        do {
            let new = try await makeStream(targetPID: targetPID)
            guard token == generation, !Task.isCancelled else { return }
            do { try await new.start() }
            catch { await new.stop(); throw error }
            guard token == generation, !Task.isCancelled else { await new.stop(); return }
            stream = new
            targetWindowID = new.windowID
            targetWindowVisible = new.isOnScreen
            targetVisibilityConfirmedAt = nil
            lastVisibilityCheck = 0
            emit(status: "capturing")
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            freezeStacks.disarm()
            emit(status: "capture-start-failed")
        }
    }

    @MainActor private func makeStream(targetPID: Int32) async throws -> CaptureStream {
#if MONITOR_PROCESS_SELF_TEST
        if let testStream { return try await testStream(targetPID) }
#endif
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.filter({ $0.owningApplication?.processID == targetPID && $0.frame.width >= 500 && $0.frame.height >= 300 }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw NSError(domain: "VisualCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "target-window-not-found"])
        }
        let config = SCStreamConfiguration()
        let aspect = max(window.frame.width / max(window.frame.height, 1), 1)
        config.width = 480; config.height = max(180, Int(480 / aspect))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false; config.capturesAudio = false
        let native = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try native.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        return CaptureStream(native: native, windowID: window.windowID, isOnScreen: window.isOnScreen,
                             start: { try await native.startCapture() }, stop: { try? await native.stopCapture() })
    }

    @MainActor func finishRecord(outputURL: URL?) async -> VisualFinishResult {
        let status = currentMetrics.status
        stopRecording()
        await pendingStop?.value
        let completed = detachOutput()
        guard outputURL != nil else { return .init(succeeded: true, message: "画面变化率：本轮未选择") }
        return completed?.succeeded == true ? .init(succeeded: true, message: "画面变化率：已记录") : .init(succeeded: false, message: "画面变化率：未取得有效数值（\(status)）")
    }
    func stream(_ outputStream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream?.native === outputStream, type == .screen, sample.isValid, let attach = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attach.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete, let pixel = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp.seconds; guard time.isFinite else { return }; let sampled = sceneSamples(pixel); frames.append(time); let exactChanged = lastHash != nil && lastHash != sampled.exact; if exactChanged { exact.append(time) }; let compare: (changed: Bool, mean: Double, ratio: Double) = lastGrid.map { VisualFrameAnalyzer.perceptuallyChanged(previous: $0, current: sampled.grid) } ?? (changed: false, mean: 0, ratio: 0); if compare.changed { perceptual.append(time); unchangedStart = nil } else if unchangedStart == nil { unchangedStart = lastTime ?? time }; lastHash = sampled.exact; lastGrid = sampled.grid; lastTime = time
        let cutoff = time - 1; frames.removeAll { $0 < cutoff }; exact.removeAll { $0 < cutoff }; perceptual.removeAll { $0 < cutoff }; let unchanged = (unchangedStart.map { (time - $0) * 1000 }) ?? 0; maxUnchanged = max(maxUnchanged, unchanged)
        if time - lastVisibilityCheck >= 0.25 { lastVisibilityCheck = time; refreshTargetVisibility() }
        let visibilityFresh = targetVisibilityConfirmedAt.map { time - $0 <= 0.5 } == true
        freezeStacks.observe(timestamp: time, perceptuallyChanged: compare.changed, captureFPS: Double(frames.count), stillDurationMs: unchanged, streamIsActive: stream != nil && output != nil, targetVisible: targetWindowVisible && visibilityFresh)
        if time - lastEmit >= 0.25 { lastEmit = time; numericSamples += 1; emit(metrics: .init(timestamp: Date().timeIntervalSince1970, status: "capturing", captureFPS: Double(frames.count), sampleChangedFPS: Double(exact.count), perceptualVisualFPS: Double(perceptual.count), meanSampleDelta: compare.mean, changedSampleRatio: compare.ratio, currentUnchangedRunMs: unchanged, maxUnchangedRunMs: maxUnchanged, targetPID: activePID ?? 0)) }
    }
    func stream(_ stopped: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, stopped === self.stream?.native else { return }
            self.stopRecording()
            self.publishStatus("capture-stopped")
        }
    }
    private func reset(pid: Int32) { activePID = pid; frames = []; exact = []; perceptual = []; lastHash = nil; lastGrid = nil; lastTime = nil; unchangedStart = nil; maxUnchanged = 0; lastEmit = 0; numericSamples = 0; targetWindowID = nil; targetWindowVisible = false; targetVisibilityConfirmedAt = nil; lastVisibilityCheck = 0; visibilityRefreshInFlight = false }
    private func emit(status: String) { emit(metrics: .init(timestamp: Date().timeIntervalSince1970, status: status, captureFPS: nil, sampleChangedFPS: nil, perceptualVisualFPS: nil, meanSampleDelta: nil, changedSampleRatio: nil, currentUnchangedRunMs: nil, maxUnchangedRunMs: nil, targetPID: activePID ?? 0)) }
    private func emit(metrics: VisualMetrics) { currentMetrics = metrics; if let data = try? JSONEncoder().encode(metrics) { append(data, isNumeric: metrics.isUsable) }; let token = generation; DispatchQueue.main.async { if self.generation == token { self.onUpdate?(metrics) } } }
    private func publishStatus(_ status: String) { let value = VisualMetrics(timestamp: Date().timeIntervalSince1970, status: status, captureFPS: nil, sampleChangedFPS: nil, perceptualVisualFPS: nil, meanSampleDelta: nil, changedSampleRatio: nil, currentUnchangedRunMs: nil, maxUnchangedRunMs: maxUnchanged, targetPID: activePID ?? 0); currentMetrics = value; let token = generation; DispatchQueue.main.async { if self.generation == token { self.onUpdate?(value) } } }
    private func prepareOutput(_ url: URL, token: UInt64) -> Bool {
        // Keep evidence and file ownership per explicit record. Revalidating
        // the same output must never reopen or truncate its exclusive handle.
        if let current = output {
            guard current.url == url, !current.failed else { return false }
            output = .init(generation: token, url: current.url, handle: current.handle, writes: current.writes, numericWrites: current.numericWrites, failed: false)
            return true
        }
        let d = url.deletingLastPathComponent()
        guard MonitorSecureFS.isPrivateDirectory(d), MonitorSecureFS.lstat(url) == nil, let handle = MonitorSecureFS.createExclusiveFile(url) else { return false }
        output = .init(generation: token, url: url, handle: handle, writes: 0, numericWrites: 0, failed: false); return true
    }
    private func detachOutput() -> OutputSession? { guard let old = output else { return nil }; output = nil; try? old.handle.close(); return old }
    private func append(_ data: Data, isNumeric: Bool = false) {
        guard var session = output, session.generation == generation, !session.failed else { return }
        do { try session.handle.write(contentsOf: data); try session.handle.write(contentsOf: Data([10])); session.writes += 1; if isNumeric { session.numericWrites += 1 }; output = session }
        catch { session.failed = true; output = session; _ = detachOutput(); stopRecording(); publishStatus("output-failed") }
    }
    private func refreshTargetVisibility() {
        guard !visibilityRefreshInFlight, let expectedID = targetWindowID, let expectedPID = activePID else { return }
        visibilityRefreshInFlight = true
        Task { [weak self] in
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let self else { return }
            self.visibilityRefreshInFlight = false
            guard self.targetWindowID == expectedID, self.activePID == expectedPID else { return }
            self.targetWindowVisible = content?.windows.contains { $0.windowID == expectedID && $0.owningApplication?.processID == expectedPID && $0.isOnScreen } == true
            self.targetVisibilityConfirmedAt = self.targetWindowVisible ? self.lastTime : nil
        }
    }
#if MONITOR_PROCESS_SELF_TEST
    @MainActor static func lifecycleFixtureChecks() async -> [Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-visual-lifecycle-\(UUID().uuidString)", isDirectory: true)
        guard MonitorSecureFS.createDirectoryOneLevel(root) else { return [false] }
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = VisualCaptureControllerNative()
        // A pipe-only stand-in exercises display-helper ownership, without a
        // window, game, ScreenCaptureKit call or permission request.
        controller.overlay = DisplayOverlayHelper(executableURL: URL(fileURLWithPath: "/bin/cat"))
        controller.testPermission = { true }
        var created = 0, starts = 0, stops = 0
        controller.testStream = { _ in
            created += 1
            return CaptureStream(native: nil, windowID: nil, isOnScreen: true,
                                 start: { starts += 1 }, stop: { stops += 1 })
        }
        let overlayStarted = controller.showOverlay()
        controller.publishOverlay(.init(cpuLine: "CPU 3%", gpuLine: "GPU 2%  20%", targetPID: 42, hasLiveData: true))
        let overlayOnlyDoesNotCapture = overlayStarted && created == 0 && controller.stream == nil && controller.output == nil
        let firstURL = root.appendingPathComponent("first.jsonl")
        controller.beginStart(targetPID: 42, outputURL: firstURL)
        await controller.pendingStart?.value
        let explicitStart = created == 1 && starts == 1 && controller.stream != nil
        controller.hideOverlay()
        let hidingPreservesRecord = controller.stream != nil && stops == 0
        _ = controller.showOverlay()
        let sample = VisualMetrics(timestamp: 1, status: "capturing", captureFPS: 60, sampleChangedFPS: 0, perceptualVisualFPS: 0, meanSampleDelta: 0, changedSampleRatio: 0, currentUnchangedRunMs: 1000, maxUnchangedRunMs: 1000, targetPID: 42)
        controller.emit(metrics: sample)
        let first = await controller.finishRecord(outputURL: firstURL)
        let completedKeepsOnlyOverlay = first.succeeded && controller.overlay.isRunning && controller.stream == nil && controller.output == nil && stops == 1
        let noFakeFPS = !sample.localizedDescription.contains("FPS") && !controller.currentMetrics.isUsable && controller.statusDescription.contains("未采集")

        let noVisualURL = root.appendingPathComponent("cleanup-without-output-argument.jsonl")
        controller.beginStart(targetPID: 42, outputURL: noVisualURL)
        await controller.pendingStart?.value
        let unselected = await controller.finishRecord(outputURL: nil)
        let nilStillStops = unselected.succeeded && stops == 2 && controller.stream == nil && controller.output == nil && controller.overlay.isRunning

        var resumeStart: CheckedContinuation<Void, Never>?
        controller.testStream = { _ in
            created += 1
            return CaptureStream(native: nil, windowID: nil, isOnScreen: true, start: {
                starts += 1
                await withCheckedContinuation { resumeStart = $0 }
            }, stop: { stops += 1 })
        }
        let pendingURL = root.appendingPathComponent("pending.jsonl")
        controller.beginStart(targetPID: 42, outputURL: pendingURL)
        for _ in 0..<1000 where resumeStart == nil { await Task.yield() }
        guard let resumeStart else { controller.hideOverlay(); return [false] }
        controller.stopRecording()
        let invalidatedImmediately = controller.stream == nil && controller.activePID == nil && !controller.currentMetrics.isUsable
        resumeStart.resume()
        let pending = await controller.finishRecord(outputURL: pendingURL)
        let cancelledStartCannotResurrect = !pending.succeeded && controller.stream == nil && controller.pendingStart == nil && stops == 3

        // Stopping before the task even runs must not deadlock against its own
        // cleanup task, create an output file, or enumerate shareable windows.
        let before = created
        let immediateURL = root.appendingPathComponent("immediate.jsonl")
        controller.beginStart(targetPID: 42, outputURL: immediateURL)
        _ = await controller.finishRecord(outputURL: immediateURL)
        let immediateStop = created == before && MonitorSecureFS.lstat(immediateURL) == nil
        controller.testPermission = { false }
        let deniedURL = root.appendingPathComponent("denied.jsonl")
        controller.beginStart(targetPID: 42, outputURL: deniedURL)
        await controller.pendingStart?.value
        let deniedDoesNotStart = created == before && MonitorSecureFS.lstat(deniedURL) == nil
        _ = await controller.finishRecord(outputURL: deniedURL)
        controller.hideOverlay()
        return [overlayOnlyDoesNotCapture, explicitStart, hidingPreservesRecord, completedKeepsOnlyOverlay, noFakeFPS,
                nilStillStops, invalidatedImmediately, cancelledStartCannotResurrect, immediateStop, deniedDoesNotStart]
    }
#endif

    static func outputFixtureChecks() -> [Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-visual-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard MonitorSecureFS.createDirectoryOneLevel(root) else { return [false] }
        let normal = root.appendingPathComponent("normal.jsonl"), victim = root.appendingPathComponent("victim"), link = root.appendingPathComponent("link.jsonl")
        let controller = VisualCaptureControllerNative()
        let normalPrepared = controller.prepareOutput(normal, token: 11)
        controller.generation = 11; controller.emit(status: "capturing")
        let statusOnlyRejected = controller.output?.succeeded == false
        controller.emit(metrics: .init(timestamp: 1, status: "capturing", captureFPS: 60, sampleChangedFPS: 0, perceptualVisualFPS: 0, meanSampleDelta: 0, changedSampleRatio: 0, currentUnchangedRunMs: 1000, maxUnchangedRunMs: 1000, targetPID: 123))
        let sameSessionPrepared = controller.prepareOutput(normal, token: 12)
        controller.generation = 12; controller.append(Data("{}".utf8)); let first = controller.detachOutput()
        let existingRejected = !controller.prepareOutput(normal, token: 12)
        _ = MonitorSecureFS.createExclusiveFile(victim); try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: victim.path)
        let symlinkRejected = !controller.prepareOutput(link, token: 13) && (try? String(contentsOf: victim, encoding: .utf8)) == ""
        let second = root.appendingPathComponent("second.jsonl"); let reusePrepared = controller.prepareOutput(second, token: 14); let reuseZero = controller.output?.writes == 0 && controller.output?.numericWrites == 0 && controller.output?.succeeded == false; _ = controller.detachOutput()
        let full = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/full")); if let full { controller.output = .init(generation: 14, url: second, handle: full, writes: 0, numericWrites: 0, failed: false); controller.generation = 14; controller.append(Data("{}".utf8)) }; let failedDetached = controller.output == nil
        return [normalPrepared, statusOnlyRejected, sameSessionPrepared, first?.writes == 3, first?.numericWrites == 1, first?.succeeded == true, existingRejected, symlinkRejected, reusePrepared, reuseZero, failedDetached] + DisplayOverlayHelper.fixtureChecks()
    }
}

typealias VisualCaptureController = VisualCaptureControllerNative
