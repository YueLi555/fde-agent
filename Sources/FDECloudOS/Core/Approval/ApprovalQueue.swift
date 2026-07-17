import Foundation

enum ApprovalQueueError: LocalizedError {
    case requestNotFound(UUID)
    case requestNotPending(UUID, ApprovalState)

    var errorDescription: String? {
        switch self {
        case .requestNotFound(let id):
            return "Approval request not found: \(id.uuidString)."
        case .requestNotPending(let id, let state):
            return "Approval request \(id.uuidString) is \(state.rawValue) and cannot authorize an action."
        }
    }
}

actor ApprovalQueue {
    private let persistence: any PersistenceStore
    private var continuations: [UUID: [CheckedContinuation<ApprovalRequest, Never>]] = [:]

    init(persistence: any PersistenceStore) {
        self.persistence = persistence
    }

    func enqueue(_ request: ApprovalRequest) async throws -> ApprovalRequest {
        try await persistence.saveApprovalRequest(request)
        return request
    }

    func load(requestID: UUID) async throws -> ApprovalRequest? {
        try await persistence.loadApprovalRequest(id: requestID)
    }

    func pendingRequests(workspaceID: UUID) async throws -> [ApprovalRequest] {
        try await persistence.loadApprovalRequests(workspaceID: workspaceID, state: .pending)
    }

    func waitForDecision(requestID: UUID) async throws -> ApprovalRequest {
        guard let request = try await persistence.loadApprovalRequest(id: requestID) else {
            throw ApprovalQueueError.requestNotFound(requestID)
        }

        if request.state != .pending {
            return request
        }

        return await withCheckedContinuation { continuation in
            continuations[requestID, default: []].append(continuation)
        }
    }

    func approve(
        requestID: UUID,
        approverRole: UserRole,
        reason: String,
        metadata: [String: String] = [:]
    ) async throws -> ApprovalRequest {
        try await decide(
            requestID: requestID,
            state: .approved,
            approverRole: approverRole,
            reason: reason,
            metadata: metadata
        )
    }

    func reject(requestID: UUID, approverRole: UserRole, reason: String) async throws -> ApprovalRequest {
        try await decide(requestID: requestID, state: .rejected, approverRole: approverRole, reason: reason)
    }

    func supersede(
        requestID: UUID,
        approverRole: UserRole,
        reason: String,
        metadata: [String: String]
    ) async throws -> ApprovalRequest {
        guard var request = try await persistence.loadApprovalRequest(id: requestID) else {
            throw ApprovalQueueError.requestNotFound(requestID)
        }
        guard request.state == .pending else {
            throw ApprovalQueueError.requestNotPending(requestID, request.state)
        }
        request.state = .superseded
        request.decidedByRole = approverRole
        request.decisionReason = reason
        request.decidedAt = Date()
        request.metadata.merge(metadata) { _, new in new }
        try await persistence.saveApprovalRequest(request)
        resumeContinuations(for: request)
        return request
    }

    func expirePending(now: Date = Date()) async throws -> [ApprovalRequest] {
        let pending = try await persistence.loadApprovalRequests(workspaceID: nil, state: .pending)
        var expired: [ApprovalRequest] = []

        for var request in pending where request.expiresAt.map({ $0 <= now }) == true {
            request.state = .expired
            request.decidedAt = now
            request.decisionReason = "Approval request expired."
            try await persistence.saveApprovalRequest(request)
            resumeContinuations(for: request)
            expired.append(request)
        }

        return expired
    }

    private func decide(
        requestID: UUID,
        state: ApprovalState,
        approverRole: UserRole,
        reason: String,
        metadata: [String: String] = [:]
    ) async throws -> ApprovalRequest {
        guard var request = try await persistence.loadApprovalRequest(id: requestID) else {
            throw ApprovalQueueError.requestNotFound(requestID)
        }
        guard request.state == .pending else {
            throw ApprovalQueueError.requestNotPending(requestID, request.state)
        }

        request.state = state
        request.decidedByRole = approverRole
        request.decisionReason = reason
        request.decidedAt = Date()
        request.metadata.merge(metadata) { _, new in new }
        try await persistence.saveApprovalRequest(request)
        resumeContinuations(for: request)
        return request
    }

    private func resumeContinuations(for request: ApprovalRequest) {
        let waiting = continuations.removeValue(forKey: request.id) ?? []
        for continuation in waiting {
            continuation.resume(returning: request)
        }
    }
}

