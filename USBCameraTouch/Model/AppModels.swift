import Foundation

enum SendMode: String, CaseIterable, Codable, Identifiable {
    case single = "SINGLE"
    case continuous = "CONTINUOUS"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "Single Frame"
        case .continuous: return "Continuous"
        }
    }
}

/// Only used by the TEST solid-color path (`JPEGEncoder.encodeSolidColor`).
/// The camera stream path ignores this field.
enum ImageMode: String, CaseIterable, Codable, Identifiable {
    case red = "RED"
    case green = "GREEN"
    case blue = "BLUE"

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// Front / back camera. Kept as a plain string enum so the Model layer does
/// not import AVFoundation; CameraCaptureController maps it to
/// `AVCaptureDevice.Position`.
enum CameraPosition: String, CaseIterable, Codable, Identifiable {
    case back = "BACK"
    case front = "FRONT"

    var id: String { rawValue }
    var displayName: String { self == .back ? "後鏡頭" : "前鏡頭" }
}

enum TCPDisplayState: String, Codable {
    case idle = "IDLE"
    case connecting = "CONNECTING"
    case connected = "CONNECTED"
    case disconnected = "DISCONNECTED"
    case reconnecting = "RECONNECTING"
}

struct RuntimeConfig: Codable, Equatable {
    // Image / transport (reused from USBDisplay)
    var width: Int = 640             // 8808 panel resolution (per1_ios_ncmdisplay)
    var height: Int = 1136
    var jpegQuality: Int = 80
    var targetFps: Int = 30
    var ackPaced: Bool = true
    var sendMode: SendMode = .continuous
    var imageMode: ImageMode = .red  // TEST solid-color only; camera stream ignores it

    // Camera (new)
    var cameraPosition: CameraPosition = .back

    // Touch behavior (M2/M3; v1 does tap focus+exposure only)
    var touchFocus: Bool = true
    var touchExposure: Bool = true
    var touchZoom: Bool = true

    static let defaultValue = RuntimeConfig()
}

struct RuntimeStatus: Codable, Equatable {
    var tcpState: TCPDisplayState = .idle
    var tcpDetail: String = ""
    var statusText: String = "Ready"

    var frameCount: UInt64 = 0
    var jpegBytes: Int = 0
    var fps: Double = 0
    var mbps: Double = 0

    /// iOS native encoder decides chroma subsampling; inspected after encoding.
    var jpegSampling: String = "Native / Unknown"

    /// TX-side latency instrumentation (milliseconds); 0 until the first frame.
    var encodeMs: Double = 0          // frame accepted -> JPEG encoded
    var sendMs: Double = 0            // TCP send start -> send completion (TX)
    var captureToSendMs: Double = 0   // frame accepted -> send completion (end to end)
    var responseMs: Double = 0        // last send start -> device reply bytes (RTT); 0 = none
    var instantFps: Double = 0        // 1 / interval between the last two sent frames

    var isSending: Bool = false
    var extensionActive: Bool = false // always false here (no extension); kept for metrics parity
    var singleCompleted: Bool = false

    var disconnectGeneration: UInt64 = 0
    var lastError: String = ""

    static let idle = RuntimeStatus()
}
