import Foundation

enum AgentNarrationKind: String, Hashable, Sendable {
    case action = "Action"
    case observation = "Observation"
    case decision = "Decision"
    case result = "Result"
}

enum AgentNarrationStatus: String, Hashable, Sendable {
    case active = "Active"
    case completed = "Completed"
    case upNext = "Up Next"
}

struct AgentNarrationItem: Identifiable, Equatable, Sendable {
    let id: String
    var eventID: UUID?
    var sequence: Int64?
    var timestamp: Date?
    var kind: AgentNarrationKind
    var status: AgentNarrationStatus
    var title: String
    var detail: String?
    var agent: AgentKind?
}

struct AgentNarrationEvidence: Identifiable, Equatable, Sendable {
    let id: String
    var sourceEventID: UUID
    var sequence: Int64
    var timestamp: Date
    var kind: AgentNarrationKind
    var title: String
    var detail: String?
}

struct AgentNarrationFeed: Equatable, Sendable {
    var currentAction: AgentNarrationItem?
    var completedActions: [AgentNarrationItem]
    var nextAction: AgentNarrationItem?
    var evidenceProduced: [AgentNarrationEvidence]

    static let empty = AgentNarrationFeed(
        currentAction: nil,
        completedActions: [],
        nextAction: nil,
        evidenceProduced: []
    )
}

struct AgentNarrationEngine: Sendable {
    func feed(task: FDETask?, events: [ExecutionEvent]) -> AgentNarrationFeed {
        Self.feed(task: task, events: events)
    }

    static func feed(task: FDETask?, events: [ExecutionEvent]) -> AgentNarrationFeed {
        let orderedEvents = events.sortedByNarrationOrder()
        let updates = orderedEvents.compactMap { narrationItem(for: $0) }
        let current = activeCurrentAction(from: updates, task: task)
        let completed = completedActions(from: updates)

        return AgentNarrationFeed(
            currentAction: current,
            completedActions: completed,
            nextAction: nextAction(task: task, events: orderedEvents, currentAction: current),
            evidenceProduced: orderedEvents.compactMap { evidence(for: $0) }
        )
    }

    private static func activeCurrentAction(from updates: [AgentNarrationItem], task: FDETask?) -> AgentNarrationItem? {
        guard var current = updates.last else { return nil }
        current.status = task?.state == .completed || isTerminal(current) ? .completed : .active
        return current
    }

    private static func completedActions(from updates: [AgentNarrationItem]) -> [AgentNarrationItem] {
        guard updates.count > 1 else { return [] }
        return updates.dropLast().map { item in
            var completed = item
            completed.status = .completed
            return completed
        }
    }

    private static func isTerminal(_ item: AgentNarrationItem) -> Bool {
        item.title == "Agent completed the request" || item.title == "Human rejected requested action"
    }

