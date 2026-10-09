// Part of the frozen contract surface. See Contracts.swift.
//
// `rules_list`, `rules_add` and `review_status` params. Split from
// MCPParams.swift to keep every contract file under 500 lines (MCP-004).

import Foundation

extension MCPParams {

    public struct RulesList: Codable, Equatable, Sendable {
        public var includeInactive: Bool

        public init(includeInactive: Bool = false) { self.includeInactive = includeInactive }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeInactive = try c.decodeIfPresent(Bool.self, forKey: .includeInactive) ?? false
        }
    }

    public struct RulesAdd: Codable, Equatable, Sendable {
        public let text: String
        public var scope: Scope

        public enum Scope: String, Codable, CaseIterable, Sendable {
            case all, triage, impuls, ordo

            public var kRuleScope: KRuleScope {
                switch self {
                case .all:    return .all
                case .triage: return .triage
                case .impuls: return .impuls
                case .ordo:   return .ordo
                }
            }
        }

        public init(text: String, scope: Scope = .all) {
            self.text  = text
            self.scope = scope
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text  = try c.decode(String.self, forKey: .text)
            scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .all
        }
    }

    /// `review_status` (finish-round-1 B3): either `ids` (up to 200) or `project`, never both
    /// and never neither — same shape rule as `OrdoSet.order`/`top`.
    public struct ReviewStatus: Codable, Equatable, Sendable {
        public var ids: [UUID]?
        public var project: UUID?

        public init(ids: [UUID]? = nil, project: UUID? = nil) {
            self.ids = ids
            self.project = project
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ids     = try c.decodeIfPresent([UUID].self, forKey: .ids)
            project = try c.decodeIfPresent(UUID.self, forKey: .project)
        }

        public var validationError: MCPToolError? {
            switch (ids, project) {
            case (nil, nil):     return .invalidParams
            case (.some, .some): return .invalidParams
            case (.some(let i), nil):
                if i.isEmpty || i.count > 200 { return .invalidParams }
                return nil
            case (nil, .some):   return nil
            }
        }
    }
}
