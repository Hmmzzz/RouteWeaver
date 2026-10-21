import Foundation

/// Compiles intent into the smallest disjoint set of public IPv4 bypass routes.
/// Exit-node rules are exclusions, so they can never install or replace a default route.
public enum PolicyCompiler {
    public static let maximumRouteCount = 20_000
    public static let maximumInputCount = 100_000

    public static func compile(countryCIDRs: [String], rules: [RouteRule],
                               excludedAddresses: [String]) throws -> [IPv4CIDR] {
        let inputCount = countryCIDRs.count + rules.count + excludedAddresses.count
        guard inputCount <= maximumInputCount else { throw RouteCoreError.tooManyRoutes(inputCount) }

        var direct: [AddressRange] = []
        direct.reserveCapacity(countryCIDRs.count + rules.count)
        var exclusions: [AddressRange] = []

        for input in countryCIDRs {
            let cidr = try IPv4CIDR(input)
            try cidr.validateForBypass()
            direct.append(AddressRange(cidr))
        }

        for rule in rules {
            let cidr = try IPv4CIDR(rule.cidr)
            if rule.action == .direct { try cidr.validateForBypass() }
            guard rule.enabled else { continue }
            switch rule.action {
            case .direct: direct.append(AddressRange(cidr))
            case .exitNode: exclusions.append(AddressRange(cidr))
            }
        }

        for input in excludedAddresses {
            guard let address = IPv4CIDR.parseAddress(input) else {
                throw RouteCoreError.invalidAddress(input)
            }
            exclusions.append(AddressRange(lower: UInt64(address), upper: UInt64(address)))
        }

        let disjoint = AddressRange.subtract(AddressRange.union(exclusions), from: AddressRange.union(direct))
        var result: [IPv4CIDR] = []
        for range in disjoint {
            result.append(contentsOf: range.cidrs())
            guard result.count <= maximumRouteCount else {
                throw RouteCoreError.tooManyRoutes(result.count)
            }
        }
        return result
    }
}
