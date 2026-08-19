import Foundation
import AVFoundation

/// Maps `'TC'` touch contacts (640×1136 panel coords) to camera controls.
/// M2 scope: single-tap → focus + exposure POI. Zoom / exposure-bias are M3.
final class TouchController {
    /// Panel resolution the device maps touches into (8808 §10.5). Hard-coded for
    /// per1_ios_ncmdisplay; make dynamic if other panels are supported (SPEC §12.3).
    var panelWidth: CGFloat = 640
    var panelHeight: CGFloat = 1136

    private let deviceProvider: () -> AVCaptureDevice?
    private var config: RuntimeConfig

    private struct TouchState {
        var startNX: CGFloat
        var startNY: CGFloat
        var startTime: TimeInterval
        var moved: Bool
    }
    private var active = [UInt8: TouchState]()   // keyed by touchId

    private let tapMaxDuration: TimeInterval = 0.4
    private let tapMaxMove: CGFloat = 0.03       // normalized units

    init(deviceProvider: @escaping () -> AVCaptureDevice?, config: RuntimeConfig) {
        self.deviceProvider = deviceProvider
        self.config = config
    }

    func updateConfig(_ newConfig: RuntimeConfig) { config = newConfig }

    /// Fires on every received 'TC' event (for UI visibility/debug), before
    /// gesture processing. Wire to the ViewModel to show "touch received".
    var onTouchReceived: (([ReverseChannelParser.Contact]) -> Void)?

    /// Called by ReverseChannelParser on the sender/transport queue (serial), so
    /// `active` needs no extra locking.
    func handle(_ contacts: [ReverseChannelParser.Contact]) {
        onTouchReceived?(contacts)

        // Two-finger pinch → camera zoom (8808 panel).
        if config.touchZoom, contacts.count == 2,
           contacts[0].tipDown, contacts[1].tipDown {
            handlePinch(contacts[0], contacts[1])
            return
        }
        pinchStartDist = nil

        let now = Date().timeIntervalSince1970

        for c in contacts {
            let nx = clamp01(CGFloat(c.x) / panelWidth)
            let ny = clamp01(CGFloat(c.y) / panelHeight)

            if c.tipDown {
                if var st = active[c.touchId] {
                    if abs(nx - st.startNX) > tapMaxMove ||
                       abs(ny - st.startNY) > tapMaxMove {
                        st.moved = true
                        active[c.touchId] = st
                    }
                } else {
                    active[c.touchId] = TouchState(
                        startNX: nx, startNY: ny, startTime: now, moved: false
                    )
                }
            } else {
                // tip up → gesture end. Tap = primary finger, short, little move.
                if let st = active[c.touchId] {
                    active[c.touchId] = nil
                    let isTap = !st.moved && (now - st.startTime) <= tapMaxDuration
                    if isTap && c.touchId == 0 {
                        applyFocusExposure(nx: nx, ny: ny)
                    }
                }
            }
        }
    }

    private func applyFocusExposure(nx: CGFloat, ny: CGFloat) {
        guard config.touchFocus || config.touchExposure else { return }
        guard let device = deviceProvider() else { return }

        // Normalized panel point → device POI. AVFoundation POI origin is
        // top-left of landscapeRight sensor space; the outgoing image is portrait
        // (videoRotationAngle = 90). This is the portrait starting guess —
        // CALIBRATE on device with a four-corner tap (SPEC §12.3).
        let poi = CGPoint(x: ny, y: 1.0 - nx)

        do {
            try device.lockForConfiguration()
            if config.touchFocus,
               device.isFocusPointOfInterestSupported,
               device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = poi
                device.focusMode = .autoFocus
            }
            if config.touchExposure,
               device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = poi
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        } catch {
            // best-effort; ignore lock failures
        }
    }

    private func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

    // MARK: - Pinch zoom (two-finger, from 8808 panel)

    private var pinchStartDist: CGFloat?
    private var pinchBaseZoom: CGFloat = 1.0

    private func handlePinch(_ a: ReverseChannelParser.Contact,
                             _ b: ReverseChannelParser.Contact) {
        let dist = hypot(CGFloat(a.x) - CGFloat(b.x), CGFloat(a.y) - CGFloat(b.y))
        guard let device = deviceProvider() else { return }
        if let start = pinchStartDist, start > 0 {
            let target = pinchBaseZoom * (dist / start)
            do {
                try device.lockForConfiguration()
                let maxZ = min(device.maxAvailableVideoZoomFactor, 10.0)
                device.videoZoomFactor = max(1.0, min(target, maxZ))
                device.unlockForConfiguration()
            } catch {}
        } else {
            pinchStartDist = dist
            pinchBaseZoom = device.videoZoomFactor
        }
    }
}
