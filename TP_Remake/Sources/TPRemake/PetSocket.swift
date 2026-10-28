import Foundation

/// Socket UNIX en datagrammes : `hook` envoie, l'app écoute.
enum PetSocket {
    /// Un chemin de socket UNIX tient dans 103 octets ; au-delà on refuse plutôt que de tronquer.
    static let maxPathLength = 103

    fileprivate static func address(_ path: String) -> sockaddr_un? {
        guard path.utf8.count <= maxPathLength else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strncpy($0, path, 103) }
        }
        return addr
    }

    /// Envoie un datagramme ; renvoie faux si personne n'écoute (app fermée).
    static func send(_ data: Data, to socketURL: URL) -> Bool {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var addr = address(socketURL.path) else { return false }
        let sent = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        return sent == data.count
    }

    final class Listener {
        private var source: DispatchSourceRead?
        private var fd: Int32 = -1

        func start(at socketURL: URL, handler: @escaping (Data) -> Void) -> Bool {
            unlink(socketURL.path)
            fd = socket(AF_UNIX, SOCK_DGRAM, 0)
            guard fd >= 0 else { return false }
            guard var addr = PetSocket.address(socketURL.path) else { close(fd); return false }
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { close(fd); return false }
            let fd = self.fd
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            src.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let n = recv(fd, &buffer, buffer.count, 0)
                if n > 0 { handler(Data(buffer[0..<n])) }
            }
            src.setCancelHandler { close(fd); unlink(socketURL.path) }
            src.resume()
            source = src
            return true
        }
    }
}

/// Socket éphémère du hook pour recevoir la décision de l'app (une seule réponse).
final class ReplySocket {
    let url: URL
    private var fd: Int32 = -1

    init?(url: URL) {
        self.url = url
        unlink(url.path)
        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = PetSocket.address(url.path) else { close(fd); return nil }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); return nil }
    }

    /// Attend une réponse au plus `timeout` secondes.
    func wait(timeout: TimeInterval) -> Data? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buffer, buffer.count, 0)
        return n > 0 ? Data(buffer[0..<n]) : nil
    }

    deinit { if fd >= 0 { close(fd) }; unlink(url.path) }
}

/// Une seule instance de l'app : verrou exclusif sur run/pet.pid.
enum PetLock {
    private static var fd: Int32 = -1

    static func acquire(_ dd: DataDir) -> Bool {
        dd.prepare()
        fd = open(dd.lock.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        ftruncate(fd, 0)
        _ = "\(getpid())\n".withCString { write(fd, $0, strlen($0)) }
        return true
    }
}
