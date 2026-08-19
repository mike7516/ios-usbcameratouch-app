import Foundation
import CoreMedia

/// ReplayKit SCREEN sender.
/// Output is PURE JPEG only:
/// FF D8 ... FF D9
/// No HEADER32 and no length prefix.
final class BroadcastStreamController {
    private let queue = DispatchQueue(
        label: "usbdisplay.broadcast.controller"
    )

    private let encodeQueue = DispatchQueue(
        label: "usbdisplay.broadcast.jpeg",
        qos: .userInitiated
    )

    private let transport = TCPTransport()
    private let encoder = JPEGEncoder()

    private var config = RuntimeConfig.defaultValue

    private var running = false
    private var connected = false
    private var encodeBusy = false
    private var sendBusy = false
    private var singleCompleted = false

    private var startTime: TimeInterval = 0
    private var frameCount: UInt64 = 0
    private var totalBytes: UInt64 = 0

    private var lastAcceptedFrameTime: TimeInterval = 0
    private var lastPreviewWriteTime: TimeInterval = 0
    private var lastSendStartTime: TimeInterval = 0
    private var lastSendDoneTime: TimeInterval = 0
    private var pendingAckTimes: [TimeInterval] = []
    private var awaitingAck = false
    private var ackTimeout: DispatchWorkItem?
    private var stopGeneration: UInt64 = 0

    private var outageAlerted = false
    private var status = RuntimeStatus.idle

