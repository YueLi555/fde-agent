import Foundation

enum AgentDelegationStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case proposed
    case approved
    case inProgress = "in_progress"
    case completed
    case blocked
    case overridden

    var id: String { rawValue }
}

enum AgentSubMissionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case queued
    case active
    case completed
    case blocked
    case overridden

    var id: String { rawValue }
}

enum AgentExpertise: String, Codable, CaseIterable, Identifiable, Sendable {
    case leadership
    case code
    case security
    case infrastructure
    case data
    case documentation

    var id: String { rawValue }

    var roleID: AgentRoleID {
        switch self {
        case .leadership: return .fdeLeadAgent
        case .code: return .codeInvestigationAgent
        case .security: return .securityAgent
        case .infrastructure: return .infrastructureAgent
        case .data: return .dataAgent
        case .documentation: return .documentationAgent
        }
    }
}

enum HumanLeadApprovalState: String, Codable, CaseIterable, Identifiable, Sendable {
    case notRequired = "not_required"
    case pending
    case approved
    case overridden

    var id: String { rawValue }
}

struct SharedMissionContext: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var worldModel: SystemWorldModel?
    var evidence: [EvidenceRecord]
    var agentEvidence: [AgentEvidence]
    var memory: AgentRelevantMemory
    var outcome: OutcomeRecord?
    var events: [ExecutionEvent]

    init(
        workspaceID: UUID,
        worldModel: SystemWorldModel? = nil,
        evidence: [EvidenceRecord] = [],
        agentEvidence: [AgentEvidence] = [],
        memory: AgentRelevantMemory = .empty,
        outcome: OutcomeRecord? = nil,
        events: [ExecutionEvent] = []
    ) {
        self.workspaceID = workspaceID
        self.worldModel = worldModel
        self.evidence = evidence
        self.agentEvidence = agentEvidence
        self.memory = memory
        self.outcome = outcome
        self.events = events
    }

    var evidenceDigest: [String] {
        var values = evidence.map(\.summary)
        values += agentEvidence.map { "\($0.kind.rawValue):\($0.title)" }
        values += worldModel?.evidence ?? []
        values += events.suffix(8).map { "\($0.type.rawValue):\($0.summary)" }
        if let outcome {
            values.append("outcome:\(outcome.finalState.rawValue):\(outcome.achievedOutcome)")
        }
        return Array(values.prefix(24))
    }

    var hasGroundingEvidence: Bool {
        !evidenceDigest.isEmpty
    }
}

struct AgentMissionBrief: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var objective: String
    var system: String
    var environment: String
    var riskLevel: RiskSeverity

    init(
        id: UUID = UUID(),
        workspaceID: UUID,
        objective: String,
        system: String = "workspace",
        environment: String = "local",
        riskLevel: RiskSeverity = .medium
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.objective = objective
        self.system = system
        self.environment = environment
        self.riskLevel = riskLevel
    }
}

struct AgentSubMission: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var missionID: UUID
    var title: String
    var objective: String
    var assignedRole: AgentRoleID
    var requiredExpertise: AgentExpertise
    var expectedOutputSchema: AgentOutputSchema
    var status: AgentSubMissionStatus
    var evidenceRequired: Bool
    var progress: Double

    init(
        id: UUID = UUID(),
        missionID: UUID,
        title: String,
        objective: String,
        assignedRole: AgentRoleID,
        requiredExpertise: AgentExpertise,
        expectedOutputSchema: AgentOutputSchema,
        status: AgentSubMissionStatus = .queued,
        evidenceRequired: Bool = true,
        progress: Double = 0
    ) {
        self.id = id
        self.missionID = missionID
        self.title = title
        self.objective = objective
        self.assignedRole = assignedRole
        self.requiredExpertise = requiredExpertise
        self.expectedOutputSchema = expectedOutputSchema
        self.status = status
        self.evidenceRequired = evidenceRequired
        self.progress = progress
    }
}

