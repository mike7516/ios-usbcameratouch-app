import Foundation

enum RuntimeConstants {
    static let deviceHost = "192.168.0.1"
    static let devicePort: UInt16 = 7658
    static let reconnectIntervalSeconds: TimeInterval = 1.0
    // ACK flow control: the device sends one ACK per processed frame; if it does
    // not arrive within this window, send the next frame anyway (lost ACK).
    static let ackTimeoutSeconds: TimeInterval = 0.5
    // ~30 FPS ceiling; the real rate is then bounded by encode+send time.
    static let minimumFrameIntervalSeconds: TimeInterval = 1.0 / 30.0

    static let appGroupID = "group.wen.usbcameratouch"
    static let broadcastExtensionBundleID = "wen.usbcameratouch.BroadcastUpload"
}
