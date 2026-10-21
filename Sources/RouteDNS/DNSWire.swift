import Foundation

struct DNSQuestion: Equatable {
    let id: UInt16
    let flags: UInt16
    let name: String
    let labels: [Data]
    let type: UInt16
    let dnsClass: UInt16
    let hasEDNS: Bool
    let udpPayloadSize: Int
    let dnssecRequested: Bool
    let synthesisAllowed: Bool

    var canonicalLabels: [Data] {
        labels.map { Data($0.map { (65...90).contains($0) ? $0 + 32 : $0 }) }
    }

    var questionBytes: Data {
        var bytes = Data()
        for label in labels { bytes.append(UInt8(label.count)); bytes.append(label) }
        bytes.append(0); bytes.appendUInt16(type); bytes.appendUInt16(dnsClass)
        return bytes
    }
    func query(type: UInt16) -> Data {
        var result = Data(); result.appendUInt16(id); result.appendUInt16(0x0100)
        result.appendUInt16(1); result.appendUInt16(0); result.appendUInt16(0); result.appendUInt16(0)
        for label in labels { result.append(UInt8(label.count)); result.append(label) }
        result.append(0); result.appendUInt16(type); result.appendUInt16(1)
        return result
    }
}

struct DNSAAnswer: Equatable {
    let addresses: [UInt32]
    let ttl: UInt32
}

enum DNSWire {
    static let maximumQuerySize = 65_535
    static let maximumResponseSize = 65_535

    static func isQueryMessage(_ data: Data) -> Bool {
        guard data.count >= 12, data.count <= maximumQuerySize else { return false }
        return data[data.startIndex + 2] & 0x80 == 0
    }