struct AgentCollaborationMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sender: AgentRoleID
    var receiver: AgentRoleID
    var task: String
    var evidence: [EvidenceRecord]
    var recommendation: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sender: AgentRoleID,
        receiver: AgentRoleID,
        task: String,
        evidence: [EvidenceRecord],
        recommendation: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sender = sender
        self.receiver = receiver
        self.task = AgentPresentationSanitizer.safeContent(task, fallback: "Agent task")
        self.evidence = evidence
        self.recommendation = AgentPresentationSanitizer.safeContent(recommendation, fallback: "Review required.")
        self.createdAt = createdAt
    }
}

typealias AgentTeamMessage = AgentCollaborationMessage

struct HumanFDELeadMode: Codable, Hashable, Sendable {
    var approvalState: HumanLeadApprovalState
    var canApproveDelegation: Bool
    var canOverrideDecisions: Bool
    var canInspectAgentReports: Bool
    var decisionReason: String?

    static let active = HumanFDELeadMode(
        approvalState: .pending,
        canApproveDelegation: true,
        canOverrideDecisions: true,
        canInspectAgentReports: true,
        decisionReason: nil
    )

    static let notRequired = HumanFDELeadMode(
        approvalState: .notRequired,
        canApproveDelegation: false,
        canOverrideDecisions: true,
        canInspectAgentReports: true,
        decisionReason: nil
    )
}

struct AgentDelegationPlan: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var mission: AgentMissionBrief
    var requiredExpertise: [AgentExpertise]
    var subMissions: [AgentSubMission]
    var messages: [AgentCollaborationMessage]
    var humanLeadMode: HumanFDELeadMode
    var sharedContextDigest: [String]
    var status: AgentDelegationStatus
    var createdAt: Date

    var activeRoles: [AgentRoleID] {
        Array(Set(subMissions.map(\.assignedRole))).sorted { $0.rawValue < $1.rawValue }
    }
}

struct AgentSubMissionResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var subMissionID: UUID
    var role: AgentRoleID
    var status: AgentSubMissionStatus
    var findings: [String]
    var evidence: [EvidenceRecord]
    var recommendation: String
    var confidence: Double
    var completedAt: Date

    init(
        id: UUID = UUID(),
        subMissionID: UUID,
        role: AgentRoleID,
        status: AgentSubMissionStatus = .completed,
        findings: [String],
        evidence: [EvidenceRecord],
        recommendation: String,
        confidence: Double = 0.8,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.subMissionID = subMissionID
        self.role = role
        self.status = status
        self.findings = findings.map { AgentPresentationSanitizer.safeContent($0, fallback: "Finding recorded.") }
        self.evidence = evidence
        self.recommendation = AgentPresentationSanitizer.safeContent(recommendation, fallback: "Review required.")
        self.confidence = min(max(confidence, 0), 1)
        self.completedAt = completedAt
    }
}

struct AgentRecommendationConflict: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var blockingRole: AgentRoleID
    var proceedingRole: AgentRoleID
    var summary: String
}

struct AgentDelegationReport: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var planID: UUID
    var missionID: UUID
    var results: [AgentSubMissionResult]
    var messages: [AgentCollaborationMessage]
    var conflicts: [AgentRecommendationConflict]
    var finalFindings: [String]
    var finalRecommendation: String
    var requiresHumanLeadReview: Bool
    var evidence: [EvidenceRecord]
    var status: AgentDelegationStatus
    var completedAt: Date
}

struct AgentTeamMemberSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: AgentRoleID { roleID }
    var roleID: AgentRoleID
    var responsibility: String
    var progress: Double
    var status: AgentSubMissionStatus
    var findings: [String]
}

struct AgentTeamSnapshot: Codable, Hashable, Sendable {
    var activeAgents: [AgentTeamMemberSnapshot]
    var findings: [String]
    var progress: Double
    var requiresHumanLeadReview: Bool
    var status: AgentDelegationStatus

    static let empty = AgentTeamSnapshot(
        activeAgents: [],
        findings: ["No team delegation active."],
        progress: 0,
        requiresHumanLeadReview: false,
        status: .proposed
    )
}

struct AgentDelegationEngine: Sendable {
    let roleCatalog: AgentRoleCatalog

    init(roleCatalog: AgentRoleCatalog = AgentRoleCatalog()) {
        self.roleCatalog = roleCatalog
    }

