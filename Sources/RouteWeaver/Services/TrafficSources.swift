import Foundation
import Darwin
import RouteCore
import CRouteSocket

struct OwnedTrafficRoutes: Equatable, Sendable {
    var targets: [RouteTrafficTarget]
    static func read(gateway: String, interface: String, expectedCount: Int) -> Self? {
        guard expectedCount > 0, expectedCount <= 20_000 else { return nil }
        var pointer: UnsafeMutablePointer<RWRoute>?
        var count = 0
        guard rw_snapshot(&pointer, &count) == 0, let pointer else { return nil }
        defer { rw_free_routes(pointer) }
        let ownership = UInt32(RTF_PROTO1 | RTF_PROTO2)
        var networks: [IPv4CIDR] = []
        var keys = Set<String>()
        var targets: [RouteTrafficTarget] = []
        let interfaceIndex = if_nametoindex(interface)
        guard interfaceIndex > 0 else { return nil }
        for route in UnsafeBufferPointer(start: pointer, count: count) where route.flags & ownership == ownership {
            // Cloned host routes inherit flags and belong to the parent counter.
            if route.flags & UInt32(RTF_WASCLONED) != 0 { continue }
            guard route.flags & UInt32(RTF_STATIC | RTF_GATEWAY | RTF_UP) == UInt32(RTF_STATIC | RTF_GATEWAY | RTF_UP),
                  route.flags & UInt32(RTF_REJECT | RTF_BLACKHOLE) == 0,
                  route.gateway_is_ipv4 != 0,
                  IPv4CIDR.formatAddress(route.gateway) == gateway else { return nil }
            var name = route.interface_name
            let actualInterface = withUnsafePointer(to: &name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            guard actualInterface == interface else { return nil }
            let prefix = route.mask.nonzeroBitCount
            let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
            guard route.mask == mask, let cidr = try? IPv4CIDR("\(IPv4CIDR.formatAddress(route.network))/\(prefix)"), cidr.isPublic, cidr.network == route.network else { return nil }
            let key = "\(cidr) -> \(interface):\(interfaceIndex) -> \(gateway)"
            guard keys.insert(key).inserted else { return nil }
            targets.append(.init(key: key, network: route.network, mask: route.mask, gateway: route.gateway, interfaceIndex: interfaceIndex))
            networks.append(cidr)
        }
        guard keys.count == expectedCount else { return nil }
        networks.sort()
        for index in 1..<max(1, networks.count) where networks[index - 1].overlaps(networks[index]) { return nil }
        return .init(targets: targets.sorted { $0.network < $1.network })
    }
}

struct TailscaleTrafficIdentity: Sendable {
    var addresses: Set<String>
    static func read() async -> Self? {
        struct Status: Decodable {
            struct Peer: Decodable { var TailscaleIPs: [String]? }
            var BackendState: String?
            var `Self`: Peer?
        }
        guard let cli = NetworkInspector.cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let result = try? await CommandRunner.run(cli, ["status", "--json"], timeout: 3), result.status == 0,
              let status = try? JSONDecoder().decode(Status.self, from: Data(result.output.utf8)),
              status.BackendState == "Running", let addresses = status.Self?.TailscaleIPs, !addresses.isEmpty else { return nil }
        return .init(addresses: Set(addresses))
    }

    /// Match Tailscale's own IPs to a single live utun; never assume utun0.
    func interface() -> (String, UInt32)? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var found = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let item = current.pointee
            guard let address = item.ifa_addr, item.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                  addresses.contains(String(cString: host)) else { continue }
            let name = String(cString: item.ifa_name)
            if name.hasPrefix("utun") { found.insert(name) }
        }
        guard found.count == 1, let name = found.first else { return nil }
        let index = if_nametoindex(name)
        return index == 0 ? nil : (name, index)
    }
}

enum InterfaceTrafficCounters {
    static func read(index: UInt32) -> TrafficByteCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 8 * 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0, size <= data.count else { return nil }
        return data.withUnsafeBytes { bytes -> TrafficByteCounters? in
            var offset = 0
            while offset + 4 <= size {
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { return nil }
                let type = bytes.load(fromByteOffset: offset + 3, as: UInt8.self)
                if type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(message.ifm_index) == index {
                        return .init(received: message.ifm_data.ifi_ibytes, sent: message.ifm_data.ifi_obytes)
                    }
                }
                offset += length
            }
            return nil
        }
    }
}
