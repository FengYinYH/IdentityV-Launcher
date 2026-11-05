// CI observation only: CPU-first OCR, no permission requests, input or agreement acceptance.
import AppKit
import Foundation
import Vision
import ImageIO

func classify(_ lines: [String]) -> [String: Any] {
    let lines = lines.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    let text = lines.joined(separator: "\n")
    var auth = ["captcha", "verify you are human", "i'm not a robot", "验证码", "拖动滑块", "账号登录", "账户登录", "扫码登录", "password"].filter { text.contains($0) }
    if lines.contains(where: { ["login", "log in", "sign in", "sign-in", "登录", "登入", "账号登录", "帐号登录"].contains($0) }) { auth.append("login_control") }
    let agreement = (text.contains("i agree") && (text.contains("terms") || text.contains("privacy"))) || (text.contains("同意") && text.contains("用户协议"))
    let updating = ["downloading patches", "downloading patch", "下载补丁", "解压补丁", "更新中", "verifying files"].contains { text.contains($0) }
    let heading = lines.contains { ["notice", "notices", "announcements", "announcement", "latest news", "game notice", "公告", "公告详情", "游戏公告"].contains($0) }
    return ["authenticationRequired": !auth.isEmpty, "authenticationMarkers": auth,
            "agreementRequiresUser": agreement, "updateScreenVisible": updating,
            "announcementCandidate": heading && !updating && text.count > 100,
            "recognizedLineCount": lines.count]
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
        let image = NSImage(size: NSSize(width: 640, height: 160))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 160).fill()
        ("CAPTCHA" as NSString).draw(at: NSPoint(x: 20, y: 55), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
        result = try recognize(cg)
        guard result["authenticationRequired"] as? Bool == true else { exit(1) }
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