    func analyzeRequiredExpertise(mission: AgentMissionBrief, context: SharedMissionContext) -> [AgentExpertise] {
        let text = normalizedMissionText(mission: mission, context: context)
        var expertise: [AgentExpertise] = [.leadership]

        if containsAny(text, ["code", "repo", "repository", "bug", "test", "build", "compile", "integration", "api", "symbol", "file"]) {
            expertise.append(.code)
        }
        if containsAny(text, ["security", "permission", "credential", "token", "secret", "approval", "policy", "risk", "auth", "oauth"]) {
            expertise.append(.security)
        }
        if containsAny(text, ["infra", "infrastructure", "deploy", "production", "prod", "cloud", "kubernetes", "gcloud", "terraform", "incident", "ci"]) {
            expertise.append(.infrastructure)
        }
        if containsAny(text, ["data", "database", "schema", "migration", "query", "pii", "customer record", "analytics", "warehouse"]) {
            expertise.append(.data)
        }
        if containsAny(text, ["doc", "documentation", "runbook", "handoff", "report", "customer update", "summary"]) {
            expertise.append(.documentation)
        }

        if expertise.count == 1 {
            expertise.append(.code)
            expertise.append(.documentation)
        }

        return uniqueExpertise(expertise)
    }

    func createDelegationPlan(
        mission: AgentMissionBrief,
        context: SharedMissionContext,
        requireHumanApproval: Bool = true,
        approvedByHumanLead: Bool = false,
        now: Date = Date()
    ) -> AgentDelegationPlan {
        let expertise = analyzeRequiredExpertise(mission: mission, context: context)
        let subMissions = expertise.map { subMission(for: $0, mission: mission) }
        let messages = subMissions
            .filter { $0.assignedRole != .fdeLeadAgent }
            .map { message(for: $0, context: context, createdAt: now) }
        let leadMode = humanLeadMode(
            requireHumanApproval: requireHumanApproval,
            approvedByHumanLead: approvedByHumanLead,
            reason: approvedByHumanLead ? "Human FDE lead approved delegation." : nil
        )
        return AgentDelegationPlan(
            id: UUID(),
            mission: mission,
            requiredExpertise: expertise,
            subMissions: subMissions,
            messages: messages,
            humanLeadMode: leadMode,
            sharedContextDigest: context.evidenceDigest,
            status: leadMode.approvalState == .pending ? .proposed : .approved,
            createdAt: now
        )
    }

    func approveDelegation(
        _ plan: AgentDelegationPlan,
        reason: String,
        now: Date = Date()
    ) -> AgentDelegationPlan {
        var copy = plan
        copy.humanLeadMode.approvalState = .approved
        copy.humanLeadMode.decisionReason = AgentPresentationSanitizer.safeContent(reason, fallback: "Delegation approved.")
        copy.status = .approved
        copy.messages.append(
            AgentCollaborationMessage(
                sender: .fdeLeadAgent,
                receiver: .fdeLeadAgent,
                task: "Delegation approval",
                evidence: [],
                recommendation: copy.humanLeadMode.decisionReason ?? "Delegation approved.",
                createdAt: now
            )
        )
        return copy
    }

    func overrideDecision(
        _ plan: AgentDelegationPlan,
        subMissionID: UUID,
        reassignedRole: AgentRoleID,
        reason: String
    ) -> AgentDelegationPlan {
        var copy = plan
        guard let index = copy.subMissions.firstIndex(where: { $0.id == subMissionID }) else {
            return copy
        }
        copy.subMissions[index].assignedRole = reassignedRole
        copy.subMissions[index].status = .overridden
        copy.humanLeadMode.approvalState = .overridden
        copy.humanLeadMode.decisionReason = AgentPresentationSanitizer.safeContent(reason, fallback: "Human FDE lead overrode delegation.")
        copy.status = .overridden
        return copy
    }

