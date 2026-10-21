import Foundation
import Darwin
import CRouteSocket
import RouteCore

let routeOwnershipFlags = UInt32(RTF_PROTO1 | RTF_PROTO2)

protocol RouteTableOperating {
    func readSnapshot() throws -> [ExistingRoute]
    func add(_ record: RouteRecord) throws -> Int32
    func remove(_ record: RouteRecord) throws -> Int32
}

struct ExistingRoute {
    let network: UInt32
    let mask: UInt32
    let gateway: UInt32?
    let interface: String
    let index: UInt16
    let flags: UInt32
    func matches(_ cidr: IPv4CIDR) -> Bool { network == cidr.network && mask == cidrMask(cidr) }
    func belongs(to record: RouteRecord) -> Bool {
        guard let cidr = try? IPv4CIDR(record.cidr), let gw = IPv4CIDR.parseAddress(record.gateway) else { return false }
        return (record.markerVersion == 0 || flags & routeOwnershipFlags == routeOwnershipFlags) && matches(cidr) && gateway == gw && interface == record.interface && flags & UInt32(RTF_UP | RTF_STATIC | RTF_GATEWAY) == UInt32(RTF_UP | RTF_STATIC | RTF_GATEWAY) && flags & UInt32(RTF_REJECT | RTF_BLACKHOLE | RTF_IFSCOPE) == 0
    }
}
func cidrMask(_ cidr: IPv4CIDR) -> UInt32 { cidr.prefix == 0 ? 0 : UInt32.max << (32 - cidr.prefix) }
final class RouteTable: RouteTableOperating {
    func readSnapshot() throws -> [ExistingRoute] { try Self.snapshot() }
    private var socket: Int32 = -1
    init() throws { socket = rw_open(); try require(socket >= 0, "无法打开系统路由套接字：\(String(cString: strerror(errno)))") }
    deinit { rw_close(socket) }
    static func snapshot() throws -> [ExistingRoute] {
        var pointer: UnsafeMutablePointer<RWRoute>?
        var count = 0
        let error = rw_snapshot(&pointer, &count)
        try require(error == 0, "无法读取路由表：\(String(cString: strerror(error)))")
        guard let pointer else { return [] }
        defer { rw_free_routes(pointer) }
        return UnsafeBufferPointer(start: pointer, count: count).map { raw in
            var raw = raw
            let name = withUnsafePointer(to: &raw.interface_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            return ExistingRoute(network: raw.network, mask: raw.mask, gateway: raw.gateway_is_ipv4 == 1 ? raw.gateway : nil, interface: name, index: raw.interface_index, flags: raw.flags)
        }
    }
    func add(_ record: RouteRecord) throws -> Int32 { try mutate(record, adding: true) }
    func remove(_ record: RouteRecord) throws -> Int32 { try mutate(record, adding: false) }
    private func mutate(_ record: RouteRecord, adding: Bool) throws -> Int32 {
        let cidr = try IPv4CIDR(record.cidr)
        try cidr.validateForBypass()
        guard let gateway = IPv4CIDR.parseAddress(record.gateway) else { throw HelperError("无效的恢复网关") }
        let index = if_nametoindex(record.interface)
        try require(index > 0 && index <= UInt16.max, "物理接口已失效")
        return adding ? rw_add(socket, cidr.network, cidrMask(cidr), gateway, UInt16(index)) : rw_delete(socket, cidr.network, cidrMask(cidr), gateway, UInt16(index))
    }
}
