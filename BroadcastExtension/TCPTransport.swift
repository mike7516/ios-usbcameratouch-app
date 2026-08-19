import Foundation
import Network

final class TCPTransport: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case disconnected(String)
        case reconnecting(String)
    }

    var onStateChanged: ((State) -> Void)?
    var onReady: (() -> Void)?
    var onRemoteClosed: ((String) -> Void)?
    var onData: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "usbdisplay.tcp.transport")
    private var connection: NWConnection?
    private var reconnectWorkItem: DispatchWorkItem?

    private var host = RuntimeConstants.deviceHost
    private var port = RuntimeConstants.devicePort
    private var shouldRun = false
    private var reconnectEnabled = false
    private var ready = false

    func start(
        host: String = RuntimeConstants.deviceHost,
        port: UInt16 = RuntimeConstants.devicePort,
        reconnect: Bool
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            self.stopLocked(publishIdle: false)
            self.host = host
            self.port = port
            self.reconnectEnabled = reconnect
            self.shouldRun = true
            self.connectLocked(reconnecting: false)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked(publishIdle: true)
        }
    }

    func send(
        _ data: Data,
        completion: @escaping (Error?) -> Void
    ) {
        queue.async { [weak self] in
            guard
                let self,
                self.ready,
                let connection = self.connection
            else {
                completion(TransportError.notConnected)
                return
            }

            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    guard let self else {
                        completion(error)
                        return
                    }

                    self.queue.async {
                        completion(error)

                        if let error {
                            self.handleDisconnectLocked(
                                reason: error.localizedDescription
                            )
                        }
                    }
                }
            )
        }
    }

    private func connectLocked(reconnecting: Bool) {
        guard shouldRun else { return }

        ready = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            handleDisconnectLocked(reason: "Invalid port")
            return
        }

        publish(
            reconnecting
            ? .reconnecting("retry \(host):\(port)")
            : .connecting
        )

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3

        let parameters = NWParameters(tls: nil, tcp: tcp)

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )

        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }

            self.queue.async {
                guard self.connection === connection else { return }

                switch state {
                case .setup:
                    break

                case .preparing:
                    if !reconnecting {
                        self.publish(.connecting)
                    }

                case .ready:
                    self.ready = true
                    self.publish(.ready)
                    self.onReady?()
                    self.receiveLoopLocked(connection)

                case .waiting(let error):
                    self.handleDisconnectLocked(
                        reason: self.describe(error)
                    )

                case .failed(let error):
                    self.handleDisconnectLocked(
                        reason: self.describe(error)
                    )

                case .cancelled:
                    if self.shouldRun && self.reconnectEnabled {
                        self.scheduleReconnectLocked(
                            reason: "Connection cancelled"
                        )
                    }

                @unknown default:
                    break
                }
            }
        }

        connection.start(queue: queue)
    }

    private func receiveLoopLocked(_ connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            self.queue.async {
                guard self.connection === connection, self.shouldRun else {
                    return
                }

                if let error {
                    self.handleDisconnectLocked(
                        reason: self.describe(error)
                    )
                    return
                }

                if let data, !data.isEmpty {
                    self.onData?(data)
                }

                if isComplete {
                    let reason = "Device closed TCP connection"
                    self.onRemoteClosed?(reason)
                    self.handleDisconnectLocked(reason: reason)
                    return
                }

                self.receiveLoopLocked(connection)
            }
        }
    }

    private func handleDisconnectLocked(reason: String) {
        guard shouldRun else { return }

        ready = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        publish(.disconnected(reason))

        if reconnectEnabled {
            scheduleReconnectLocked(reason: reason)
        } else {
            shouldRun = false
        }
    }

    private func scheduleReconnectLocked(reason: String) {
        guard shouldRun, reconnectEnabled else { return }

        reconnectWorkItem?.cancel()

        publish(
            .reconnecting(
                "retry after " +
                String(
                    format: "%.1fs",
                    RuntimeConstants.reconnectIntervalSeconds
                )
            )
        )

        let work = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let self, self.shouldRun else { return }
                self.connectLocked(reconnecting: true)
            }
        }

        reconnectWorkItem = work

        queue.asyncAfter(
            deadline: .now() + RuntimeConstants.reconnectIntervalSeconds,
            execute: work
        )
    }

    private func stopLocked(publishIdle: Bool) {
        shouldRun = false
        reconnectEnabled = false
        ready = false

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        if publishIdle {
            publish(.idle)
        }
    }

    private func publish(_ state: State) {
        onStateChanged?(state)
    }

    private func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            let nsError = NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code.rawValue),
                userInfo: nil
            )
            return "POSIX \(code.rawValue): \(nsError.localizedDescription)"

        case .dns(let code):
            return "DNS \(code)"

        case .tls(let code):
            return "TLS \(code)"

        @unknown default:
            return "\(error)"
        }
    }

    enum TransportError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            "TCP is not connected"
        }
    }
}