    func collectResults(
        plan: AgentDelegationPlan,
        context: SharedMissionContext,
        results: [AgentSubMissionResult],
        now: Date = Date()
    ) -> AgentDelegationReport {
        let conflicts = detectConflicts(results)
        let missingEvidenceRoles = results
            .filter { $0.evidence.isEmpty }
            .map { "\($0.role.displayName) returned no evidence." }
        let findings = Array((results.flatMap(\.findings) + missingEvidenceRoles).prefix(12))
        let evidence = Array((results.flatMap(\.evidence) + context.evidence).prefix(24))
        let requiresLeadReview = !conflicts.isEmpty
            || !missingEvidenceRoles.isEmpty
            || plan.humanLeadMode.approvalState == .pending
        let recommendation = finalRecommendation(
            results: results,
            conflicts: conflicts,
            requiresLeadReview: requiresLeadReview
        )
        let messages = plan.messages + results.map { result in
            AgentCollaborationMessage(
                sender: result.role,
                receiver: .fdeLeadAgent,
                task: "Report result for delegated sub-mission",
                evidence: result.evidence,
                recommendation: result.recommendation,
                createdAt: result.completedAt
            )
        }

        return AgentDelegationReport(
            id: UUID(),
            planID: plan.id,
            missionID: plan.mission.id,
            results: results,
            messages: messages,
            conflicts: conflicts,
            finalFindings: findings,
            finalRecommendation: recommendation,
            requiresHumanLeadReview: requiresLeadReview,
            evidence: evidence,
            status: requiresLeadReview ? .blocked : .completed,
            completedAt: now
        )
    }

    func teamSnapshot(plan: AgentDelegationPlan, report: AgentDelegationReport? = nil) -> AgentTeamSnapshot {
        let resultsByRole = Dictionary(grouping: report?.results ?? [], by: \.role)
        let members = plan.subMissions.map { subMission -> AgentTeamMemberSnapshot in
            let role = roleCatalog.role(subMission.assignedRole)
            let roleResults = resultsByRole[subMission.assignedRole] ?? []
            return AgentTeamMemberSnapshot(
                roleID: subMission.assignedRole,
                responsibility: role.responsibility,
                progress: roleResults.isEmpty ? subMission.progress : 1,
                status: roleResults.isEmpty ? subMission.status : .completed,
                findings: Array(roleResults.flatMap(\.findings).prefix(3))
            )
        }
        let progress = members.isEmpty ? 0 : members.map(\.progress).reduce(0, +) / Double(members.count)
        let requiresHumanLeadReview = report?.requiresHumanLeadReview ?? (plan.humanLeadMode.approvalState == .pending)
        return AgentTeamSnapshot(
            activeAgents: members,
            findings: report.map { Array($0.finalFindings.prefix(4)) } ?? Array(plan.sharedContextDigest.prefix(4)),
            progress: progress,
            requiresHumanLeadReview: requiresHumanLeadReview,
            status: report?.status ?? plan.status
        )
    }

    func previewTeamSnapshot(
        mission: AgentMissionBrief,
        context: SharedMissionContext
    ) -> AgentTeamSnapshot {
        let plan = createDelegationPlan(
            mission: mission,
            context: context,
            requireHumanApproval: false,
            approvedByHumanLead: true
        )
        var snapshot = teamSnapshot(plan: plan)
        snapshot.progress = context.hasGroundingEvidence ? 0.25 : 0.1
        return snapshot
    }

    private func humanLeadMode(
        requireHumanApproval: Bool,
        approvedByHumanLead: Bool,
        reason: String?
    ) -> HumanFDELeadMode {
        guard requireHumanApproval else { return .notRequired }
        var mode = HumanFDELeadMode.active
        if approvedByHumanLead {
            mode.approvalState = .approved
        }
        mode.decisionReason = reason
        return mode
    }

    private func subMission(for expertise: AgentExpertise, mission: AgentMissionBrief) -> AgentSubMission {
        let role = roleCatalog.role(expertise.roleID)
        return AgentSubMission(
            missionID: mission.id,
            title: title(for: expertise),
            objective: objective(for: expertise, mission: mission),
            assignedRole: expertise.roleID,
            requiredExpertise: expertise,
            expectedOutputSchema: role.outputSchema,
            status: expertise == .leadership ? .active : .queued,
            evidenceRequired: role.outputSchema.requiresEvidence,
            progress: expertise == .leadership ? 0.2 : 0
        )
    }