    private static func narrationItem(for event: ExecutionEvent) -> AgentNarrationItem? {
        let title: String
        let kind: AgentNarrationKind
        let agent: AgentKind?
        let detail: String?

        switch event.type {
        case .taskCreated:
            title = "Agent started investigating the request"
            kind = .action
            agent = .systemUnderstanding
            detail = safeSummary(event.summary, fallback: "Runtime task created")
        case .contextCompiled:
            title = "Agent compiled workspace context"
            kind = .observation
            agent = .systemUnderstanding
            detail = "Workspace context is ready"
        case .planGenerated:
            title = "Planner created execution strategy"
            kind = .decision
            agent = .planner
            detail = planDetail(from: event)
        case .stateUpdated:
            title = stateTitle(from: event)
            kind = .action
            agent = .executor
            detail = stateDetail(from: event)
        case .toolCalled:
            title = "Executor is inspecting workspace"
            kind = .action
            agent = .executor
            detail = toolCallDetail(from: event)
        case .connectorCalled:
            title = "Agent is querying external system"
            kind = .action
            agent = .executor
            detail = connectorDetail(from: event, fallback: "Connector request prepared")
        case .connectorDryRun:
            title = "Agent prepared connector dry run"
            kind = .action
            agent = .executor
            detail = connectorDetail(from: event, fallback: "Connector dry run recorded")
        case .connectorExecuted:
            title = "External system returned connector result"
            kind = .result
            agent = .executor
            detail = connectorDetail(from: event, fallback: "Connector execution recorded")
        case .stepExecuted:
            title = "Executor produced a step result"
            kind = .result
            agent = .executor
            detail = stepResultDetail(from: event)
        case .toolFailed:
            title = "Executor observed a tool failure"
            kind = .observation
            agent = .executor
            detail = failureDetail(from: event, fallback: "Tool failure recorded")
        case .connectorFailed:
            title = "External system query failed"
            kind = .observation
            agent = .executor
            detail = failureDetail(from: event, fallback: "Connector failure recorded")
        case .recoveryAttempted:
            title = "Agent detected failure and is attempting recovery"
            kind = .decision
            agent = .recovery
            detail = recoveryDetail(from: event)
        case .humanApprovalRequested:
            title = "Human approval required before continuing"
            kind = .decision
            agent = .policy
            detail = approvalDetail(from: event)
        case .humanApproved:
            title = "Human approved requested action"
            kind = .decision
            agent = .policy
            detail = approvalDecisionDetail(from: event, fallback: "Approval granted")
        case .humanRejected:
            title = "Human rejected requested action"
            kind = .decision
            agent = .policy
            detail = approvalDecisionDetail(from: event, fallback: "Approval rejected")
        case .taskCompleted:
            title = "Agent completed the request"
            kind = .result
            agent = .executor
            detail = completionDetail(from: event)
        case .feedbackGenerated:
            title = "Agent generated \(feedbackArtifactPhrase(from: event))"
            kind = .result
            agent = .policy
            detail = safeSummary(event.summary, fallback: "Feedback report generated")
        case .policyUpdated:
            title = "Agent updated execution policy"
            kind = .decision
            agent = .policy
            detail = policyDetail(from: event)
        case .authorizationDenied:
            title = "Execution stopped by policy"
            kind = .decision
            agent = .policy
            detail = safeSummary(event.summary, fallback: "Authorization denied")
        case .routingDecisionMade:
            title = "Planner selected execution route"
            kind = .decision
            agent = .planner
            detail = routeDetail(from: event)
        case .nodeSelected:
            title = "Planner selected execution node"
            kind = .decision
            agent = .planner
            detail = nodeDetail(from: event)
        case .executionTargetAssigned:
            title = "Planner assigned execution target"
            kind = .decision
            agent = .planner
            detail = nodeDetail(from: event)
        case .nodeExecutionStarted, .executionDispatched, .executionReceived, .workerTaskReceived:
            title = "Executor dispatched work to runtime node"
            kind = .action
            agent = .executor
            detail = nodeDetail(from: event)
        case .nodeExecutionCompleted, .executionResponseReceived, .workerTaskCompleted:
            title = "Runtime node returned execution result"
            kind = .result
            agent = .executor
            detail = nodeDetail(from: event)
        case .nodeExecutionFailed, .workerTaskFailed:
            title = "Runtime node reported execution failure"
            kind = .observation
            agent = .executor
            detail = failureDetail(from: event, fallback: "Node execution failure recorded")
        case .sessionStarted:
            title = "Session started"
            kind = .action
            agent = nil
            detail = safeSummary(event.summary, fallback: "Local session started")
        case .sessionEnded:
            title = "Session ended"
            kind = .result
            agent = nil
            detail = safeSummary(event.summary, fallback: "Local session ended")
        case .workspaceSwitched:
            title = "Workspace switched"
            kind = .decision
            agent = nil
            detail = safeSummary(event.summary, fallback: "Active workspace changed")
        case .roleChanged:
            title = "Workspace role changed"
            kind = .decision
            agent = nil
            detail = safeSummary(event.summary, fallback: "Role changed")
        case .workerRegistered:
            title = "Worker node registered"
            kind = .observation
            agent = nil
            detail = nodeDetail(from: event)
        case .userMessageReceived:
            title = "User added an instruction"
            kind = .action
            agent = nil
            detail = safeSummary(event.summary, fallback: "User message received")
        case .userDecisionSelected:
            title = "User selected a path forward"
            kind = .decision
            agent = nil
            detail = safeSummary(event.summary, fallback: "User decision selected")
        case .userApprovalGranted:
            title = "User approved requested action"
            kind = .decision
            agent = .policy
            detail = safeSummary(event.summary, fallback: "Approval granted")
        case .userApprovalRejected:
            title = "User rejected requested action"
            kind = .decision
            agent = .policy
            detail = safeSummary(event.summary, fallback: "Approval rejected")
        }

        return AgentNarrationItem(
            id: event.id.uuidString,
            eventID: event.id,
            sequence: event.sequence,
            timestamp: event.timestamp,
            kind: kind,
            status: .completed,
            title: title,
            detail: detail,
            agent: agent
        )
    }

