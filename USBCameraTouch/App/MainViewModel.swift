import SwiftUI
import AVFoundation

/// Drives the camera + sender and republishes status to the UI.
/// M1 scope: preview + start/stop streaming + camera switch. Touch control (M2)
/// will attach a ReverseChannelParser to `sender.onReverseBytes`.
final class MainViewModel: ObservableObject {
    @Published var status: RuntimeStatus = .idle
    @Published var config: RuntimeConfig = .defaultValue
    @Published var isStreaming = false
    @Published var cameraAuthorized = false
    @Published var lastTouch = ""        // M2 debug: last received 'TC' touch
    @Published var touchCount = 0
    @Published var rxBytes = 0           // reverse-channel total bytes (ACK+touch)
    @Published var rxHex = ""            // last reverse bytes (hex), for protocol debug
    @Published var rxNonZero = 0         // count of non-0x00 bytes (0x00 = the ACK)
    @Published var rxNonZeroHex = ""     // sticky: last batch that contained a non-0x00 byte

    private let sender = FrameStreamSender()
    private lazy var camera = CameraCaptureController(sender: sender)

    // M2: reverse channel → parser → ACK + touch → camera control.
    private let parser = ReverseChannelParser()
    private lazy var touchController = TouchController(
        deviceProvider: { [weak self] in self?.camera.device },
        config: config
    )

    var previewLayer: AVCaptureVideoPreviewLayer { camera.previewLayer }

    init() {
        sender.onStatus = { [weak self] snapshot in
            // FrameStreamSender delivers on the main queue already; guard anyway.
            DispatchQueue.main.async { self?.status = snapshot }
        }
        // M2: route the reverse channel through the parser. Setting
        // onReverseBytes disables the M1 "every byte = ACK" built-in path.
        sender.onReverseBytes = { [weak self] data in
            self?.noteReverse(data)
            self?.parser.feed(data)
        }
        parser.onAck = { [weak self] in self?.sender.ackReceived() }
        parser.onTouch = { [weak self] contacts in
            self?.touchController.handle(contacts)
        }
        // Visibility: surface received touch points in the UI for M2 debug.
        touchController.onTouchReceived = { [weak self] contacts in
            let desc: String
            if let c = contacts.first {
                desc = "\(contacts.count)pt id\(c.touchId) (\(c.x),\(c.y)) \(c.tipDown ? "down" : "up")"
            } else {
                desc = "0pt (release)"
            }
            DispatchQueue.main.async {
                self?.touchCount += 1
                self?.lastTouch = desc
            }
        }
    }

    func onAppear() {
        CameraCaptureController.requestAccess { [weak self] granted in
            guard let self else { return }
            self.cameraAuthorized = granted
            guard granted else { return }
            self.camera.configure(position: self.config.cameraPosition)
            self.camera.start()   // local preview; streaming to device is separate
        }
    }

    func startStreaming() {
        guard cameraAuthorized else { return }
        sender.start(config: config)
        isStreaming = true
    }

    func stopStreaming() {
        sender.stop()
        isStreaming = false
    }

    func toggleCamera() {
        config.cameraPosition = (config.cameraPosition == .back) ? .front : .back
        camera.switchCamera(to: config.cameraPosition)
    }

    // Local pinch-to-zoom (iPhone screen gesture).
    private var zoomBase: CGFloat = 1.0
    func pinchZoom(_ magnification: CGFloat) {
        camera.setZoom(zoomBase * magnification)
    }
    func endPinch() {
        zoomBase = camera.currentZoom
    }

    // M2 debug: raw reverse-channel visibility — distinguishes "FW not sending"
    // vs "parser not matching". Shows total bytes + last bytes in hex.
    private func noteReverse(_ data: Data) {
        let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let nonZeroCount = data.reduce(0) { $0 + ($1 != 0x00 ? 1 : 0) }
        DispatchQueue.main.async {
            self.rxBytes += data.count
            self.rxHex = hex
            if nonZeroCount > 0 {
                self.rxNonZero += nonZeroCount
                self.rxNonZeroHex = hex   // sticky — only overwritten by another non-zero batch
            }
        }
    }
}