    static func question(_ data: Data, response: Bool = false) -> DNSQuestion? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.count <= (response ? maximumResponseSize : maximumQuerySize),
              let id = read16(bytes, 0), let flags = read16(bytes, 2),
              (flags & 0x8000 != 0) == response,
              read16(bytes, 4) == 1 else { return nil }
        var offset = 12
        guard let labels = readName(bytes, offset: &offset),
              let type = read16(bytes, offset), let dnsClass = read16(bytes, offset + 2) else { return nil }
        offset += 4
        let name = labels.map { String(decoding: $0, as: UTF8.self).lowercased() }.joined(separator: ".")
        var hasOPT = false
        var payloadSize = 512
        var dnssecRequested = false
        var synthesisAllowed = dnsClass == 1 && flags & ~UInt16(0x0120) == 0 && flags & 0x0100 != 0 &&
            labels.count >= 2 && labels.allSatisfy { label in
                label.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }
        if !response {
            let answers = Int(read16(bytes, 6) ?? 0), authority = Int(read16(bytes, 8) ?? 0)
            let additional = Int(read16(bytes, 10) ?? 0)
            synthesisAllowed = synthesisAllowed && answers == 0 && authority == 0 && additional <= 1
            for _ in 0..<(answers + authority) {
                guard skipRecord(bytes, offset: &offset) != nil else { return nil }
            }
            for _ in 0..<additional {
                guard let owner = readName(bytes, offset: &offset),
                      let recordType = read16(bytes, offset), let size = read16(bytes, offset + 2),
                      let ttl = read32(bytes, offset + 4), let length = read16(bytes, offset + 8),
                      offset + 10 + Int(length) <= bytes.count else { return nil }
                let end = offset + 10 + Int(length)
                if recordType == 41 {
                    guard owner.isEmpty, !hasOPT else { return nil }
                    hasOPT = true
                    var optionOffset = offset + 10
                    while optionOffset < end {
                    guard let optionLength = read16(bytes, optionOffset + 2),
                              optionOffset + 4 + Int(optionLength) <= end else { return nil }
                        optionOffset += 4 + Int(optionLength)
                    }
                    dnssecRequested = ttl & 0x8000 != 0
                    payloadSize = min(max(Int(size), 512), 65_507)
                    // Unknown EDNS versions, flags and options (cookies, ECS,
                    // padding, etc.) retain their exact original wire semantics.
                    synthesisAllowed = synthesisAllowed && ttl == 0 && length == 0
                } else {
                    synthesisAllowed = false // TSIG and all other additional records.
                }
                offset = end
            }
            guard offset == bytes.count else { return nil }
        }
        return DNSQuestion(id: id, flags: flags, name: name, labels: labels, type: type,
                           dnsClass: dnsClass, hasEDNS: hasOPT, udpPayloadSize: payloadSize, dnssecRequested: dnssecRequested,
                           synthesisAllowed: synthesisAllowed)
    }

    static func matchesResponse(_ response: Data, query: DNSQuestion) -> Bool {
        guard let answer = question(response, response: true) else { return false }
        return answer.id == query.id && answer.canonicalLabels == query.canonicalLabels && answer.type == query.type &&
            answer.dnsClass == query.dnsClass && answer.flags & 0x7800 == query.flags & 0x7800
    }

    /// Connected UDP/TCP sockets already identify the upstream. Correlate the
    /// full question when available, while preserving header-only DNS errors.
    static func matchesResponse(_ response: Data, request: Data) -> Bool {
        let bytes = [UInt8](response), sent = [UInt8](request)
        guard bytes.count >= 12, bytes.count <= maximumResponseSize, sent.count >= 12,
              read16(bytes, 0) == read16(sent, 0), let flags = read16(bytes, 2), flags & 0x8000 != 0,
              flags & 0x7800 == (read16(sent, 2) ?? 0) & 0x7800 else { return false }
        if read16(bytes, 4) == 0, flags & 0x020f != 0 { return true }
        if let query = question(request) { return matchesResponse(response, query: query) }
        // An opaque query (e.g. multiple questions) is passed through unchanged.
        return read16(bytes, 4) == read16(sent, 4)
    }

    static func failure(to data: Data, rcode: UInt16 = 2, truncated: Bool = false) -> Data {
        if let query = question(data) { return response(to: query, rcode: rcode, truncated: truncated) }
        let bytes = [UInt8](data)
        var result = Data()
        result.appendUInt16(read16(bytes, 0) ?? 0)
        result.appendUInt16(0x8080 | ((read16(bytes, 2) ?? 0) & 0x7910) | (rcode & 0xf) | (truncated ? 0x0200 : 0))
        for _ in 0..<4 { result.appendUInt16(0) }
        return result
    }

    static func aAnswer(_ data: Data, for query: DNSQuestion) -> DNSAAnswer? {
        guard let question = question(data, response: true), question.id == query.id,
              question.canonicalLabels == query.canonicalLabels, question.type == 1, question.dnsClass == 1,
              question.flags & 0x7800 == 0 else { return nil }
        let bytes = [UInt8](data)
        guard let flags = read16(bytes, 2), flags & 0x020f == 0,
              let count = read16(bytes, 6), count > 0, count <= 256 else { return nil }
        var offset = 12
        guard readName(bytes, offset: &offset) != nil else { return nil }; offset += 4
        var aliases: [String: (String, UInt32)] = [:]
        var addresses: [String: [(UInt32, UInt32)]] = [:]
        for _ in 0..<Int(count) {
            guard let labels = readName(bytes, offset: &offset), let type = read16(bytes, offset),
                  let recordClass = read16(bytes, offset + 2), let ttl = read32(bytes, offset + 4),
                  let length = read16(bytes, offset + 8), offset + 10 + Int(length) <= bytes.count else { return nil }
            let owner = labels.map { String(decoding: $0, as: UTF8.self).lowercased() }.joined(separator: ".")
            offset += 10
            let end = offset + Int(length)
            if recordClass == 1 && type == 1 {
                guard length == 4, let address = read32(bytes, offset) else { return nil }
                addresses[owner, default: []].append((address, ttl))
            } else if recordClass == 1 && type == 5 {
                var cursor = offset
                guard let target = readName(bytes, offset: &cursor), cursor == end else { return nil }
                let name = target.map { String(decoding: $0, as: UTF8.self).lowercased() }.joined(separator: ".")
                guard !name.isEmpty, aliases[owner] == nil else { return nil }
                aliases[owner] = (name, ttl)
            }
            offset = end
        }
        let remaining = Int(read16(bytes, 8) ?? 0) + Int(read16(bytes, 10) ?? 0)
        for _ in 0..<remaining {
            guard let record = skipRecord(bytes, offset: &offset),
                  record.type != 41 || record.ttl >> 24 == 0 else { return nil }
        }
        guard offset == bytes.count else { return nil }
        var owner = query.name, seen = Set<String>(), ttl: UInt32 = 60
        for _ in 0..<16 {
            guard seen.insert(owner).inserted else { return nil }
            if let values = addresses[owner], !values.isEmpty {
                guard aliases[owner] == nil, values.count <= 64, addresses.count == 1 else { return nil }
                ttl = min(ttl, values.map(\.1).min() ?? 0)
                return DNSAAnswer(addresses: Array(Set(values.map(\.0))).sorted(), ttl: ttl)
            }
            guard let alias = aliases[owner] else { return nil }
            ttl = min(ttl, alias.1); owner = alias.0
        }
        return nil
    }

    static func response(to query: DNSQuestion, addresses: [UInt32] = [], ttl: UInt32 = 0,
                         rcode: UInt16 = 0, truncated: Bool = false) -> Data {
        var bytes = Data()
        bytes.appendUInt16(query.id)
        // RD and CD retain their client meanings. AD is deliberately clear:
        // flattened local answers do not claim DNSSEC validation.
        bytes.appendUInt16(0x8080 | (query.flags & 0x7910) | (rcode & 0xf) | (truncated ? 0x0200 : 0))
        bytes.appendUInt16(1); bytes.appendUInt16(UInt16(addresses.count)); bytes.appendUInt16(0); bytes.appendUInt16(query.hasEDNS ? 1 : 0)
        bytes.append(query.questionBytes)
        for address in addresses {
            bytes.appendUInt16(0xc00c); bytes.appendUInt16(1); bytes.appendUInt16(1)
            bytes.appendUInt32(min(ttl, 60)); bytes.appendUInt16(4); bytes.appendUInt32(address)
        }
        if query.hasEDNS {
            // Local answers and errors acknowledge EDNS without copying request
            // options or claiming validation. DO is echoed independently of AD.
            bytes.append(0); bytes.appendUInt16(41)
            bytes.appendUInt16(UInt16(query.udpPayloadSize))
            bytes.appendUInt32(query.dnssecRequested ? 0x8000 : 0)
            bytes.appendUInt16(0)
        }
        return bytes
    }

    static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func skipRecord(_ bytes: [UInt8], offset: inout Int) -> (type: UInt16, ttl: UInt32)? {
        guard readName(bytes, offset: &offset) != nil, let type = read16(bytes, offset),
              let ttl = read32(bytes, offset + 4), let length = read16(bytes, offset + 8),
              offset + 10 + Int(length) <= bytes.count else { return nil }
        offset += 10 + Int(length)
        return (type, ttl)
    }

    /// Follows compression with a bounded visited set. `offset` advances over
    /// only the encoded name, so callers can validate RDATA boundaries.
    static func readName(_ bytes: [UInt8], offset: inout Int) -> [Data]? {
        var cursor = offset, resumed = false, seen = Set<Int>(), labels: [Data] = [], expanded = 1
        for _ in 0..<128 {
            guard cursor < bytes.count, seen.insert(cursor).inserted else { return nil }
            let length = Int(bytes[cursor])
            if length == 0 { if !resumed { offset = cursor + 1 }; return labels }
            if length & 0xc0 == 0xc0 {
                guard cursor + 1 < bytes.count else { return nil }
                let target = (length & 0x3f) << 8 | Int(bytes[cursor + 1])
                guard target >= 12, target < bytes.count else { return nil }
                if !resumed { offset = cursor + 2; resumed = true }
                cursor = target; continue
            }
            guard length <= 63, length & 0xc0 == 0, cursor + 1 + length <= bytes.count else { return nil }
            let label = bytes[(cursor + 1)..<(cursor + 1 + length)]
            // Names are binary on the wire. Preserve unusual names for the
            // original resolver; only ASCII hostnames qualify for synthesis.
            expanded += length + 1; guard expanded <= 255 else { return nil }
            labels.append(Data(label)); cursor += length + 1
        }
        return nil
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) { append(UInt8(value >> 8)); append(UInt8(value & 0xff)) }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24)); append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8(value & 0xff))
    }
}
