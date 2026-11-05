// CI observation only: CPU OCR, no permission requests, input or agreement acceptance.
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
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    request.usesCPUOnly = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return classify((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
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
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              try recognize(cg)["authenticationRequired"] as? Bool == true else { exit(1) }
        result = ["selfTestPassed": true, "cpuOCRVerified": true]
    } else {
        guard CommandLine.arguments.count == 2,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(64) }
        result = try recognize(image)
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fputs("screen_classifier_unavailable\n", stderr); exit(1)
}
