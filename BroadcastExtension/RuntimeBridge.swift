import Foundation

/// Transient IPC only. This is NOT configuration persistence.
/// MainViewModel resets everything on every application launch.
enum RuntimeBridge {
    private enum Key {
        static let config = "runtime.config"
        static let status = "runtime.status"
        static let stopRequest = "runtime.stopRequest"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: RuntimeConstants.appGroupID)
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                RuntimeConstants.appGroupID
        )
    }

    private static var previewURL: URL? {
        containerURL?.appendingPathComponent("latest-preview.jpg")
    }

    static func resetForNewLaunch() {
        writeConfig(.defaultValue)
        writeStatus(.idle)
        defaults?.set(0, forKey: Key.stopRequest)
        if let previewURL {
            try? FileManager.default.removeItem(at: previewURL)
        }
    }

    static func writeConfig(_ config: RuntimeConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults?.set(data, forKey: Key.config)
    }

    static func readConfig() -> RuntimeConfig {
        guard
            let data = defaults?.data(forKey: Key.config),
            let value = try? JSONDecoder().decode(RuntimeConfig.self, from: data)
        else {
            return .defaultValue
        }
        return value
    }

    static func writeStatus(_ status: RuntimeStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        defaults?.set(data, forKey: Key.status)
    }

    static func readStatus() -> RuntimeStatus {
        guard
            let data = defaults?.data(forKey: Key.status),
            let value = try? JSONDecoder().decode(RuntimeStatus.self, from: data)
        else {
            return .idle
        }
        return value
    }

    static func requestStop() -> UInt64 {
        let next = currentStopRequest() &+ 1
        defaults?.set(Int(next), forKey: Key.stopRequest)
        return next
    }

    static func currentStopRequest() -> UInt64 {
        UInt64(defaults?.integer(forKey: Key.stopRequest) ?? 0)
    }

    static func writePreview(_ jpeg: Data) {
        guard let previewURL else { return }
        try? jpeg.write(to: previewURL, options: .atomic)
    }

    static func readPreview() -> Data? {
        guard let previewURL else { return nil }
        return try? Data(contentsOf: previewURL)
    }

    // MARK: - Metrics log (App Group shared container)
    //
    // Per-frame CSV written by whichever sender is active (the extension
    // writes it during SCREEN even while the main app is backgrounded).
    // Pull it off the device afterward for offline analysis.

    private static var metricsURL: URL? {
        containerURL?.appendingPathComponent("metrics.csv")
    }

    private static var metricsHandle: FileHandle?

    static func resetMetricsLog() {
        try? metricsHandle?.close()
        metricsHandle = nil
        guard let metricsURL else { return }
        let header = "epoch,mode,frame,encodeMs,sendMs,cap2sendMs,rttMs,jpegBytes,mbps,fps,instFps\n"
        try? header.write(to: metricsURL, atomically: true, encoding: .utf8)
        if let handle = try? FileHandle(forWritingTo: metricsURL) {
            try? handle.seekToEnd()
            metricsHandle = handle
        }
    }

    static func appendMetrics(_ status: RuntimeStatus, mode: String) {
        if metricsHandle == nil {
            if let metricsURL,
               FileManager.default.fileExists(atPath: metricsURL.path),
               let handle = try? FileHandle(forWritingTo: metricsURL) {
                try? handle.seekToEnd()
                metricsHandle = handle
            } else {
                resetMetricsLog()
            }
        }

        let ms = { (value: Double) in String(format: "%.1f", value) }
        let row = [
            String(format: "%.3f", Date().timeIntervalSince1970),
            mode,
            String(status.frameCount),
            ms(status.encodeMs),
            ms(status.sendMs),
            ms(status.captureToSendMs),
            status.responseMs > 0 ? ms(status.responseMs) : "",
            String(status.jpegBytes),
            String(format: "%.2f", status.mbps),
            String(format: "%.2f", status.fps),
            String(format: "%.2f", status.instantFps)
        ].joined(separator: ",") + "\n"

        if let data = row.data(using: .utf8) {
            try? metricsHandle?.write(contentsOf: data)
        }
    }
}