    private static func evidence(for event: ExecutionEvent) -> AgentNarrationEvidence? {
        let title: String
        let kind: AgentNarrationKind
        let detail: String?

        switch event.type {
        case .connectorExecuted:
            title = "Connector activity recorded"
            kind = .result
            detail = connectorDetail(from: event, fallback: "Connector event recorded")
        case .stepExecuted:
            title = "Step result captured"
            kind = .result
            detail = stepResultDetail(from: event)
        case .toolFailed, .connectorFailed, .nodeExecutionFailed, .workerTaskFailed:
            title = "Failure signal captured"
            kind = .observation
            detail = failureDetail(from: event, fallback: "Failure recorded")
        case .humanApproved, .humanRejected:
            title = "Approval decision recorded"
            kind = .decision
            detail = approvalDecisionDetail(from: event, fallback: "Approval decision recorded")
        case .humanApprovalRequested:
            title = "Approval request recorded"
            kind = .decision
            detail = approvalDetail(from: event)
        case .feedbackGenerated:
            title = "\(feedbackArtifactName(from: event)) generated"
            kind = .result
            detail = safeSummary(event.summary, fallback: "Feedback report generated")
        case .policyUpdated:
            title = "Policy delta recorded"
            kind = .decision
            detail = policyDetail(from: event)
        case .authorizationDenied:
            title = "Policy decision recorded"
            kind = .decision
            detail = safeSummary(event.summary, fallback: "Authorization denied")
        case .nodeExecutionCompleted,
             .executionResponseReceived,
             .workerTaskCompleted:
            title = "Runtime node event recorded"
            kind = .result
            detail = nodeDetail(from: event)
        case .taskCreated,
             .contextCompiled,
             .planGenerated,
             .toolCalled,
             .connectorCalled,
             .connectorDryRun,
             .recoveryAttempted,
             .taskCompleted,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned,
             .nodeExecutionStarted,
             .executionDispatched,
             .executionReceived,
             .workerRegistered,
             .workerTaskReceived,
             .stateUpdated,
             .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted,
             .userApprovalRejected:
            return nil
        }

        return AgentNarrationEvidence(
            id: "evidence-\(event.id.uuidString)",
            sourceEventID: event.id,
            sequence: event.sequence,
            timestamp: event.timestamp,
            kind: kind,
            title: title,
            detail: detail
        )
    }

