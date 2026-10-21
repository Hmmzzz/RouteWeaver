import Foundation

public enum RuleAction: String, Codable, CaseIterable, Sendable {
    case direct
    case exitNode
}

public struct RouteRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var cidr: String
    public var action: RuleAction
    public var note: String
    public var enabled: Bool

    public init(id: UUID = UUID(), cidr: String, action: RuleAction,
                note: String = "", enabled: Bool = true) {
        self.id = id
        self.cidr = cidr
        self.action = action
        self.note = note
        self.enabled = enabled
    }
}
