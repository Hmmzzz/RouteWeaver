import Foundation

/// UInt64 endpoints avoid overflow at 255.255.255.255 and simplify subtraction.
internal struct AddressRange {
    var lower: UInt64
    var upper: UInt64

    init(_ cidr: IPv4CIDR) {
        lower = UInt64(cidr.network)
        upper = UInt64(cidr.lastAddress)
    }

    init(lower: UInt64, upper: UInt64) {
        self.lower = lower
        self.upper = upper
    }

    static func union(_ ranges: [AddressRange]) -> [AddressRange] {
        let sorted = ranges.sorted {
            $0.lower == $1.lower ? $0.upper < $1.upper : $0.lower < $1.lower
        }
        var result: [AddressRange] = []
        result.reserveCapacity(sorted.count)
        for range in sorted {
            if let last = result.last, range.lower <= last.upper + 1 {
                result[result.count - 1].upper = max(last.upper, range.upper)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Both lists must be sorted and disjoint. Complexity: O(n + m + output).
    static func subtract(_ exclusions: [AddressRange], from ranges: [AddressRange]) -> [AddressRange] {
        var result: [AddressRange] = []
        var exclusionIndex = 0
        for range in ranges {
            var start = range.lower
            while exclusionIndex < exclusions.count && exclusions[exclusionIndex].upper < start {
                exclusionIndex += 1
            }
            var index = exclusionIndex
            while index < exclusions.count && exclusions[index].lower <= range.upper {
                let excluded = exclusions[index]
                if excluded.lower > start {
                    result.append(AddressRange(lower: start, upper: excluded.lower - 1))
                }
                start = max(start, excluded.upper + 1)
                if start > range.upper { break }
                index += 1
            }
            exclusionIndex = index
            if start <= range.upper {
                result.append(AddressRange(lower: start, upper: range.upper))
            }
        }
        return result
    }

    func cidrs() -> [IPv4CIDR] {
        var result: [IPv4CIDR] = []
        var address = lower
        while address <= upper {
            let alignmentBits = address == 0 ? 32 : min(address.trailingZeroBitCount, 32)
            let remaining = upper - address + 1
            let sizeBits = 63 - remaining.leadingZeroBitCount
            let hostBits = min(alignmentBits, sizeBits)
            result.append(IPv4CIDR(network: UInt32(address), prefix: 32 - hostBits))
            address += UInt64(1) << hostBits
        }
        return result
    }
}