    private func message(
        for subMission: AgentSubMission,
        context: SharedMissionContext,
        createdAt: Date
    ) -> AgentCollaborationMessage {
        AgentCollaborationMessage(
            sender: .fdeLeadAgent,
            receiver: subMission.assignedRole,
            task: subMission.objective,
            evidence: Array(context.evidence.prefix(6)),
            recommendation: "Use shared world model, memory, outcome, and evidence only; return structured findings with evidence.",
            createdAt: createdAt
        )
    }

    private func detectConflicts(_ results: [AgentSubMissionResult]) -> [AgentRecommendationConflict] {
        let blockers = results.filter { isBlockingRecommendation($0.recommendation) }
        let proceeding = results.filter { isProceedingRecommendation($0.recommendation) }
        var conflicts: [AgentRecommendationConflict] = []
        for blocker in blockers {
            for proceed in proceeding where blocker.role != proceed.role {
                conflicts.append(
                    AgentRecommendationConflict(
                        id: UUID(),
                        blockingRole: blocker.role,
                        proceedingRole: proceed.role,
                        summary: "\(blocker.role.displayName) recommends holding while \(proceed.role.displayName) recommends proceeding."
                    )
                )
            }
        }
        return conflicts
    }

    private func finalRecommendation(
        results: [AgentSubMissionResult],
        conflicts: [AgentRecommendationConflict],
        requiresLeadReview: Bool
    ) -> String {
        if !conflicts.isEmpty {
            return "Human FDE lead review required before execution because agent recommendations conflict."
        }
        if requiresLeadReview {
            return "Human FDE lead review required before execution."
        }
        if let strongest = results.max(by: { $0.confidence < $1.confidence }) {
            return strongest.recommendation
        }
        return "No agent reports collected."
    }

    private func title(for expertise: AgentExpertise) -> String {
        switch expertise {
        case .leadership: return "Coordinate mission"
        case .code: return "Investigate codebase"
        case .security: return "Review security and permissions"
        case .infrastructure: return "Inspect infrastructure"
        case .data: return "Assess data impact"
        case .documentation: return "Prepare documentation"
        }
    }

    private func objective(for expertise: AgentExpertise, mission: AgentMissionBrief) -> String {
        switch expertise {
        case .leadership:
            return "Coordinate delegation, resolve conflicts, and synthesize final recommendation for: \(mission.objective)"
        case .code:
            return "Inspect code and validation path related to: \(mission.objective)"
        case .security:
            return "Assess policy, permissions, approvals, and security risk for: \(mission.objective)"
        case .infrastructure:
            return "Inspect runtime, deployment, and production environment dependencies for: \(mission.objective)"
        case .data:
            return "Assess data sensitivity, schema, migration, and customer data impact for: \(mission.objective)"
        case .documentation:
            return "Create evidence-grounded handoff, customer update, and runbook notes for: \(mission.objective)"
        }
    }

    private func normalizedMissionText(mission: AgentMissionBrief, context: SharedMissionContext) -> String {
        var parts = [
            mission.objective,
            mission.system,
            mission.environment,
            mission.riskLevel.rawValue
        ]
        parts.append(contentsOf: context.evidenceDigest)
        parts.append(contentsOf: context.memory.previousFailures)
        parts.append(contentsOf: context.memory.successfulSolutions)
        parts.append(contentsOf: context.worldModel?.connectedSystems ?? [])
        parts.append(contentsOf: context.worldModel?.permissions ?? [])
        parts.append(contentsOf: context.worldModel?.environmentFacts ?? [])
        return parts.joined(separator: " ").lowercased()
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func isBlockingRecommendation(_ value: String) -> Bool {
        let text = value.lowercased()
        return containsAny(text, ["do not", "block", "hold", "deny", "unsafe", "stop", "reject"])
    }

    private func isProceedingRecommendation(_ value: String) -> Bool {
        let text = value.lowercased()
        return containsAny(text, ["proceed", "approve", "ship", "deploy", "merge", "execute"])
    }

    private func uniqueExpertise(_ expertise: [AgentExpertise]) -> [AgentExpertise] {
        var seen = Set<AgentExpertise>()
        var result: [AgentExpertise] = []
        for item in expertise where !seen.contains(item) {
            seen.insert(item)
            result.append(item)
        }
        return result
    }
}
