import AppKit
import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

enum GameAudioCapturePhase: Equatable {
    case idle, starting, recording, stopping, completed, failed
    var isBusy: Bool { self == .starting || self == .recording || self == .stopping }
}

struct GameAudioCaptureUpdate {
    let phase: GameAudioCapturePhase
    let message: String
    let secondsRemaining: Int
    let outputURL: URL?
}

/// A deliberately separate, user-started ScreenCaptureKit stream. The filter is
/// tied to the managed game's exact window owner; ScreenCaptureKit then applies
/// its documented application-level audio filter. No screen output is attached.
final class GameAudioCaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    static let maximumDuration: TimeInterval = 30
    static let sampleRate = 48_000
    static let channelCount = 2

    var onUpdate: ((GameAudioCaptureUpdate) -> Void)?
    private(set) var phase: GameAudioCapturePhase = .idle
    private(set) var targetIdentity: GameProcessIdentity?
    private var stream: SCStream?
    private var writer: PCM16WAVWriter?
    private var outputURL: URL?
    private var metadataURL: URL?
    private var startedAt: Date?
    private var startUptime: TimeInterval = 0
    private var deadlineWork: DispatchWorkItem?
    private var countdownTimer: Timer?
    private var generation: UInt64 = 0
    private var isFinishing = false
    private var sampleCount: UInt64 = 0
    private var firstSampleAt: Date?
    private var lastSampleAt: Date?
    private var failure: String?

    func start(targetPID: Int32, identity: GameProcessIdentity) {
        guard !phase.isBusy else { return }
        guard identity.pid == targetPID, GameProcessIdentity.read(targetPID) == identity else {
            publish(.failed, "游戏进程已变化，未开始录音。")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            publish(.failed, "游戏声音录制需要工具箱已有的屏幕录制权限；未请求系统授权，也未开始录音。")
            return
        }
        generation &+= 1
        let token = generation
        targetIdentity = identity
        sampleCount = 0
        firstSampleAt = nil
        lastSampleAt = nil
        failure = nil
        isFinishing = false
        phase = .starting
        publish(.starting, "正在准备游戏声音录制…")
        Task { [weak self] in await self?.begin(targetPID: targetPID, identity: identity, token: token) }
    }

    private func begin(targetPID: Int32, identity: GameProcessIdentity, token: UInt64) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard token == generation, !isFinishing else { return }
            guard GameProcessIdentity.read(targetPID) == identity else {
                publish(.failed, "游戏已退出或进程已更换，未开始录音。")
                return
            }
            guard let window = content.windows
                .filter({ $0.owningApplication?.processID == targetPID && $0.frame.width >= 500 && $0.frame.height >= 300 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                publish(.failed, "未找到归属当前 dwrg.exe 的游戏窗口，未开始录音。")
                return
            }
            guard let root = Self.prepareOutputDirectory(), let files = Self.newOutputFiles(in: root, pid: targetPID) else {
                publish(.failed, "无法安全创建游戏声音输出文件，未开始录音。")
                return
            }
            let newWriter = try PCM16WAVWriter(url: files.wavURL, sampleRate: Self.sampleRate, channelCount: Self.channelCount)
            guard token == generation, !isFinishing else {
                try? newWriter.abort(); return
            }
            outputURL = files.wavURL
            metadataURL = files.metadataURL
            writer = newWriter
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            if #available(macOS 15.0, *) { configuration.captureMicrophone = false }
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Self.sampleRate
            configuration.channelCount = Self.channelCount
            let newStream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
            stream = newStream
            try await newStream.startCapture()
            guard token == generation, !isFinishing else {
                try? await newStream.stopCapture()
                return
            }
            guard GameProcessIdentity.read(targetPID) == identity else {
                await finish(reason: "游戏退出", isFailure: false)
                return
            }
            startedAt = Date()
            startUptime = ProcessInfo.processInfo.systemUptime
            phase = .recording
            publish(.recording, "正在录制第五人格游戏声音（最长 30 秒）")
            armDeadline(token: token)
        } catch {
            failure = error.localizedDescription
            await finish(reason: "启动失败", isFailure: true)
        }
    }

    func stopManually() { Task { await finish(reason: "手动停止", isFailure: false) } }

    func stopIfTargetExited(snapshot: String) {
        guard phase.isBusy, let identity = targetIdentity else { return }
        let stillListed = snapshot.split(whereSeparator: \.isNewline).contains { line in
            let fields = String(line).split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            return fields.count == 3 && Int32(fields[0]) == identity.pid && UInt32(fields[1]) == getuid() && MonitorGameProcessMatcher.isGameCommand(String(fields[2]))
        }
        guard stillListed, GameProcessIdentity.read(identity.pid) == identity else {
            Task { await finish(reason: "游戏退出", isFailure: false) }
            return
        }
    }

    func stopForToolboxExit() async { await finish(reason: "工具箱退出", isFailure: false) }

    private func armDeadline(token: UInt64) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            Task { await self.finish(reason: "达到 30 秒上限", isFailure: false) }
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maximumDuration, execute: work)
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.phase == .recording else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.startUptime
            let remaining = max(0, Int(ceil(Self.maximumDuration - elapsed)))
            self.publish(.recording, "正在录制第五人格游戏声音 · 剩余 \(remaining) 秒")
        }
    }

    private func finish(reason: String, isFailure: Bool) async {
        guard !isFinishing, phase.isBusy else { return }
        isFinishing = true
        generation &+= 1 // Invalidate any suspended window lookup or stream start before awaiting teardown.
        phase = .stopping
        deadlineWork?.cancel(); deadlineWork = nil
        countdownTimer?.invalidate(); countdownTimer = nil
        publish(.stopping, "正在收尾游戏声音文件…")
        let oldStream = stream
        stream = nil
        if let oldStream { try? await oldStream.stopCapture() }
        let endedAt = Date()
        let saved = finalizeOutput(reason: reason, endedAt: endedAt, isFailure: isFailure || failure != nil)
        targetIdentity = nil
        isFinishing = false
        if saved.success {
            phase = .completed
            publish(.completed, saved.message, outputURL: saved.url)
        } else {
            phase = .failed
            publish(.failed, saved.message, outputURL: saved.url)
        }
    }

    private func finalizeOutput(reason: String, endedAt: Date, isFailure: Bool) -> (success: Bool, message: String, url: URL?) {
        let wavURL = outputURL
        let resultMetadataURL = metadataURL
        var wavVerified = false
        var bytes: UInt64 = 0
        if let writer {
            do {
                let result = try writer.finish()
                bytes = result.bytesWritten
                wavVerified = result.frameCount > 0 && Self.validWAV(at: writer.url, expectedDataBytes: result.bytesWritten)
            } catch { failure = failure ?? error.localizedDescription }
        }
        writer = nil
        if !wavVerified, let wavURL { try? FileManager.default.removeItem(at: wavURL) }
        let target = targetIdentity
        let started = startedAt
        let metadata = GameAudioCaptureMetadata(
            schema: 1,
            targetPID: target?.pid ?? 0,
            targetStartSeconds: target?.startSeconds ?? 0,
            targetStartMicros: target?.startMicros ?? 0,
            startedAt: started,
            endedAt: endedAt,
            endReason: reason,
            format: "WAVE PCM signed 16-bit little-endian, 48000 Hz, stereo",
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            sampleFrames: sampleCount,
            audioBytes: bytes,
            firstAudioAt: firstSampleAt,
            lastAudioAt: lastSampleAt,
            wavSaved: wavVerified,
            error: failure
        )
        var metadataSaved = false
        if let metadataURL, let data = try? JSONEncoder.gameAudio.encode(metadata),
           let handle = MonitorSecureFS.createExclusiveFile(metadataURL) {
            do { try handle.write(contentsOf: data); try handle.close(); metadataSaved = MonitorSecureFS.isPrivateRegularFile(metadataURL) }
            catch { try? handle.close(); failure = failure ?? error.localizedDescription }
        }
        outputURL = nil
        self.metadataURL = nil
        writer = nil
        startedAt = nil
        startUptime = 0
        sampleCount = 0
        firstSampleAt = nil
        lastSampleAt = nil
        if !wavVerified {
            let metadataNote = metadataSaved ? "录制结果说明已保存：\(resultMetadataURL?.lastPathComponent ?? "")。" : "录制结果说明也未能保存。"
            return (false, "未取得有效游戏声音样本；没有保存 WAV。\(metadataNote)\(failure.map { "\($0)" } ?? "")", metadataSaved ? resultMetadataURL : nil)
        }
        if isFailure || !metadataSaved {
            return (false, "游戏声音 WAV 已保存\(wavURL.map { "：\($0.lastPathComponent)" } ?? "")，但收尾存在问题\(failure.map { "：\($0)" } ?? "（录制元数据未写入）")。", wavURL)
        }
        return (true, "游戏声音 WAV 已保存，可在输出目录回听：\(wavURL?.lastPathComponent ?? "")", wavURL)
    }

    func stream(_ outputStream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard outputStream === stream, type == .audio, phase == .recording, sampleBuffer.isValid,
              let writer, let pcm = Self.pcm16(sampleBuffer, expectedRate: Self.sampleRate, expectedChannels: Self.channelCount) else {
            if outputStream === stream, type == .audio, phase == .recording, sampleBuffer.isValid {
                failure = "音频样本格式不受支持或数据无效"
                Task { await finish(reason: "音频样本格式错误", isFailure: true) }
            }
            return
        }
        let frameCount = UInt64(pcm.count / (Self.channelCount * MemoryLayout<Int16>.size))
        guard frameCount > 0, sampleCount + frameCount <= UInt64(Self.sampleRate) * UInt64(Self.maximumDuration) else { return }
        do {
            try writer.append(pcm)
            sampleCount += frameCount
            let now = Date()
            if firstSampleAt == nil { firstSampleAt = now }
            lastSampleAt = now
        } catch {
            failure = error.localizedDescription
            Task { await finish(reason: "写入失败", isFailure: true) }
        }
    }

    func stream(_ stoppedStream: SCStream, didStopWithError error: Error) {
        guard stoppedStream === stream, !isFinishing else { return }
        failure = error.localizedDescription
        Task { await finish(reason: "音频流异常停止", isFailure: true) }
    }

    private func publish(_ phase: GameAudioCapturePhase, _ message: String, outputURL: URL? = nil) {
        self.phase = phase
        let remaining = phase == .recording
            ? max(0, Int(ceil(Self.maximumDuration - (ProcessInfo.processInfo.systemUptime - startUptime))) )
            : 0
        onUpdate?(.init(phase: phase, message: message, secondsRemaining: remaining, outputURL: outputURL))
    }

    private static func prepareOutputDirectory() -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let support = MonitorSecureFS.lstat(appSupport), (support.st_mode & S_IFMT) == S_IFDIR, support.st_uid == getuid() else { return nil }
        var directory = appSupport
        for name in ["IdentityVOnMac", "Diagnostics", "GameAudio"] {
            directory.appendPathComponent(name, isDirectory: true)
            if MonitorSecureFS.lstat(directory) == nil && !MonitorSecureFS.createDirectoryOneLevel(directory) { return nil }
            guard MonitorSecureFS.isPrivateDirectory(directory) else { return nil }
        }
        return directory
    }

    private static func newOutputFiles(in directory: URL, pid: Int32) -> (wavURL: URL, metadataURL: URL)? {
        let stamp = ISO8601DateFormatter.gameAudio.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let basename = "IdentityV-\(stamp)-pid-\(pid)-\(UUID().uuidString)"
        return (directory.appendingPathComponent(basename + ".wav"), directory.appendingPathComponent(basename + ".json"))
    }

    private static func validWAV(at url: URL, expectedDataBytes: UInt64) -> Bool {
        guard MonitorSecureFS.isPrivateRegularFile(url), let data = try? Data(contentsOf: url), data.count >= 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE",
              String(decoding: data[36..<40], as: UTF8.self) == "data" else { return false }
        let riffBytes = UInt64(data[4]) | UInt64(data[5]) << 8 | UInt64(data[6]) << 16 | UInt64(data[7]) << 24
        let audioBytes = UInt64(data[40]) | UInt64(data[41]) << 8 | UInt64(data[42]) << 16 | UInt64(data[43]) << 24
        return riffBytes == UInt64(data.count - 8) && audioBytes == expectedDataBytes && expectedDataBytes > 0 && data.count == 44 + Int(expectedDataBytes)
    }

    private static func pcm16(_ sampleBuffer: CMSampleBuffer, expectedRate: Int, expectedChannels: Int) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let descriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        let description = descriptionPointer.pointee
        guard
              description.mFormatID == kAudioFormatLinearPCM,
              Int(description.mSampleRate) == expectedRate,
              Int(description.mChannelsPerFrame) == expectedChannels,
              (description.mBitsPerChannel == 32 && description.mFormatFlags & kAudioFormatFlagIsFloat != 0)
                || (description.mBitsPerChannel == 16 && description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        var listSize = 0
        var retainedBlock: CMBlockBuffer?
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &retainedBlock)
        guard sizeStatus == noErr, listSize >= MemoryLayout<AudioBufferList>.size else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &retainedBlock)
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard !buffers.isEmpty else { return nil }
        let bytesPerSample = Int(description.mBitsPerChannel / 8)
        let interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var output = Data(capacity: frames * expectedChannels * 2)
        for frame in 0..<frames {
            for channel in 0..<expectedChannels {
                let bufferIndex = interleaved ? 0 : channel
                guard bufferIndex < buffers.count, let base = buffers[bufferIndex].mData else { return nil }
                let channelsInBuffer = max(1, Int(buffers[bufferIndex].mNumberChannels))
                let sampleIndex = interleaved ? frame * channelsInBuffer + channel : frame
                let offset = sampleIndex * bytesPerSample
                guard offset + bytesPerSample <= Int(buffers[bufferIndex].mDataByteSize) else { return nil }
                let sample: Int16
                if description.mBitsPerChannel == 32 {
                    let value = base.loadUnaligned(fromByteOffset: offset, as: Float.self)
                    guard value.isFinite else { return nil }
                    let clipped = max(-1, min(1, value))
                    sample = Int16(clamping: Int(clipped < 0 ? clipped * 32768 : clipped * 32767))
                } else {
                    sample = base.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                }
                var littleEndian = sample.littleEndian
                withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
            }
        }
        return output
    }

    static func fixtureChecks() -> [Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-audio-fixture-\(UUID().uuidString)", isDirectory: true)
        guard MonitorSecureFS.createDirectoryOneLevel(root) else { return [false] }
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.wav")
        do {
            let writer = try PCM16WAVWriter(url: url, sampleRate: sampleRate, channelCount: channelCount)
            var samples = Data(capacity: sampleRate / 10 * channelCount * 2)
            for frame in 0..<(sampleRate / 10) {
                let wave = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate)) * 12_000)
                for _ in 0..<channelCount { samples.appendLE(wave) }
            }
            try writer.append(samples)
            let result = try writer.finish()
            let valid = result.frameCount == UInt64(sampleRate / 10)
                && result.bytesWritten == UInt64(samples.count)
                && validWAV(at: url, expectedDataBytes: UInt64(samples.count))
            return [valid, maximumDuration == 30, GameAudioCapturePhase.recording.isBusy, !GameAudioCapturePhase.completed.isBusy]
        } catch { return [false] }
    }
}

