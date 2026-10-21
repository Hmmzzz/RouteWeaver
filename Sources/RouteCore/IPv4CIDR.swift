import Foundation

/// A normalized IPv4 network. Parsing and decoding preserve its invariants.
public struct IPv4CIDR: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let network: UInt32
    public let prefix: Int

    public init(_ text: String) throws {
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              let address = Self.parseAddress(String(components[0])),
              !components[1].isEmpty,
              components[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let prefix = Int(components[1]), (0...32).contains(prefix) else {
            throw RouteCoreError.invalidCIDR(text)
        }
        self.init(network: address, prefix: prefix)
    }

    internal init(network: UInt32, prefix: Int) {
        precondition((0...32).contains(prefix))
        self.prefix = prefix
        self.network = network & Self.mask(for: prefix)
    }

    public var description: String { "\(Self.formatAddress(network))/\(prefix)" }

    public var lastAddress: UInt32 { network | ~Self.mask(for: prefix) }

    public func contains(_ address: String) -> Bool {
        guard let address = Self.parseAddress(address) else { return false }
        return contains(address)
    }

    public func contains(_ address: UInt32) -> Bool {
        address >= network && address <= lastAddress
    }

    public func overlaps(_ other: IPv4CIDR) -> Bool {
        network <= other.lastAddress && other.network <= lastAddress
    }

    /// Conservative bypass policy: never route special-use or private networks.
    /// LAN access remains a Tailscale setting; this tool manages public IPv4 only.
    public var isPublic: Bool { !Self.protectedNetworks.contains(where: overlaps) }

    public func validateForBypass() throws {
        guard prefix >= 2 else { throw RouteCoreError.unsafeCIDR(description) }
        guard isPublic else { throw RouteCoreError.unsafeCIDR(description) }
    }

    public static func < (lhs: IPv4CIDR, rhs: IPv4CIDR) -> Bool {
        lhs.network == rhs.network ? lhs.prefix < rhs.prefix : lhs.network < rhs.network
    }

    /// Strict decimal dotted-quad parsing, including rejection of ambiguous octal notation.
    public static func parseAddress(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var address: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  part.count == 1 || part.first != "0",
                  let value = UInt32(part), value <= 255 else { return nil }
            address = (address << 8) | value
        }
        return address
    }

    public static func formatAddress(_ address: UInt32) -> String {
        "\((address >> 24) & 255).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func mask(for prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    }

    /// IANA special-use ranges, including Tailnet CGNAT space and documentation ranges.
    private static let protectedNetworks: [IPv4CIDR] = [
        (0x00000000, 8),   // 0.0.0.0/8 — this network
        (0x0a000000, 8),   // 10.0.0.0/8 — private
        (0x64400000, 10),  // 100.64.0.0/10 — shared / Tailscale
        (0x7f000000, 8),   // 127.0.0.0/8 — loopback
        (0xa9fe0000, 16),  // 169.254.0.0/16 — link local
        (0xac100000, 12),  // 172.16.0.0/12 — private
        (0xc0000000, 24),  // 192.0.0.0/24 — protocol assignments
        (0xc0000200, 24),  // 192.0.2.0/24 — documentation
        (0xc0586300, 24),  // 192.88.99.0/24 — deprecated relay
        (0xc0a80000, 16),  // 192.168.0.0/16 — private
        (0xc6120000, 15),  // 198.18.0.0/15 — benchmarking
        (0xc6336400, 24),  // 198.51.100.0/24 — documentation
        (0xcb007100, 24),  // 203.0.113.0/24 — documentation
        (0xe0000000, 4),   // 224.0.0.0/4 — multicast
        (0xf0000000, 4)    // 240.0.0.0/4 — reserved / broadcast
    ].map { IPv4CIDR(network: UInt32($0.0), prefix: $0.1) }
}

public enum RouteCoreError: Error, LocalizedError, Equatable {
    case invalidCIDR(String)
    case unsafeCIDR(String)
    case invalidAddress(String)
    case tooManyRoutes(Int)
    case malformedAPNICRow(Int)
    case emptyDataset

    public var errorDescription: String? {
        switch self {
        case .invalidCIDR(let input): return "无效的 IPv4 CIDR：\(input)。请使用如 223.5.5.0/24 的格式。"
        case .unsafeCIDR(let input): return "不能将默认、私有或保留网段设为直连：\(input)。局域网访问请在 Tailscale 中设置。"
        case .invalidAddress(let input): return "无效的 IPv4 地址：\(input)。"
        case .tooManyRoutes(let count): return "规则数量超出安全上限（\(count) 条）。请缩小规则集。"
        case .malformedAPNICRow(let line): return "APNIC 数据第 \(line) 行无效；本次更新已中止。"
        case .emptyDataset: return "数据中没有可用的中国大陆 IPv4 网段；保留现有数据。"
        }
    }
}
