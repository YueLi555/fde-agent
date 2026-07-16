import Foundation

enum AgentRoleID: String, Codable, CaseIterable, Identifiable, Sendable {
    case fdeLeadAgent = "FDELeadAgent"
    case codeInvestigationAgent = "CodeInvestigationAgent"
    case securityAgent = "SecurityAgent"
    case infrastructureAgent = "InfrastructureAgent"
    case dataAgent = "DataAgent"
    case documentationAgent = "DocumentationAgent"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fdeLeadAgent: return "FDE Lead"
        case .codeInvestigationAgent: return "Code Investigation"
        case .securityAgent: return "Security"
        case .infrastructureAgent: return "Infrastructure"
        case .dataAgent: return "Data"
        case .documentationAgent: return "Documentation"
        }
    }
}

enum AgentRoleTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case worldModel = "world_model"
    case evidencePipeline = "evidence_pipeline"
    case memory = "memory"
    case outcomeTracking = "outcome_tracking"
    case codebaseIntelligence = "codebase_intelligence"
    case engineeringConnector = "engineering_connector"
    case policyEngine = "policy_engine"
    case permissionGraph = "permission_graph"
    case infrastructureInspector = "infrastructure_inspector"
    case dataProfiler = "data_profiler"
    case documentationWriter = "documentation_writer"

    var id: String { rawValue }
}

enum AgentRolePermission: String, Codable, CaseIterable, Identifiable, Sendable {
    case readSharedContext = "read_shared_context"
    case inspectEvidence = "inspect_evidence"
    case inspectCode = "inspect_code"
    case proposeCodeChange = "propose_code_change"
    case editCode = "edit_code"
    case runValidation = "run_validation"
    case reviewSecurity = "review_security"
    case inspectPermissions = "inspect_permissions"
    case inspectInfrastructure = "inspect_infrastructure"
    case inspectData = "inspect_data"
    case writeDocumentation = "write_documentation"
    case approveDelegation = "approve_delegation"
    case overrideAgentDecision = "override_agent_decision"
    case aggregateFinalReport = "aggregate_final_report"

    var id: String { rawValue }
}

struct AgentOutputSchema: Codable, Hashable, Sendable {
    var requiredFields: [String]
    var optionalFields: [String]
    var requiresEvidence: Bool
    var format: String

    static func roleReport(
        requiredFields: [String] = ["findings", "evidence", "recommendation", "confidence"],
        optionalFields: [String] = ["risks", "open_questions", "validation_plan"]
    ) -> AgentOutputSchema {
        AgentOutputSchema(
            requiredFields: requiredFields,
            optionalFields: optionalFields,
            requiresEvidence: true,
            format: "structured_role_report"
        )
    }
}

struct AgentRole: Identifiable, Codable, Hashable, Sendable {
    var id: AgentRoleID
    var responsibility: String
    var tools: [AgentRoleTool]
    var permissions: [AgentRolePermission]
    var outputSchema: AgentOutputSchema

    var displayName: String { id.displayName }

    func hasPermission(_ permission: AgentRolePermission) -> Bool {
        permissions.contains(permission)
    }
}

struct AgentRoleCatalog: Sendable {
    let roles: [AgentRoleID: AgentRole]

    init(roles: [AgentRole] = AgentRoleCatalog.defaultRoles) {
        self.roles = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, $0) })
    }

    func role(_ id: AgentRoleID) -> AgentRole {
        roles[id] ?? Self.fallbackRole(id)
    }

    func hasPermission(_ permission: AgentRolePermission, for roleID: AgentRoleID) -> Bool {
        role(roleID).hasPermission(permission)
    }

    static let defaultRoles: [AgentRole] = [
        AgentRole(
            id: .fdeLeadAgent,
            responsibility: "Own mission decomposition, delegation approval, conflict resolution, customer-facing synthesis, and final outcome accountability.",
            tools: [.worldModel, .evidencePipeline, .memory, .outcomeTracking, .policyEngine],
            permissions: [
                .readSharedContext,
                .inspectEvidence,
                .approveDelegation,
                .overrideAgentDecision,
                .aggregateFinalReport
            ],
            outputSchema: AgentOutputSchema.roleReport(
                requiredFields: ["delegation_plan", "decision_log", "conflicts", "final_recommendation", "evidence"]
            )
        ),
        AgentRole(
            id: .codeInvestigationAgent,
            responsibility: "Inspect repositories, identify code-level failure modes, propose bounded changes, and define validation steps.",
            tools: [.codebaseIntelligence, .engineeringConnector, .evidencePipeline, .memory],
            permissions: [.readSharedContext, .inspectEvidence, .inspectCode, .proposeCodeChange, .runValidation],
            outputSchema: AgentOutputSchema.roleReport(
                requiredFields: ["files_inspected", "symbols", "suspected_failure", "proposed_change", "validation_plan", "evidence"]
            )
        ),
        AgentRole(
            id: .securityAgent,
            responsibility: "Review permission, credential, policy, data exposure, and approval risks before execution.",
            tools: [.policyEngine, .permissionGraph, .evidencePipeline, .memory],
            permissions: [.readSharedContext, .inspectEvidence, .reviewSecurity, .inspectPermissions],
            outputSchema: AgentOutputSchema.roleReport(
                requiredFields: ["risk_assessment", "policy_findings", "approval_requirements", "recommendation", "evidence"]
            )
        ),
        AgentRole(
            id: .infrastructureAgent,
            responsibility: "Inspect deployment, cloud, CI/CD, runtime, and production environment dependencies.",
            tools: [.worldModel, .infrastructureInspector, .evidencePipeline, .memory],
            permissions: [.readSharedContext, .inspectEvidence, .inspectInfrastructure, .runValidation],
            outputSchema: AgentOutputSchema.roleReport(
                requiredFields: ["environment_findings", "deployment_risk", "recovery_plan", "evidence"]
            )
        ),
        AgentRole(
            id: .dataAgent,
            responsibility: "Assess database, schema, analytics, data quality, and sensitivity implications.",
            tools: [.worldModel, .dataProfiler, .policyEngine, .evidencePipeline],
            permissions: [.readSharedContext, .inspectEvidence, .inspectData, .reviewSecurity],
            outputSchema: AgentOutputSchema.roleReport(
                requiredFields: ["data_scope", "sensitivity", "migration_or_query_risk", "recommendation", "evidence"]
            )
        ),
        AgentRole(
            id: .documentationAgent,
            responsibility: "Produce customer-safe summaries, runbooks, decision records, and implementation notes from verified evidence.",
            tools: [.documentationWriter, .evidencePipeline, .outcomeTracking, .memory],
            permissions: [.readSharedContext, .inspectEvidence, .writeDocumentation],
            outputSchema: AgentOutputSchema.roleReport(
                requiredFields: ["summary", "customer_update", "runbook_delta", "evidence"]
            )
        )
    ]

    private static func fallbackRole(_ id: AgentRoleID) -> AgentRole {
        AgentRole(
            id: id,
            responsibility: "Participate in the shared mission using available verified context.",
            tools: [.worldModel, .evidencePipeline],
            permissions: [.readSharedContext, .inspectEvidence],
            outputSchema: .roleReport()
        )
    }
}
