import Foundation
import AVFoundation

/// AVFoundation camera capture. Replaces USBDisplay's ReplayKit `SampleHandler`:
/// each video frame (`CMSampleBuffer`) is forwarded to `FrameStreamSender.submit`,
/// which then reuses the exact same encode → pace → send path as USBDisplay.
///
/// The `device` is exposed so `TouchController` (M2) can drive focus/exposure/zoom.
final class CameraCaptureController: NSObject,
                                     AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "usbcameratouch.camera.samples")
    private let sessionQueue = DispatchQueue(label: "usbcameratouch.camera.session")

    private weak var sender: FrameStreamSender?
    private(set) var currentInput: AVCaptureDeviceInput?

    /// The active capture device — TouchController uses it for POI/zoom (M2).
    private(set) var device: AVCaptureDevice?

    /// Preview layer bound to the session; attach it to a UIView in the UI layer.
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        return layer
    }()

    init(sender: FrameStreamSender) {
        self.sender = sender
        super.init()
    }

    // MARK: - Permission

    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Configuration

    func configure(
        position: CameraPosition,
        preset: AVCaptureSession.Preset = .hd1280x720
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()

            if self.session.canSetSessionPreset(preset) {
                self.session.sessionPreset = preset
            }

            self.setInputLocked(position: position)

            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sampleQueue)

            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            // Portrait orientation for the outgoing image. NOTE: this sets the
            // pixel geometry the device displays AND that touch coords map back
            // to — keep it consistent with TouchController's mapping (M2, SPEC §5).
            if let conn = self.videoOutput.connection(with: .video),
               conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }

            self.session.commitConfiguration()
        }
    }

    private func setInputLocked(position: CameraPosition) {
        let avPosition: AVCaptureDevice.Position =
            position == .back ? .back : .front

        guard
            let newDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: avPosition
            ),
            let newInput = try? AVCaptureDeviceInput(device: newDevice)
        else { return }

        if let existing = currentInput {
            session.removeInput(existing)
        }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
        }
        currentInput = newInput
        device = newDevice
    }

    func switchCamera(to position: CameraPosition) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.setInputLocked(position: position)
            self.session.commitConfiguration()
        }
    }

    // MARK: - Zoom

    /// Set camera zoom (1.0 = none). Clamped to [1, min(maxAvailable, 10)].
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                let maxZ = min(device.maxAvailableVideoZoomFactor, 10.0)
                device.videoZoomFactor = max(1.0, min(factor, maxZ))
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Current zoom factor (gesture base).
    var currentZoom: CGFloat { device?.videoZoomFactor ?? 1.0 }

    // MARK: - Run

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sender?.submit(sampleBuffer)
    }
}
