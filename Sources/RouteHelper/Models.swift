import Foundation
import RouteCore

struct ApplyRequest: Codable {
    let routes: [String]
    let gateway: String
    let interface: String
    let exitNodeID: String
}
struct RouteRecord: Codable, Equatable {
    let cidr: String
    let gateway: String
    let interface: String
    var confirmed: Bool
    var markerVersion: Int = 1
    init(cidr: String, gateway: String, interface: String, confirmed: Bool, markerVersion: Int = 1) {
        self.cidr = cidr; self.gateway = gateway; self.interface = interface
        self.confirmed = confirmed; self.markerVersion = markerVersion
    }
    enum CodingKeys: String, CodingKey { case cidr, gateway, interface, confirmed, markerVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cidr = try c.decode(String.self, forKey: .cidr)
        gateway = try c.decode(String.self, forKey: .gateway)
        interface = try c.decode(String.self, forKey: .interface)
        confirmed = try c.decode(Bool.self, forKey: .confirmed)
        markerVersion = try c.decodeIfPresent(Int.self, forKey: .markerVersion) ?? 0
    }
}
struct Journal: Codable {
    var version = 2
    var records: [RouteRecord] = []
}
struct OperationDetail: Codable {
    let cidr: String
    let action: String
    let result: String
}
struct Report: Codable {
    var active = 0
    var pending = 0
    var added = 0
    var removed = 0
    var skipped = 0
    var failed = 0
    var durationMilliseconds = 0
    var verified = false
    var message = ""
    var details: [OperationDetail] = []
    var detailsOmitted = 0
}
struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HelperError(message) }
}
