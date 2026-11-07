#if os(macOS)
// Parameters of the run-contract tools (Kronos v1.2, Phase 1 slice A4): run_start, run_update,
// run_finish. Same shape as MCPAgentParams.swift's agent-loop structs — plain `Decodable`, no
// custom init, the schema in MCPToolSchemas.swift is the one place the wire contract is read.

import Foundation

extension MCPParams {

    struct RunStart: Decodable {
        var taskID: UUID
        var leaseSeconds: Int?
    }

    struct RunUpdate: Decodable {
        var runID: UUID
        var progress: Double?
        var note: String?
        var artifactsAdd: [RunArtifact]?
    }

    struct RunFinish: Decodable {
        var runID: UUID
        var outcome: String
        var summary: String
        var artifactsAdd: [RunArtifact]?
        var handoffTo: String?
    }
}
#endif
