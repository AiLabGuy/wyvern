// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

enum IPFamily: Equatable, Sendable {
    case v4
    case v6
}

/// One resolved socket address. Built only from `getaddrinfo` or `inet_pton`.
struct ResolvedPeer {
    var ip: String
    var family: IPFamily
    var storage: sockaddr_storage
    var length: socklen_t

    func withPort(_ port: UInt16) -> ResolvedPeer {
        var copy = self
        let networkPort = port.bigEndian
        if family == .v4 {
            withUnsafeMutableBytes(of: &copy.storage) { raw in
                let pointer = raw.bindMemory(to: sockaddr_in.self)
                pointer.baseAddress?.pointee.sin_port = networkPort
            }
        } else {
            withUnsafeMutableBytes(of: &copy.storage) { raw in
                let pointer = raw.bindMemory(to: sockaddr_in6.self)
                pointer.baseAddress?.pointee.sin6_port = networkPort
            }
        }
        return copy
    }
}

enum SystemDNS {
    /// Local resolver. Numeric hosts do not leave the machine.
    static func lookup(_ host: String) -> ResolvedPeer? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var head: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(trimmed, nil, &hints, &head)
        guard code == 0, let head else { return nil }
        defer { freeaddrinfo(head) }
        var matches: [ResolvedPeer] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let node = cursor {
            if let peer = peer(from: node.pointee) {
                matches.append(peer)
            }
            cursor = node.pointee.ai_next
        }
        return matches.first { $0.family == .v4 } ?? matches.first
    }

    /// Parses a literal. Does not look the name up.
    static func numeric(_ ip: String) -> ResolvedPeer? {
        var v4 = in_addr()
        if ip.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = v4
            address.sin_port = 0
            var storage = sockaddr_storage()
            withUnsafeBytes(of: address) { source in
                withUnsafeMutableBytes(of: &storage) { destination in
                    destination.copyMemory(from: source)
                }
            }
            return ResolvedPeer(
                ip: ip,
                family: .v4,
                storage: storage,
                length: socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
        var v6 = in6_addr()
        if ip.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = v6
            address.sin6_port = 0
            var storage = sockaddr_storage()
            withUnsafeBytes(of: address) { source in
                withUnsafeMutableBytes(of: &storage) { destination in
                    destination.copyMemory(from: source)
                }
            }
            return ResolvedPeer(
                ip: ip,
                family: .v6,
                storage: storage,
                length: socklen_t(MemoryLayout<sockaddr_in6>.size)
            )
        }
        return nil
    }

    private static func peer(from info: addrinfo) -> ResolvedPeer? {
        guard let address = info.ai_addr else { return nil }
        let family = info.ai_family
        guard family == AF_INET || family == AF_INET6 else { return nil }
        let length = Int(info.ai_addrlen)
        guard length > 0, length <= MemoryLayout<sockaddr_storage>.size else { return nil }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.baseAddress?.copyMemory(from: address, byteCount: length)
        }
        let ipFamily: IPFamily = family == AF_INET6 ? .v6 : .v4
        let ip = ipString(storage, family: family)
        guard !ip.isEmpty else { return nil }
        return ResolvedPeer(ip: ip, family: ipFamily, storage: storage, length: socklen_t(length))
    }
}

enum BSDSockets {
    static func openICMPReceive(_ family: IPFamily) -> Int32 {
        let fd: Int32
        switch family {
        case .v4:
            fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        case .v6:
            fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        }
        guard fd >= 0 else { return -1 }
        if !configure(fd) {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    static func openUDP(_ family: IPFamily) -> Int32 {
        let domain: Int32 = family == .v6 ? AF_INET6 : AF_INET
        let fd = socket(domain, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return -1 }
        if !configure(fd) {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    static func configure(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | Int32(O_NONBLOCK))
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return true
    }

    static func close(_ fd: inout Int32) {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    static func setTTL(_ ttl: Int32, fd: Int32, family: IPFamily) -> Bool {
        var value = ttl
        let result: Int32
        if family == .v6 {
            result = setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &value, socklen_t(MemoryLayout<Int32>.size))
        } else {
            result = setsockopt(fd, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
        }
        return result == 0
    }

    static func send(_ packet: [UInt8], fd: Int32, peer: ResolvedPeer) -> Bool {
        var storage = peer.storage
        let sent = packet.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, base, buffer.count, 0, address, peer.length)
                }
            }
        }
        return sent == packet.count
    }

    /// Receives one datagram. The peer is the sender. Nil peer means the call failed or would block.
    static func receive(fd: Int32, limit: Int = 1500) -> (bytes: [UInt8], peer: ResolvedPeer)? {
        var buffer = [UInt8](repeating: 0, count: limit)
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(fd, base, raw.count, 0, address, &length)
                }
            }
        }
        guard count > 0 else { return nil }
        buffer.removeLast(buffer.count - count)
        let family = Int32(storage.ss_family)
        let ipFamily: IPFamily = family == AF_INET6 ? .v6 : .v4
        let ip = ipString(storage, family: family == AF_INET6 ? AF_INET6 : AF_INET)
        let peer = ResolvedPeer(ip: ip, family: ipFamily, storage: storage, length: length)
        return (buffer, peer)
    }

    static func pollIn(fd: Int32, timeout: TimeInterval, cancelled: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cancelled() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            let slice = min(remaining, 0.05)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, nfds_t(1), Int32(slice * 1_000))
            if result > 0 {
                return (descriptor.revents & Int16(POLLIN)) != 0
            }
            if result < 0, errno != EINTR {
                return false
            }
        }
        return false
    }

}

/// Copies the address into a String before the scratch buffer goes out of scope.
func ipString(_ storage: sockaddr_storage, family: Int32) -> String {
    var copy = storage
    let capacity = Int(INET6_ADDRSTRLEN)
    var buffer = [CChar](repeating: 0, count: capacity)
    let ok: Bool = withUnsafeMutablePointer(to: &copy) { raw -> Bool in
        if family == AF_INET {
            return raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> Bool in
                var addr = sin.pointee.sin_addr
                return inet_ntop(AF_INET, &addr, &buffer, socklen_t(capacity)) != nil
            }
        }
        return raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin -> Bool in
            var addr = sin.pointee.sin6_addr
            return inet_ntop(AF_INET6, &addr, &buffer, socklen_t(capacity)) != nil
        }
    }
    guard ok, let end = buffer.firstIndex(of: 0) else { return "" }
    return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
