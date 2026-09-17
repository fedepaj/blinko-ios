import Foundation
import Network

/// Remote session server: a TCP listener (port 7777) through which a computer drives the app
/// (record, grab a frame, change settings) and receives live stats, messages and files.
///
/// Framing, both directions: u32 big-endian length | u8 kind (0 = JSON, 1 = binary) | payload.
/// Binary payloads are always announced by the JSON message that precedes them.
/// Reach it over Wi-Fi (address shown in Settings) or over USB with
/// `pymobiledevice3 usbmux forward 7777 7777` and then localhost:7777.
final class RemoteServer {
    static let port: UInt16 = 7777

    /// A command from a client; `reply` sends JSON (+ optional binary) back to that client only.
    var onCommand: ((_ cmd: [String: Any], _ reply: @escaping ([String: Any], Data?) -> Void) -> Void)?
    var onClientsChanged: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "rslog.remote")
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private(set) var isRunning = false

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) else {
                Diag.log("[remote] listener failed"); return
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { state in Diag.log("[remote] listener \(state)") }
            l.start(queue: self.queue)
            self.listener = l
            self.isRunning = true
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil; self.isRunning = false
            for c in self.conns.values { c.cancel() }
            self.conns.removeAll()
            self.onClientsChanged?(0)
        }
    }

    var clientCount: Int { queue.sync { conns.count } }

    /// Send to every connected client.
    func broadcast(_ json: [String: Any], binary: Data? = nil) {
        queue.async {
            guard !self.conns.isEmpty, let framed = Self.frame(json, binary) else { return }
            for c in self.conns.values { c.send(content: framed, completion: .contentProcessed { _ in }) }
        }
    }

    // MARK: - connections

    private func accept(_ c: NWConnection) {
        let key = ObjectIdentifier(c)
        conns[key] = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(key)
            default: break
            }
        }
        c.start(queue: queue)
        onClientsChanged?(conns.count)
        Diag.log("[remote] client connected (\(conns.count))")
        readMessage(c)
    }

    private func remove(_ key: ObjectIdentifier) {
        if let c = conns.removeValue(forKey: key) { c.cancel() }
        onClientsChanged?(conns.count)
    }

    private func readMessage(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self = self, let d = data, d.count == 5, error == nil else { self?.remove(ObjectIdentifier(c)); return }
            let b = [UInt8](d)
            let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            let kind = b[4]
            guard len > 0, len < 64 * 1024 * 1024 else { self.readMessage(c); return }
            c.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, _, error in
                guard let self = self, let p = data, p.count == len, error == nil else { self?.remove(ObjectIdentifier(c)); return }
                if kind == 0, let obj = try? JSONSerialization.jsonObject(with: p) as? [String: Any] {
                    let reply: ([String: Any], Data?) -> Void = { [weak c] json, bin in
                        guard let c = c, let framed = Self.frame(json, bin) else { return }
                        c.send(content: framed, completion: .contentProcessed { _ in })
                    }
                    if let h = self.onCommand { h(obj, reply) } else { reply(["type": "error", "msg": "no handler"], nil) }
                }
                self.readMessage(c)
            }
        }
    }

    private static func frame(_ json: [String: Any], _ binary: Data?) -> Data? {
        guard let j = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        var out = Data()
        out.append(header(j.count, kind: 0)); out.append(j)
        if let b = binary { out.append(header(b.count, kind: 1)); out.append(b) }
        return out
    }

    private static func header(_ len: Int, kind: UInt8) -> Data {
        let n = UInt32(len)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff), kind])
    }

    /// First IPv4 address of the Wi-Fi interface, for the Settings screen.
    static func localIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var result: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name == "en0" || (result == nil && name.hasPrefix("en")) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
                if name == "en0" { break }
            }
        }
        return result
    }
}