struct RiskClassificationEngine: Sendable {
    func classify(
        step: PlanStep,
        toolCall: ToolCall,
        workspace: Workspace,
        globalPolicy: GlobalExecutionPolicy?,
        systemFailureProfile: SystemFailureProfile?,
        governorDecision: GlobalGovernorDecision
    ) -> RiskClassification {
        var level = RiskSeverity.low
        var reasons: [String] = []

        if step.requiresApproval || toolCall.requiresApproval {
            level = .high
            reasons.append("Planner or tool marked this step as requiring approval.")
        }

        switch toolCall.type {
        case .connector:
            level = .high
            reasons.append("Connector operations require explicit local approval.")
        case .appleScript:
            level = maxRisk(level, .medium)
            reasons.append("AppleScript can affect local system state.")
        case .api:
            level = maxRisk(level, .medium)
            reasons.append("API tool calls are treated as externally sensitive.")
        case .shell:
            if isSystemChangingShellCommand(toolCall.command, arguments: toolCall.arguments) {
                level = .high
                reasons.append("Shell command can modify system or workspace state.")
            }
        }

        if workspace.role == .user {
            level = .high
            reasons.append("User role cannot bypass high-risk controls.")
        }

        if globalPolicy?.avoidedToolCommands.contains(toolCall.command) == true {
            level = .high
            reasons.append("GlobalExecutionPolicy marks this tool as avoided.")
        }

        if let cluster = systemFailureProfile?.clusters.first(where: { $0.toolCommand == toolCall.command }) {
            if cluster.frequency >= 2 {
                level = .high
                reasons.append("Failure history shows recurring failures for this tool.")
            } else {
                level = maxRisk(level, .medium)
                reasons.append("Failure history contains a prior failure for this tool.")
            }
        }

        if governorDecision.selectedStrategy == .conservativeRecovery || !governorDecision.overrides.isEmpty {
            level = maxRisk(level, .medium)
            reasons.append("Governor selected a cautious or overridden execution strategy.")
        }

        if reasons.isEmpty {
            reasons.append("No elevated risk signals detected.")
        }

        return RiskClassification(
            level: level,
            reasons: reasons,
            requiresApproval: rank(level) >= rank(.high)
        )
    }

    func classifyPolicyUpdate(delta: ExecutionPolicyDelta, workspace: Workspace) -> RiskClassification {
        if workspace.role == .user {
            return RiskClassification(
                level: .high,
                reasons: ["User role cannot approve execution policy updates."],
                requiresApproval: true
            )
        }

        if delta.retryBudget > 3 {
            return RiskClassification(
                level: .high,
                reasons: ["Policy update increases retry budget beyond local safety threshold."],
                requiresApproval: true
            )
        }

        return RiskClassification(
            level: .medium,
            reasons: ["Policy update recorded as medium risk for audit."],
            requiresApproval: false
        )
    }

    private func isSystemChangingShellCommand(_ command: String, arguments: [String]) -> Bool {
        let dangerousExecutables: Set<String> = [
            "/bin/rm",
            "/bin/mv",
            "/bin/chmod",
            "/usr/sbin/chown",
            "/usr/bin/sudo",
            "/bin/launchctl",
            "/usr/bin/defaults",
            "/usr/bin/killall"
        ]
        if dangerousExecutables.contains(command) {
            return true
        }

        let combined = ([command] + arguments).joined(separator: " ").lowercased()
        return combined.contains(" rm ")
            || combined.contains(" --delete")
            || combined.contains(" chmod ")
            || combined.contains(" chown ")
            || combined.contains(" launchctl ")
            || combined.contains(" defaults write ")
    }

    private func maxRisk(_ lhs: RiskSeverity, _ rhs: RiskSeverity) -> RiskSeverity {
        rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private func rank(_ severity: RiskSeverity) -> Int {
        switch severity {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }
}
