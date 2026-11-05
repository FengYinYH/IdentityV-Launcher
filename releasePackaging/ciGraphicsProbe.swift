// Hosted-runner preflight only: no permission requests, event injection, or game launch.
import AppKit
import CoreGraphics
import Metal
import Foundation

let device = MTLCreateSystemDefaultDevice()
let queue = device?.makeCommandQueue()
let command = queue?.makeCommandBuffer()
command?.commit()
command?.waitUntilCompleted()
let displays = NSScreen.screens.map { screen in
    ["width": Int(screen.frame.width), "height": Int(screen.frame.height)]
}
let ready = device != nil && command?.status == .completed && !displays.isEmpty
let result: [String: Any] = [
    "schemaVersion": 1,
    "experiment": "hosted-game-graphics-preflight",
    "metalDeviceAvailable": device != nil,
    "metalDeviceName": device?.name ?? "unavailable",
    "metalCommandCompleted": command?.status == .completed,
    "displayCount": displays.count,
    "displays": displays,
    "screenCapturePreauthorized": CGPreflightScreenCaptureAccess(),
    "usableForGameExperiment": ready,
    "gameLaunched": false,
    "announcementVerified": false,
    "permissionsRequested": false
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