    private static func nextAction(
        task: FDETask?,
        events: [ExecutionEvent],
        currentAction: AgentNarrationItem?
    ) -> AgentNarrationItem? {
        guard task?.state != .completed,
              currentAction?.title != "Agent completed the request",
              currentAction?.title != "Human rejected requested action" else {
            return nil
        }

        guard let lastEvent = events.last else {
            return nextItem(
                title: task == nil ? "Waiting for a request" : "Agent will start investigating the request",
                detail: task?.title,
                kind: .action,
                agent: .systemUnderstanding
            )
        }

        switch lastEvent.type {
        case .taskCreated, .contextCompiled:
            return nextItem(
                title: "Planner will create execution strategy",
                detail: task?.title,
                kind: .decision,
                agent: .planner
            )
        case .planGenerated,
             .stateUpdated,
             .humanApproved,
             .stepExecuted,
             .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted:
            if let nextStep = nextPlanStep(task: task, events: events) {
                return nextItem(
                    title: "Executor will run next planned action",
                    detail: sanitizeDisplayText(nextStep.title, fallback: "Next plan step"),
                    kind: .action,
                    agent: .executor
                )
            }
            return nextItem(
                title: "Executor will verify results",
                detail: task?.title,
                kind: .observation,
                agent: .executor
            )
        case .toolCalled, .connectorCalled, .connectorDryRun:
            return nextItem(
                title: "Executor will capture the result",
                detail: currentStepTitle(task: task, event: lastEvent),
                kind: .result,
                agent: .executor
            )
        case .toolFailed, .connectorFailed, .nodeExecutionFailed, .workerTaskFailed:
            return nextItem(
                title: "Recovery agent will inspect failure",
                detail: safeCommand(event: lastEvent),
                kind: .decision,
                agent: .recovery
            )
        case .recoveryAttempted:
            return nextItem(
                title: "Executor will run recovery action",
                detail: safePayloadValue(lastEvent, key: "recovery_command"),
                kind: .action,
                agent: .executor
            )
        case .humanApprovalRequested:
            return nextItem(
                title: "Waiting for approval decision",
                detail: approvalDetail(from: lastEvent),
                kind: .decision,
                agent: .policy
            )
        case .nodeExecutionStarted, .executionDispatched, .executionReceived, .workerTaskReceived:
            return nextItem(
                title: "Runtime node will return execution result",
                detail: nodeDetail(from: lastEvent),
                kind: .result,
                agent: .executor
            )
        case .connectorExecuted,
             .nodeExecutionCompleted,
             .executionResponseReceived,
             .workerTaskCompleted:
            return nextItem(
                title: "Executor will verify results",
                detail: nodeDetail(from: lastEvent),
                kind: .observation,
                agent: .executor
            )
        case .taskCompleted,
             .feedbackGenerated,
             .policyUpdated,
             .humanRejected,
             .authorizationDenied,
             .userApprovalRejected,
             .sessionEnded:
            return nil
        case .sessionStarted,
             .workspaceSwitched,
             .roleChanged,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned,
             .workerRegistered:
            return nextItem(
                title: "Agent will continue from latest runtime state",
                detail: safeSummary(lastEvent.summary, fallback: lastEvent.type.rawValue),
                kind: .action,
                agent: nil
            )
        }
    }

    private static func nextItem(
        title: String,
        detail: String?,
        kind: AgentNarrationKind,
        agent: AgentKind?
    ) -> AgentNarrationItem {
        AgentNarrationItem(
            id: "next-\(title)",
            eventID: nil,
            sequence: nil,
            timestamp: nil,
            kind: kind,
            status: .upNext,
            title: title,
            detail: detail,
            agent: agent
        )
    }

    private static func nextPlanStep(task: FDETask?, events: [ExecutionEvent]) -> PlanStep? {
        guard let plan = task?.plan, !plan.isEmpty else { return nil }
        let completedStepIDs = Set(
            events
                .filter { $0.type == .stepExecuted }
                .compactMap { $0.payload["step_id"] }
        )
        return plan.first { !completedStepIDs.contains($0.id) }
    }

    private static func currentStepTitle(task: FDETask?, event: ExecutionEvent) -> String? {
        guard let stepID = event.payload["step_id"],
              let step = task?.plan.first(where: { $0.id == stepID }) else {
            return safeCommand(event: event)
        }
        return sanitizeDisplayText(step.title, fallback: "Current plan step")
    }

    private static func planDetail(from event: ExecutionEvent) -> String {
        var parts: [String] = []
        if let confidence = safePayloadValue(event, key: "confidence") {
            parts.append("Confidence \(confidence)")
        }
        if let strategy = safePayloadValue(event, key: "governor_strategy") {
            parts.append("Strategy \(strategy)")
        }
        return parts.isEmpty ? "Execution strategy ready" : parts.joined(separator: " | ")
    }

