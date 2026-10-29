import AutopingCore
import Darwin
import Foundation

struct ResolvedAddress: Sendable, Equatable {
    let family: ICMPPacket.Family
    /// A `sockaddr_in` or `sockaddr_in6`.
    let socketAddress: Data
    let text: String
}

enum PingError: LocalizedError {
    case resolution(host: String, reason: String)
    case noAddress(host: String, preference: AddressPreference)
    case socket(reason: String)

    var errorDescription: String? {
        switch self {
        case let .resolution(host, reason):
            String(localized: "Could not resolve \(host): \(reason)")
        case let .noAddress(host, preference):
            String(localized: "\(host) has no \(preference.title) address")
        case let .socket(reason):
            String(localized: "Could not open ICMP socket: \(reason)")
        }
    }
}

/// Sends ICMP echo requests to one host through an unprivileged datagram socket
/// (the modern equivalent of Apple's SimplePing sample that autoping 1.x used).
/// Supports IPv4 and IPv6; with `.automatic` it falls back to the next resolved
/// address when the system has no route for the first one.
@MainActor
final class ICMPPinger {
    enum Event {
        case started(ResolvedAddress)
        case failed(PingError)
        /// The system refused to send, e.g. "No route to host". Reported once per socket.
        case sendFailed(reason: String)
        case reply(sequence: UInt16, received: Date)
    }

    let host: String
    private let preference: AddressPreference
    private let identifier = UInt16.random(in: .min ... .max)
    private let onEvent: (Event) -> Void

    private var addresses: [ResolvedAddress] = []
    private var addressIndex = 0
    private var socketDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var reportedSendFailure = false
    private var resolveTask: Task<Void, Never>?
    private static let readQueue = DispatchQueue(label: "Autoping.icmp-read", qos: .userInteractive)

    private(set) var address: ResolvedAddress?
    var isReady: Bool { socketDescriptor >= 0 }

    init(host: String, preference: AddressPreference, onEvent: @escaping (Event) -> Void) {
        self.host = host
        self.preference = preference
        self.onEvent = onEvent
    }

    func start() {
        let host = host
        let preference = preference
        resolveTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.resolve(host, preference: preference) }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case let .success(addresses):
                self.addresses = addresses
                self.openSocket(at: 0)
            case let .failure(error):
                self.onEvent(.failed(error as? PingError ?? .socket(reason: error.localizedDescription)))
            }
        }
    }

    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        closeSocket()
    }

    func send(sequence: UInt16) {
        guard socketDescriptor >= 0, let address else { return }
        let packet = ICMPPacket.echoRequest(family: address.family, identifier: identifier, sequence: sequence)
        let descriptor = socketDescriptor
        let result = address.socketAddress.withUnsafeBytes { target in
            packet.withUnsafeBytes { bytes in
                sendto(
                    descriptor, bytes.baseAddress, bytes.count, 0,
                    target.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(target.count)
                )
            }
        }
        guard result < 0 else { return }

        let error = errno
        if [EHOSTUNREACH, ENETUNREACH, EADDRNOTAVAIL].contains(error), addressIndex + 1 < addresses.count {
            openSocket(at: addressIndex + 1)
        } else if !reportedSendFailure {
            // The ping stays unanswered and is counted as lost; just tell why.
            reportedSendFailure = true
            onEvent(.sendFailed(reason: String(cString: strerror(error))))
        }
    }

    // MARK: - Socket

    private func openSocket(at index: Int) {
        closeSocket()
        let address = addresses[index]
        let descriptor = address.family == .v4
            ? socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            : socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard descriptor >= 0 else {
            onEvent(.failed(.socket(reason: String(cString: strerror(errno)))))
            return
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        let family = address.family
        let identifier = identifier
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: Self.readQueue)
        // Both handlers run on `readQueue`; @Sendable keeps them from inheriting
        // main-actor isolation (which Swift checks, and traps on, at run time).
        source.setEventHandler { @Sendable [weak self] in
            // Timestamp off the main thread so UI work cannot inflate the round-trip time.
            let replies = Self.receiveReplies(from: descriptor, family: family, identifier: identifier)
            guard !replies.isEmpty, let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.socketDescriptor == descriptor else { return }
                    for (sequence, received) in replies {
                        self.onEvent(.reply(sequence: sequence, received: received))
                    }
                }
            }
        }
        source.setCancelHandler { @Sendable in close(descriptor) }
        source.resume()

        socketDescriptor = descriptor
        readSource = source
        reportedSendFailure = false
        addressIndex = index
        self.address = address
        onEvent(.started(address))
    }

    private func closeSocket() {
        readSource?.cancel() // closes the descriptor
        readSource = nil
        socketDescriptor = -1
        address = nil
    }

    private nonisolated static func receiveReplies(
        from descriptor: Int32, family: ICMPPacket.Family, identifier: UInt16
    ) -> [(UInt16, Date)] {
        var replies: [(UInt16, Date)] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            let received = Date()
            if let reply = ICMPPacket.parseEchoReply(Array(buffer[0..<count]), family: family),
               reply.identifier == identifier {
                replies.append((reply.sequence, received))
            }
        }
        return replies
    }

    // MARK: - Name resolution

    private nonisolated static func resolve(_ host: String, preference: AddressPreference) throws -> [ResolvedAddress] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = switch preference {
        case .automatic: AF_UNSPEC
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }

        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        guard status == 0 else {
            if status == EAI_NONAME, preference != .automatic {
                throw PingError.noAddress(host: host, preference: preference)
            }
            throw PingError.resolution(host: host, reason: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(list) }

        var addresses: [ResolvedAddress] = []
        var entry = list
        while let info = entry?.pointee {
            defer { entry = info.ai_next }
            guard let socketAddress = info.ai_addr,
                  info.ai_family == AF_INET || info.ai_family == AF_INET6 else { continue }

            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(socketAddress, info.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
            let resolved = ResolvedAddress(
                family: info.ai_family == AF_INET ? .v4 : .v6,
                socketAddress: Data(bytes: socketAddress, count: Int(info.ai_addrlen)),
                text: String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            )
            if !addresses.contains(resolved) { addresses.append(resolved) }
        }
        guard !addresses.isEmpty else { throw PingError.noAddress(host: host, preference: preference) }
        return addresses
    }
}