    func start(config: RuntimeConfig) {
        queue.async { [weak self] in
            guard let self else { return }

            self.config = config
            self.running = true
            self.connected = false
            self.encodeBusy = false
            self.sendBusy = false
            self.singleCompleted = false

            self.frameCount = 0
            self.totalBytes = 0
            self.startTime = Date().timeIntervalSince1970
            self.lastAcceptedFrameTime = 0
            self.lastPreviewWriteTime = 0
            self.lastSendStartTime = 0
            self.lastSendDoneTime = 0
            self.pendingAckTimes.removeAll()
            self.awaitingAck = false
            self.ackTimeout?.cancel()
            self.ackTimeout = nil

            RuntimeBridge.resetMetricsLog()

            self.stopGeneration =
                RuntimeBridge.currentStopRequest()

            self.outageAlerted = false

            self.status = RuntimeStatus(
                tcpState: .connecting,
                tcpDetail:
                    "\(RuntimeConstants.deviceHost):\(RuntimeConstants.devicePort)",
                statusText: "Connecting to device...",
                frameCount: 0,
                jpegBytes: 0,
                fps: 0,
                mbps: 0,
                isSending: true,
                extensionActive: true,
                singleCompleted: false,
                disconnectGeneration: 0,
                lastError: ""
            )

            self.publishStatus()
            self.installCallbacks()

            self.transport.start(
                reconnect:
                    config.sendMode == .continuous
            )
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }

            self.running = false
            self.connected = false
            self.ackTimeout?.cancel()
            self.ackTimeout = nil
            self.awaitingAck = false
            self.transport.stop()

            self.status.isSending = false
            self.status.extensionActive = false
            self.status.tcpState = .idle
            self.status.statusText =
                "Broadcast stream stopped"

            self.publishStatus()
        }
    }

    func submit(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard
                let self,
                self.running,
                self.connected,
                !self.singleCompleted
            else {
                return
            }

            let currentStop =
                RuntimeBridge.currentStopRequest()

            if currentStop != self.stopGeneration {
                self.running = false
                self.connected = false
                self.transport.stop()

                self.status.isSending = false
                self.status.tcpState = .idle
                self.status.statusText =
                    "Stopped from Main App"

                self.publishStatus()
                return
            }

            let now = Date().timeIntervalSince1970

            if now - self.lastAcceptedFrameTime <
                (1.0 / Double(max(1, self.config.targetFps))) {
                return
            }

            // ACK flow control: one frame in flight at a time — wait for the
            // device's ACK (or the timeout) before accepting the next frame.
            if self.config.ackPaced && self.awaitingAck {
                return
            }

            guard !self.encodeBusy, !self.sendBusy else {
                return
            }

            self.lastAcceptedFrameTime = now
            self.encodeBusy = true

            let cfg = self.config
            let acceptTime = now

            self.encodeQueue.async { [weak self] in
                guard let self else { return }

                do {
                    let jpeg = try self.encoder.encode(
                        sampleBuffer: sampleBuffer,
                        width: cfg.width,
                        height: cfg.height,
                        quality: cfg.jpegQuality
                    )

                    let encodeDone = Date().timeIntervalSince1970

                    self.queue.async {
                        self.encodeBusy = false

                        guard self.running, self.connected else {
                            return
                        }

                        self.status.jpegSampling =
                            JPEGSamplingInspector.describe(jpeg)
                        self.status.encodeMs =
                            (encodeDone - acceptTime) * 1000.0

                        self.sendLocked(jpeg, acceptTime: acceptTime)
                    }

                } catch {
                    self.queue.async {
                        self.encodeBusy = false
                        self.status.lastError =
                            error.localizedDescription
                        self.status.statusText =
                            "JPEG ERROR: \(error.localizedDescription)"
                        self.publishStatus()
                    }
                }
            }
        }
    }

    private func installCallbacks() {
        transport.onStateChanged = { [weak self] state in
            guard let self else { return }

            self.queue.async {
                guard self.running else { return }

                switch state {
                case .idle:
                    self.connected = false
                    self.status.tcpState = .idle

                case .connecting:
                    self.connected = false
                    self.status.tcpState = .connecting
                    self.status.statusText =
                        "Connecting to device..."

                case .ready:
                    self.connected = true
                    self.outageAlerted = false
                    self.status.tcpState = .connected
                    self.status.tcpDetail =
                        "\(RuntimeConstants.deviceHost):\(RuntimeConstants.devicePort)"
                    self.status.statusText =
                        self.config.sendMode == .single
                        ? "Waiting for one screen frame"
                        : "Continuous sending | iOS Native JPEG"

                case .disconnected(let reason):
                    self.connected = false
                    self.markDisconnected(reason)

                case .reconnecting(let detail):
                    self.connected = false
                    self.status.tcpState = .reconnecting
                    self.status.tcpDetail = detail
                    self.status.statusText =
                        "Device unavailable - waiting to reconnect..."
                }

                self.publishStatus()
            }
        }

        transport.onRemoteClosed = { [weak self] reason in
            self?.queue.async {
                self?.markDisconnected(reason)
            }
        }

        transport.onData = { [weak self] data in
            self?.queue.async {
                guard let self else { return }
                let now = Date().timeIntervalSince1970
                // Device sends one 1-byte ACK per processed frame; match each
                // ACK to the oldest outstanding send (FIFO) for a true RTT.
                var rtt: Double?
                for _ in 0..<data.count {
                    if self.pendingAckTimes.isEmpty { break }
                    rtt = (now - self.pendingAckTimes.removeFirst()) * 1000.0
                }
                if let rtt {
                    self.status.responseMs = rtt
                    self.publishStatus()
                }
                // ACK arrived → open the gate for the next frame.
                if self.config.ackPaced && self.pendingAckTimes.isEmpty {
                    self.ackTimeout?.cancel()
                    self.ackTimeout = nil
                    self.awaitingAck = false
                }
            }
        }
    }

    private func sendLocked(_ jpeg: Data, acceptTime: TimeInterval) {
        guard !sendBusy else { return }

        sendBusy = true
        let sendStart = Date().timeIntervalSince1970
        lastSendStartTime = sendStart
        pendingAckTimes.append(sendStart)
        if pendingAckTimes.count > 240 {
            pendingAckTimes.removeFirst(pendingAckTimes.count - 240)
        }

        if config.ackPaced {
            awaitingAck = true
            ackTimeout?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    if !self.pendingAckTimes.isEmpty {
                        self.pendingAckTimes.removeFirst()
                    }
                    self.awaitingAck = false
                }
            }
            ackTimeout = work
            queue.asyncAfter(
                deadline: .now() + RuntimeConstants.ackTimeoutSeconds,
                execute: work
            )
        }

        transport.send(jpeg) { [weak self] error in
            guard let self else { return }

            self.queue.async {
                self.sendBusy = false

                guard self.running else { return }

                if let error {
                    self.status.lastError =
                        error.localizedDescription
                    self.publishStatus()
                    return
                }

                let sendDone = Date().timeIntervalSince1970
                self.status.sendMs =
                    (sendDone - sendStart) * 1000.0
                self.status.captureToSendMs =
                    (sendDone - acceptTime) * 1000.0
                if self.lastSendDoneTime > 0 {
                    let dt = sendDone - self.lastSendDoneTime
                    if dt > 0 {
                        self.status.instantFps = 1.0 / dt
                    }
                }
                self.lastSendDoneTime = sendDone

                self.frameCount &+= 1
                self.totalBytes &+= UInt64(jpeg.count)
                self.updateStatisticsLocked(
                    jpegBytes: jpeg.count
                )

                RuntimeBridge.appendMetrics(self.status, mode: "SCREEN")

                let now = Date().timeIntervalSince1970

                if now - self.lastPreviewWriteTime >= 1.0 {
                    self.lastPreviewWriteTime = now
                    RuntimeBridge.writePreview(jpeg)
                }

                if self.config.sendMode == .single {
                    self.singleCompleted = true
                    self.status.isSending = false
                    self.status.singleCompleted = true
                    self.status.tcpState = .idle
                    self.status.statusText =
                        "Single frame completed | TCP connection closed"
                    self.publishStatus()
                    self.transport.stop()
                }
            }
        }
    }

    private func updateStatisticsLocked(jpegBytes: Int) {
        let elapsed = max(
            Date().timeIntervalSince1970 - startTime,
            0.000001
        )

        status.frameCount = frameCount
        status.jpegBytes = jpegBytes
        status.fps = Double(frameCount) / elapsed
        status.mbps =
            Double(totalBytes) *
            8.0 /
            elapsed /
            1_000_000.0

        publishStatus()
    }

    private func markDisconnected(_ reason: String) {
        status.tcpState = .disconnected
        status.tcpDetail = reason
        status.statusText = "Device disconnected"
        status.lastError = reason

        if !outageAlerted {
            outageAlerted = true
            status.disconnectGeneration &+= 1
        }

        publishStatus()
    }

    private func publishStatus() {
        RuntimeBridge.writeStatus(status)
    }
}
