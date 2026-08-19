import Foundation

enum RuntimeConstants {
    static let deviceHost = "192.168.0.1"
    static let devicePort: UInt16 = 7658
    static let reconnectIntervalSeconds: TimeInterval = 1.0
    // ACK flow control: the device sends one 0x01 ACK per processed frame; if it
    // does not arrive within this window, send the next frame anyway (lost ACK).
    static let ackTimeoutSeconds: TimeInterval = 0.5
    // ~30 FPS ceiling; the real rate is then bounded by encode+send time
    // (back-pressure drops frames while busy), not by this floor.
    static let minimumFrameIntervalSeconds: TimeInterval = 1.0 / 30.0

    // Project IDs (mirrors USBDisplay naming convention).
    static let appGroupID = "group.wen.usbcameratouch"
    // Screen-broadcast extension (background / Home-screen mirroring).
    static let broadcastExtensionBundleID = "wen.usbcameratouch.BroadcastUpload"
}
