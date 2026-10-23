import Foundation
import Network

/// TCP server that sends the H.264 stream to every connected client.
/// Over USB the PC reaches it through usbmuxd (`iproxy`); over WiFi a PC can connect to the phone's IP directly.
final class StreamServer {
    var onClientsChanged: ((Int) -> Void)?

    private final class Client {
        let connection: NWConnection
        var waitingForKeyframe = true
        var pendingSends = 0
        init(connection: NWConnection) { self.connection = connection }
    }

    /// About one second of video. A client further behind skips ahead to the next keyframe instead of lagging more.
    private static let maxPendingSends = 30

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "cleancam.server")
    // Used on `queue` only.
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]

    private let lock = NSLock()
    private var clientCount = 0

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    var hasClients: Bool {
        lock.withLock { clientCount > 0 }
    }

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters, on: self.port) else { return }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed = state, let self else { return }
                self.listener?.cancel()
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 1) { self.start() }
            }
            listener.start(queue: self.queue)
            self.listener = listener
            self.clientsChanged()
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for client in self.clients.values { client.connection.cancel() }
            self.clients.removeAll()
            self.clientsChanged()
        }
    }

    func broadcast(_ data: Data, isKeyframe: Bool) {
        queue.async {
            for (id, client) in self.clients {
                if client.waitingForKeyframe {
                    guard isKeyframe else { continue }
                    client.waitingForKeyframe = false
                }
                if client.pendingSends >= Self.maxPendingSends {
                    client.waitingForKeyframe = true
                    continue
                }
                client.pendingSends += 1
                client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    client.pendingSends -= 1
                    if error != nil { self?.remove(id) }
                })
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        let id = ObjectIdentifier(client)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        connection.start(queue: queue)
        clientsChanged()
    }

    private func remove(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        clientsChanged()
    }

    private func clientsChanged() {
        let count = clients.count
        lock.withLock { clientCount = count }
        onClientsChanged?(count)
    }
}