    private static func stateTitle(from event: ExecutionEvent) -> String {
        guard let state = event.payload["state"].flatMap(TaskState.init(rawValue:)) else {
            return "Runtime state updated"
        }
        switch state {
        case .running:
            return "Executor started running the plan"
        case .pendingApproval:
            return "Runtime paused for approval"
        case .completed:
            return "Runtime marked the task complete"
        case .failed:
            return "Runtime marked the task failed"
        case .blocked:
            return "Runtime blocked the task safely"
        case .created, .planned, .waiting, .replayed:
            return "Runtime state updated"
        }
    }

    private static func stateDetail(from event: ExecutionEvent) -> String? {
        if let state = safePayloadValue(event, key: "state") {
            return "State \(state)"
        }
        return safeSummary(event.summary, fallback: "State changed")
    }

    private static func toolCallDetail(from event: ExecutionEvent) -> String? {
        var parts: [String] = []
        if let command = safeCommand(event: event) {
            parts.append(command)
        }
        if let attempt = safePayloadValue(event, key: "attempt") {
            parts.append("Attempt \(attempt)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    private static func connectorDetail(from event: ExecutionEvent, fallback: String) -> String {
        var parts: [String] = []
        if let command = safeCommand(event: event) {
            parts.append(command)
        }
        if let network = safePayloadValue(event, key: "network") {
            parts.append("Network \(network)")
        }
        return parts.isEmpty ? fallback : parts.joined(separator: " | ")
    }

    private static func stepResultDetail(from event: ExecutionEvent) -> String {
        if let exitCode = safePayloadValue(event, key: "exit_code") {
            return "Exit code \(exitCode); output captured"
        }
        return safeSummary(event.summary, fallback: "Step output captured")
    }

    private static func failureDetail(from event: ExecutionEvent, fallback: String) -> String {
        var parts: [String] = []
        if let command = safeCommand(event: event) {
            parts.append(command)
        }
        if let attempt = safePayloadValue(event, key: "attempt") {
            parts.append("Attempt \(attempt)")
        }
        return parts.isEmpty ? fallback : parts.joined(separator: " | ")
    }

    private static func recoveryDetail(from event: ExecutionEvent) -> String {
        let failed = safePayloadValue(event, key: "failed_command")
        let recovery = safePayloadValue(event, key: "recovery_command")
        switch (failed, recovery) {
        case let (failed?, recovery?):
            return "\(failed) -> \(recovery)"
        case let (_, recovery?):
            return "Recovery action \(recovery)"
        case let (failed?, _):
            return "Recovering from \(failed)"
        case (nil, nil):
            return "Recovery action selected"
        }
    }

    private static func approvalDetail(from event: ExecutionEvent) -> String {
        var parts: [String] = []
        if let command = safeCommand(event: event) {
            parts.append(command)
        }
        if let risk = safePayloadValue(event, key: "risk_level") {
            parts.append("Risk \(risk)")
        }
        return parts.isEmpty ? "Waiting for human decision" : parts.joined(separator: " | ")
    }

    private static func approvalDecisionDetail(from event: ExecutionEvent, fallback: String) -> String {
        if let command = safeCommand(event: event) {
            return command
        }
        return safeSummary(event.summary, fallback: fallback)
    }

    private static func completionDetail(from event: ExecutionEvent) -> String {
        var parts: [String] = []
        if let risk = safePayloadValue(event, key: "risk_score") {
            parts.append("Risk \(risk)")
        }
        if let fdeScore = safePayloadValue(event, key: "performance_score") {
            parts.append("FDE score \(fdeScore)")
        }
        return parts.isEmpty ? safeSummary(event.summary, fallback: "Task completed") : parts.joined(separator: " | ")
    }

    private static func feedbackArtifactName(from event: ExecutionEvent) -> String {
        let name = safeSummary(event.summary, fallback: "Review artifact")
        return name == EventType.feedbackGenerated.rawValue ? "Review artifact" : name
    }

    private static func feedbackArtifactPhrase(from event: ExecutionEvent) -> String {
        feedbackArtifactName(from: event).lowercased()
    }

    private static func policyDetail(from event: ExecutionEvent) -> String {
        if let kind = safePayloadValue(event, key: "kind") {
            return "Policy kind \(kind)"
        }
        return safeSummary(event.summary, fallback: "Policy update recorded")
    }

    private static func routeDetail(from event: ExecutionEvent) -> String? {
        safePayloadValue(event, key: "selected_route")
            ?? safePayloadValue(event, key: "routing_decision")
            ?? safeSummary(event.summary, fallback: "Routing decision recorded")
    }

    private static func nodeDetail(from event: ExecutionEvent) -> String? {
        safePayloadValue(event, key: "node_id")
            ?? safePayloadValue(event, key: "target_node_id")
            ?? safePayloadValue(event, key: "worker_id")
            ?? safeSummary(event.summary, fallback: "Runtime node event recorded")
    }

    private static func safeCommand(event: ExecutionEvent) -> String? {
        guard let value = event.payload["command"] ?? event.payload["failed_command"] ?? event.payload["recovery_command"],
              !value.isEmpty else {
            return nil
        }
        return sanitizeCommand(value)
    }

    private static func safePayloadValue(_ event: ExecutionEvent, key: String) -> String? {
        let allowedKeys: Set<String> = [
            "attempt",
            "confidence",
            "exit_code",
            "governor_strategy",
            "failed_command",
            "kind",
            "network",
            "node_id",
            "performance_score",
            "recovery_command",
            "risk_level",
            "risk_score",
            "routing_decision",
            "selected_route",
            "state",
            "target_node_id",
            "worker_id"
        ]
        guard allowedKeys.contains(key),
              let value = event.payload[key],
              !value.isEmpty else {
            return nil
        }
        if key.hasSuffix("command") {
            return sanitizeCommand(value)
        }
        return sanitizeDisplayText(value, fallback: nil)
    }

    private static func safeSummary(_ summary: String, fallback: String) -> String {
        sanitizeDisplayText(summary, fallback: fallback) ?? fallback
    }

    private static func sanitizeDisplayText(_ value: String, fallback: String?) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        if containsPrivateReasoningMarker(trimmed) {
            return fallback
        }

        let redacted = redactSensitiveInlineValues(trimmed)
        if redacted.isEmpty {
            return fallback
        }
        return String(redacted.prefix(180))
    }

    private static func containsPrivateReasoningMarker(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return [
            "chain_of_thought",
            "chain-of-thought",
            "chain of thought",
            "scratchpad",
            "private reasoning",
            "reasoning:",
            "thought:",
            "analysis:"
        ].contains { lowercased.contains($0) }
    }

    private static func redactSensitiveInlineValues(_ value: String) -> String {
        var words = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var redactNext = false
        for index in words.indices {
            let lowercased = words[index].lowercased()
            if redactNext {
                words[index] = "[redacted]"
                redactNext = false
                continue
            }
            if isSensitiveFlag(lowercased) {
                redactNext = true
                continue
            }
            if containsSensitiveAssignment(lowercased) {
                words[index] = redactedAssignment(words[index])
            } else if lowercased == "bearer" || lowercased == "bearer:" {
                words[index] = "[redacted]"
                redactNext = true
            } else if lowercased.hasPrefix("bearer") {
                words[index] = "[redacted]"
            }
        }
        return words.joined(separator: " ")
    }

    private static func sanitizeCommand(_ command: String) -> String {
        let redacted = redactSensitiveInlineValues(command)
        return sanitizeDisplayText(redacted, fallback: "Command recorded") ?? "Command recorded"
    }

    private static func isSensitiveFlag(_ value: String) -> Bool {
        [
            "--api-key",
            "--apikey",
            "--authorization",
            "--credential",
            "--password",
            "--secret",
            "--token",
            "-p"
        ].contains(value)
    }

    private static func containsSensitiveAssignment(_ value: String) -> Bool {
        [
            "api_key=",
            "apikey=",
            "authorization=",
            "credential=",
            "password=",
            "secret=",
            "token="
        ].contains { value.contains($0) }
    }

    private static func redactedAssignment(_ value: String) -> String {
        guard let separatorIndex = value.firstIndex(of: "=") else {
            return "[redacted]"
        }
        return "\(value[..<value.index(after: separatorIndex)])[redacted]"
    }
}

private extension Array where Element == ExecutionEvent {
    func sortedByNarrationOrder() -> [ExecutionEvent] {
        sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
    }
}
