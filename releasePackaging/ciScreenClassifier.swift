// CI observation only: CPU-first OCR, no permission requests, input or agreement acceptance.
import AppKit
import Foundation
import Vision
import ImageIO

func classify(_ lines: [String]) -> [String: Any] {
    let lines = lines.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"(?<=\p{Han})\s+(?=\p{Han})"#, with: "", options: .regularExpression) }
    let text = lines.joined(separator: "\n").replacingOccurrences(of: #"(?<=\p{Han})\s+(?=\p{Han})"#, with: "", options: .regularExpression)
    var auth = ["captcha", "verify you are human", "i'm not a robot", "验证码", "拖动滑块", "账号登录", "账户登录", "扫码登录", "password"].filter { text.contains($0) }
    if lines.contains(where: { ["login", "log in", "sign in", "sign-in", "登录", "登入", "账号登录", "帐号登录"].contains($0) }) { auth.append("login_control") }
    let agreement = (text.contains("i agree") && (text.contains("terms") || text.contains("privacy"))) || (text.contains("同意") && text.contains("用户协议"))
    let updating = ["downloading patches", "downloading patch", "下载补丁", "解压补丁", "更新中", "verifying files"].contains { text.contains($0) }
    let heading = lines.contains { line in
        let key = line.replacingOccurrences(of: #"[^a-z\p{Han}]"#, with: "", options: .regularExpression)
        return ["notice", "notices", "news", "announcements", "announcement", "latestnews", "gamenotice", "servernotice", "systemnotice", "systemannouncement", "公告", "公告详情", "游戏公告"].contains(key)
    }
    return ["authenticationRequired": !auth.isEmpty, "authenticationMarkers": auth,
            "agreementRequiresUser": agreement, "updateScreenVisible": updating,
            "announcementCandidate": heading && !updating && text.count > 100,
            "recognizedLineCount": lines.count]
}
func recognizeWithTesseract(_ image: CGImage) throws -> [String: Any]? {
    let environment = ProcessInfo.processInfo.environment
    guard let executable = environment["IDV_CI_TESSERACT"], FileManager.default.isExecutableFile(atPath: executable),
          let dataRoot = environment["IDV_CI_TESSDATA_DIR"] else { return nil }
    var input = image
    var crop: CGRect?
    var didCrop = false
    if let spec = environment["IDV_CI_OCR_TEST_CROP"] {
        let values = spec.split(separator: ",").compactMap { Double($0) }
        if values.count == 4 { crop = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) }
    } else if environment["GITHUB_ACTIONS"] == "true", let rawPID = environment["IDV_CI_GAME_PID"], let pid = Int(rawPID),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        let scale = Double(image.width) / CGDisplayBounds(CGMainDisplayID()).width
        for window in windows where (window[kCGWindowOwnerPID as String] as? Int) == pid {
            if let b = window[kCGWindowBounds as String] as? [String: Double],
               let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w >= 300, h >= 200 {
                crop = CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale); break
            }
        }
    }
    if let rect = crop, rect.minX >= 0, rect.minY >= 0, rect.maxX <= Double(image.width), rect.maxY <= Double(image.height),
       let cropped = image.cropping(to: rect) { input = cropped; didCrop = true }
    let width = min(input.width * 3, 4096), height = min(input.height * 3, 4096)
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    bitmap.interpolationQuality = .high
    bitmap.draw(input, in: CGRect(x: 0, y: 0, width: width, height: height))
    if let raw = bitmap.data {
        let bytes = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var total = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) { total += (Int(bytes[i]) + Int(bytes[i+1]) + Int(bytes[i+2])) / 3 }
        let average = total / (width * height)
        let threshold = average < 128 ? min(190, average + 65) : max(90, average - 65)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let light = (Int(bytes[i]) + Int(bytes[i+1]) + Int(bytes[i+2])) / 3
            let ink = average < 128 ? light > threshold : light < threshold
            let value: UInt8 = ink ? 0 : 255
            bytes[i] = value; bytes[i+1] = value; bytes[i+2] = value; bytes[i+3] = 255
        }
    }
    guard let scaled = bitmap.makeImage() else { return nil }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("ci-ocr-" + UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: file) }
    guard let output = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(output, scaled, nil)
    guard CGImageDestinationFinalize(output) else { return nil }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    let languages = environment["IDV_CI_OCR_LANGUAGES"] ?? "eng+chi_sim"
    process.arguments = [file.path, "stdout", "--tessdata-dir", dataRoot, "-l", languages, "--psm", "11"]
    process.environment = environment.merging(["OMP_THREAD_LIMIT": "1"]) { _, new in new }
    process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "CI.Tesseract", code: Int(process.terminationStatus)) }
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(200).map(String.init)
    var result = classify(lines)
    result["ocrBackend"] = "tesseract_cpu"
    result["ocrRecognitionLanguages"] = languages.contains("chi_sim") ? ["en-US", "zh-Hans"] : ["en-US"]
    result["ocrInputCropped"] = didCrop
    result["ocrUsesCPUOnly"] = true
    return result
}
func recognize(_ image: CGImage) throws -> [String: Any] {
    // AppKit can render a floating-point fixture on newer guests. Normalize
    // both fixtures and captures to the same 8-bit RGB input for Vision.
    guard let bitmap = CGContext(data: nil, width: image.width, height: image.height,
                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "CI.ScreenClassifier.Input", code: 2)
    }
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let normalized = bitmap.makeImage() else { throw NSError(domain: "CI.ScreenClassifier.Input", code: 3) }
    if ProcessInfo.processInfo.environment["IDV_CI_OCR_FORCE_TESSERACT"] == "1", let result = try recognizeWithTesseract(image) { return result }
    // The default configuration failed on guest 27. Try explicit supported
    // revisions and normal device selection; this changes only observation.
    let configurations: [(Int, Bool, [String])] = [(3, true, ["en-US", "zh-Hans"]), (3, false, ["en-US", "zh-Hans"]), (2, true, ["en-US"])]
    var failures: [[String: Any]] = []
    for (revision, cpuOnly, languages) in configurations where VNRecognizeTextRequest.supportedRevisions.contains(revision) {
        let request = VNRecognizeTextRequest()
        let defaultRevision = request.revision
        request.revision = revision
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesCPUOnly = cpuOnly
        do {
            try VNImageRequestHandler(cgImage: normalized).perform([request])
            var result = classify((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
            result["ocrBackend"] = "vision"
            result["ocrDefaultRevision"] = defaultRevision
            result["ocrPriorFailures"] = failures
            result["ocrRevision"] = revision
            result["ocrUsesCPUOnly"] = cpuOnly
            result["ocrRecognitionLanguages"] = languages
            return result
        } catch {
            let e = error as NSError
            failures.append(["revision": revision, "cpuOnly": cpuOnly, "domain": e.domain, "code": e.code])
        }
    }
    if var result = try recognizeWithTesseract(normalized) {
        result["ocrPriorFailures"] = failures
        return result
    }
    let details = try JSONSerialization.data(withJSONObject: ["screenClassifierAvailable": false, "errors": failures], options: [.sortedKeys])
    FileHandle.standardError.write(details)
    throw NSError(domain: "CI.ScreenClassifier", code: 1)
}

do {
    var result: [String: Any]
    if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
        precondition(classify(["Login"]) ["authenticationRequired"] as? Bool == true)
        precondition(classify(["Password"]) ["authenticationRequired"] as? Bool == true)
        precondition(classify(["I agree to the Terms"]) ["agreementRequiresUser"] as? Bool == true)
        let body = String(repeating: "Maintenance information. ", count: 8)
        precondition(classify(["Notice", body]) ["announcementCandidate"] as? Bool == true)
        precondition(classify(["Notice", body, "Downloading patches..."]) ["announcementCandidate"] as? Bool == false)
        let image = NSImage(size: NSSize(width: 640, height: 240))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 240).fill()
        ("CAPTCHA" as NSString).draw(at: NSPoint(x: 20, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        ("验证码" as NSString).draw(at: NSPoint(x: 20, y: 45), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
        result = try recognize(cg)
        let markers = result["authenticationMarkers"] as? [String] ?? []
        guard markers.contains("captcha") else { exit(1) }
        result["chineseOCRVerified"] = markers.contains("验证码")
        result["selfTestPassed"] = true
        result["ocrVerified"] = true
        result["cpuOCRVerified"] = result["ocrUsesCPUOnly"] as? Bool ?? false
    } else {
        guard CommandLine.arguments.count == 2,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(64) }
        result = try recognize(image)
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    let e = error as NSError
    fputs("screen_classifier_unavailable domain=\(e.domain) code=\(e.code)\n", stderr); exit(1)
}