private struct GameAudioCaptureMetadata: Encodable {
    let schema: Int
    let targetPID: Int32
    let targetStartSeconds: UInt64
    let targetStartMicros: UInt64
    let startedAt: Date?
    let endedAt: Date
    let endReason: String
    let format: String
    let sampleRate: Int
    let channels: Int
    let sampleFrames: UInt64
    let audioBytes: UInt64
    let firstAudioAt: Date?
    let lastAudioAt: Date?
    let wavSaved: Bool
    let error: String?
}

private extension JSONEncoder {
    static var gameAudio: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601; return encoder }
}

private extension ISO8601DateFormatter {
    static var gameAudio: ISO8601DateFormatter { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter }
}

private final class PCM16WAVWriter {
    let url: URL
    let sampleRate: Int
    let channelCount: Int
    private let handle: FileHandle
    private(set) var frameCount: UInt64 = 0
    private(set) var byteCount: UInt64 = 0

    init(url: URL, sampleRate: Int, channelCount: Int) throws {
        guard let handle = MonitorSecureFS.createExclusiveFile(url) else { throw NSError(domain: "GameAudioWAV", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法独占创建 WAV 文件"]) }
        self.url = url; self.sampleRate = sampleRate; self.channelCount = channelCount; self.handle = handle
        try handle.write(contentsOf: Data(repeating: 0, count: 44))
    }

    func append(_ pcm: Data) throws {
        guard pcm.count.isMultiple(of: channelCount * 2), !pcm.isEmpty else { throw NSError(domain: "GameAudioWAV", code: 2, userInfo: [NSLocalizedDescriptionKey: "PCM 样本长度不完整"]) }
        try handle.write(contentsOf: pcm)
        byteCount += UInt64(pcm.count)
        frameCount += UInt64(pcm.count / (channelCount * 2))
    }

    func finish() throws -> (frameCount: UInt64, bytesWritten: UInt64) {
        guard byteCount <= UInt64(UInt32.max - 36) else { throw NSError(domain: "GameAudioWAV", code: 3, userInfo: [NSLocalizedDescriptionKey: "WAV 超出 RIFF 4 GiB 限制"]) }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channelCount, dataBytes: UInt32(byteCount)))
        try handle.synchronize()
        try handle.close()
        return (frameCount, byteCount)
    }

    func abort() throws { try handle.close(); try FileManager.default.removeItem(at: url) }

    static func header(sampleRate: Int, channels: Int, dataBytes: UInt32) -> Data {
        let byteRate = UInt32(sampleRate * channels * 2)
        let blockAlign = UInt16(channels * 2)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8)); data.appendLE(dataBytes + 36)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); data.appendLE(UInt32(16)); data.appendLE(UInt16(1))
        data.appendLE(UInt16(channels)); data.appendLE(UInt32(sampleRate)); data.appendLE(byteRate); data.appendLE(blockAlign); data.appendLE(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); data.appendLE(dataBytes)
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) } }
}
