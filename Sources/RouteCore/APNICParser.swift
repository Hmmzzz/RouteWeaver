import Foundation

/// RIR delegated statistics parser. Data provenance is allocation country, not geolocation.
public enum APNICParser {
    public static func chinaIPv4(from text: String) throws -> [IPv4CIDR] {
        var ranges: [AddressRange] = []
        var rowNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            rowNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[1] == "CN", fields[2] == "ipv4" else { continue }
            guard fields.count >= 7, fields[0] == "apnic",
                  let address = IPv4CIDR.parseAddress(String(fields[3])),
                  !fields[4].isEmpty,
                  fields[4].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let count = UInt64(fields[4]), count > 0,
                  count <= UInt64(UInt32.max) + 1,
                  UInt64(address) + count <= UInt64(UInt32.max) + 1 else {
                throw RouteCoreError.malformedAPNICRow(rowNumber)
            }
            guard fields[6] == "allocated" || fields[6] == "assigned" else { continue }
            let range = AddressRange(lower: UInt64(address), upper: UInt64(address) + count - 1)
            for cidr in range.cidrs() {
                do { try cidr.validateForBypass() }
                catch { throw RouteCoreError.malformedAPNICRow(rowNumber) }
            }
            ranges.append(range)
            guard ranges.count <= PolicyCompiler.maximumInputCount else {
                throw RouteCoreError.tooManyRoutes(ranges.count)
            }
        }
        guard !ranges.isEmpty else { throw RouteCoreError.emptyDataset }
        var result: [IPv4CIDR] = []
        for range in AddressRange.union(ranges) {
            result.append(contentsOf: range.cidrs())
            guard result.count <= PolicyCompiler.maximumRouteCount else {
                throw RouteCoreError.tooManyRoutes(result.count)
            }
        }
        return result
    }
}
