import Foundation
import Network

/// TCP server that sends a stream, the H.264 video or the PCM audio, to every connected client,
/// or receives one, the PC's speaker audio.
/// Over USB the PC reaches it through usbmuxd (`iproxy`); over WiFi a PC can connect to the phone's IP directly.
final class StreamServer {
    var onClientsChanged: ((Int) -> Void)?
    /// When set, called on the server's queue with whatever a client sends.
    var onReceive: ((Data) -> Void)?

    private final class Client {
        let connection: NWConnection
        var waitingForKeyframe = true
        var pendingSends = 0
        init(connection: NWConnection) { self.connection = connection }
    }

    /// About one second of video or half a second of audio.
    /// A client further behind skips ahead to the next keyframe instead of lagging more.
    static let maxPendingSends = 30

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "cleancam.server")
    // Used on `queue` only.
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]

    private let lock = NSLock()
    private var clientCount = 0
    private var peakBacklog = 0

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    var hasClients: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clientCount > 0
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clientCount
    }

    /// The most sends any client had waiting since the last call, up to `maxPendingSends`.
    /// It grows when the link carries less than the stream sends.
    func takePeakBacklog() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let peak = peakBacklog
        peakBacklog = 0
        return peak
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

    /// Closes every client's connection; a client that connects again starts at the next keyframe.
    func disconnectAll() {
        queue.async {
            for id in Array(self.clients.keys) { self.remove(id) }
        }
    }

    func broadcast(_ data: Data, isKeyframe: Bool) {
        queue.async {
            var backlog = 0
            for (id, client) in self.clients {
                if client.waitingForKeyframe {
                    guard isKeyframe else { continue }
                    client.waitingForKeyframe = false
                }
                backlog = max(backlog, client.pendingSends)
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
            self.lock.lock()
            self.peakBacklog = max(self.peakBacklog, backlog)
            self.lock.unlock()
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
        if onReceive != nil { receive(from: client, id: id) }
    }

    private func receive(from client: Client, id: ObjectIdentifier) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(data) }
            if isComplete || error != nil {
                self.remove(id)
            } else {
                self.receive(from: client, id: id)
            }
        }
    }

    private func remove(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        clientsChanged()
    }

    private func clientsChanged() {
        let count = clients.count
        lock.lock()
        clientCount = count
        lock.unlock()
        onClientsChanged?(count)
    }
}
