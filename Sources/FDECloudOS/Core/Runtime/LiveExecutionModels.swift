import Foundation

enum LiveExecutionState: String, CaseIterable, Hashable, Identifiable, Sendable {
    case idle = "IDLE"
    case understanding = "UNDERSTANDING"
    case planning = "PLANNING"
    case waitingApproval = "WAITING_APPROVAL"
    case executing = "EXECUTING"
    case verifying = "VERIFYING"
    case blocked = "BLOCKED"
    case failed = "FAILED"
    case completed = "COMPLETED"

    var id: String { rawValue }
}

enum LiveAgentStatus: String, Hashable, Sendable {
    case queued
    case active
    case completed
}

enum LiveExecutionArtifactKind: String, Hashable, Sendable {
    case executionPlan
    case report
    case policyUpdate
    case discoveredDependency
    case riskScore
    case fdeScore
}

struct LiveExecutionSnapshot: Equatable, Sendable {
    var state: LiveExecutionState
    var timeline: [LiveExecutionTimelineItem]
    var agents: [LiveAgentActivity]
    var artifacts: [LiveExecutionArtifact]

    static let empty = LiveExecutionSnapshot(
        state: .idle,
        timeline: [],
        agents: LiveExecutionMapper.defaultAgents(state: .idle, events: []),
        artifacts: []
    )
}

struct LiveExecutionTimelineItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var sequence: Int64
    var timestamp: Date
    var eventType: EventType
    var humanTitle: String
    var humanDetail: String
    var agent: AgentKind?
    var developerTrace: [DeveloperTraceField]
}

struct DeveloperTraceField: Identifiable, Equatable, Sendable {
    var key: String
    var value: String

    var id: String { key }
}

struct LiveAgentActivity: Identifiable, Equatable, Sendable {
    var agent: AgentKind
    var status: LiveAgentStatus
    var workTrace: String
    var lastEventSequence: Int64?

    var id: String { agent.rawValue }
}

struct LiveExecutionArtifact: Identifiable, Equatable, Sendable {
    var id: String
    var kind: LiveExecutionArtifactKind
    var title: String
    var value: String
    var detail: String?
}

struct LiveExecutionMapper: Sendable {
    static func snapshot(
        task: FDETask?,
        events: [ExecutionEvent],
        feedback: [FeedbackInsight] = [],
        policyDeltas: [ExecutionPolicyDelta] = [],
        graphNodes: [SystemGraphNode] = [],
        contextDiagnostics: ContextCompilerDiagnostics = .empty
    ) -> LiveExecutionSnapshot {
        let orderedEvents = events.sortedByExecutionOrder()
        let state = state(for: task, events: orderedEvents)

        return LiveExecutionSnapshot(
            state: state,
            timeline: orderedEvents.map(timelineItem(for:)),
            agents: defaultAgents(state: state, events: orderedEvents),
            artifacts: artifacts(
                task: task,
                events: orderedEvents,
                feedback: feedback,
                policyDeltas: policyDeltas,
                graphNodes: graphNodes,
                contextDiagnostics: contextDiagnostics
            )
        )
    }

    static func timelineItem(for event: ExecutionEvent) -> LiveExecutionTimelineItem {
        let translated = humanTranslation(for: event)
        return LiveExecutionTimelineItem(
            id: event.id,
            sequence: event.sequence,
            timestamp: event.timestamp,
            eventType: event.type,
            humanTitle: translated.title,
            humanDetail: translated.detail,
            agent: translated.agent,
            developerTrace: developerTrace(for: event)
        )
    }

    static func state(for task: FDETask?, events: [ExecutionEvent]) -> LiveExecutionState {
        let orderedEvents = events.sortedByExecutionOrder()
        if orderedEvents.contains(where: {
            $0.type == .taskCompleted && $0.payload["completion_gate_passed"] != "false"
        }) || task?.state == .completed {
            return .completed
        }

        if task?.state == .failed {
            return .failed
        }

        if task?.state == .blocked {
            return .blocked
        }

        if task?.state == .pendingApproval {
            return .waitingApproval
        }

        guard let lastEvent = orderedEvents.last else {
            return task == nil ? .idle : state(for: task?.state)
        }

        switch lastEvent.type {
        case .taskCreated:
            return .understanding
        case .contextCompiled:
            return .planning
        case .planGenerated:
            return .planning
        case .humanApprovalRequested:
            return .waitingApproval
        case .humanApproved:
            return .executing
        case .stepExecuted:
            return .verifying
        case .taskCompleted:
            return lastEvent.payload["completion_gate_passed"] == "false" ? .failed : .completed
        case .stateUpdated:
            return lastEvent.payload["state"].flatMap(TaskState.init(rawValue:)).map(state(for:)) ?? state(for: task?.state)
        case .toolCalled,
             .connectorCalled,
             .connectorDryRun,
             .connectorExecuted,
             .recoveryAttempted,
             .nodeExecutionStarted,
             .nodeExecutionCompleted,
             .executionDispatched,
             .executionReceived,
             .executionResponseReceived,
             .workerTaskReceived,
             .workerTaskCompleted,
             .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted:
            return .executing
        case .feedbackGenerated,
             .policyUpdated:
            return .verifying
        case .toolFailed,
             .connectorFailed,
             .authorizationDenied,
             .humanRejected,
             .nodeExecutionFailed,
             .workerTaskFailed,
             .userApprovalRejected:
            return .failed
        case .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned,
             .workerRegistered:
            return state(for: task?.state)
        }
    }

    static func defaultAgents(state: LiveExecutionState, events: [ExecutionEvent]) -> [LiveAgentActivity] {
        let orderedEvents = events.sortedByExecutionOrder()
        return [
            agentActivity(
                .systemUnderstanding,
                activeWhen: state == .understanding,
                completedWhen: orderedEvents.contains { $0.type == .contextCompiled || $0.type == .planGenerated },
                trace: latestTrace(
                    from: orderedEvents,
                    matching: [.taskCreated, .contextCompiled],
                    fallback: "Analyzing workspace dependencies"
                ),
                events: orderedEvents
            ),
            agentActivity(
                .planner,
                activeWhen: state == .planning,
                completedWhen: orderedEvents.contains { $0.type == .planGenerated },
                trace: latestTrace(
                    from: orderedEvents,
                    matching: [.contextCompiled, .planGenerated],
                    fallback: "Creating execution strategy"
                ),
                events: orderedEvents
            ),
            agentActivity(
                .executor,
                activeWhen: state == .executing || state == .verifying,
                completedWhen: orderedEvents.contains { $0.type == .taskCompleted },
                trace: latestTrace(
                    from: orderedEvents,
                    matching: [.toolCalled, .connectorCalled, .stepExecuted, .taskCompleted],
                    fallback: "Running integration check"
                ),
                events: orderedEvents
            ),
            agentActivity(
                .recovery,
                activeWhen: orderedEvents.last?.type == .recoveryAttempted,
                completedWhen: orderedEvents.contains { $0.type == .recoveryAttempted },
                trace: latestTrace(
                    from: orderedEvents,
                    matching: [.recoveryAttempted, .policyUpdated],
                    fallback: "Applying recovery policy"
                ),
                events: orderedEvents
            )
        ]
    }

    private static func state(for taskState: TaskState?) -> LiveExecutionState {
        switch taskState {
        case .created:
            return .understanding
        case .planned:
            return .planning
        case .running:
            return .executing
        case .waiting, .pendingApproval:
            return .waitingApproval
        case .blocked:
            return .blocked
        case .completed, .replayed:
            return .completed
        case .failed:
            return .failed
        case nil:
            return .idle
        }
    }

    private static func humanTranslation(for event: ExecutionEvent) -> (title: String, detail: String, agent: AgentKind?) {
        switch event.type {
        case .taskCreated:
            return ("Mission Created", event.summary, .systemUnderstanding)
        case .contextCompiled:
            return ("System Understanding Agent analyzed environment", event.summary, .systemUnderstanding)
        case .planGenerated:
            return ("Planner Agent created execution plan", event.summary, .planner)
        case .toolCalled:
            return ("Executor Agent running tool: \(toolName(from: event))", event.summary, .executor)
        case .humanApprovalRequested:
            return ("Waiting for human approval", event.summary, .executor)
        case .taskCompleted:
            return ("Mission completed", event.summary, .executor)
        case .stepExecuted:
            return ("Checked API dependency", event.summary, .executor)
        case .toolFailed:
            return ("Detected execution issue", event.summary, .executor)
        case .connectorCalled, .connectorDryRun, .connectorExecuted:
            return ("Checked connector dependency", event.summary, .executor)
        case .connectorFailed:
            return ("Detected connector issue", event.summary, .executor)
        case .recoveryAttempted:
            return ("Applied recovery", event.summary, .recovery)
        case .authorizationDenied:
            return ("Detected permission issue", event.summary, .policy)
        case .stateUpdated:
            return ("Runtime state updated", event.summary, nil)
        case .feedbackGenerated:
            return ("Generated execution report", event.summary, .policy)
        case .policyUpdated:
            return ("Updated execution policy", event.summary, .policy)
        case .humanApproved:
            return ("Human approved action", event.summary, .executor)
        case .humanRejected:
            return ("Human rejected action", event.summary, .executor)
        case .sessionStarted:
            return ("Session started", event.summary, nil)
        case .sessionEnded:
            return ("Session ended", event.summary, nil)
        case .workspaceSwitched:
            return ("Workspace switched", event.summary, nil)
        case .roleChanged:
            return ("Workspace role changed", event.summary, nil)
        case .routingDecisionMade:
            return ("Selected execution route", event.summary, .planner)
        case .nodeSelected:
            return ("Selected execution node", event.summary, .planner)
        case .executionTargetAssigned:
            return ("Assigned execution target", event.summary, .planner)
        case .nodeExecutionStarted:
            return ("Node execution started", event.summary, .executor)
        case .nodeExecutionCompleted:
            return ("Node execution completed", event.summary, .executor)
        case .nodeExecutionFailed:
            return ("Node execution failed", event.summary, .executor)
        case .executionDispatched:
            return ("Execution dispatched", event.summary, .executor)
        case .executionReceived:
            return ("Execution received", event.summary, .executor)
        case .executionResponseReceived:
            return ("Execution response received", event.summary, .executor)
        case .workerRegistered:
            return ("Worker registered", event.summary, nil)
        case .workerTaskReceived:
            return ("Worker received task", event.summary, .executor)
        case .workerTaskCompleted:
            return ("Worker completed task", event.summary, .executor)
        case .workerTaskFailed:
            return ("Worker task failed", event.summary, .executor)
        case .userMessageReceived:
            return ("User added instruction", event.summary, nil)
        case .userDecisionSelected:
            return ("User selected decision", event.summary, nil)
        case .userApprovalGranted:
            return ("User granted approval", event.summary, .policy)
        case .userApprovalRejected:
            return ("User rejected approval", event.summary, .policy)
        }
    }

    private static func developerTrace(for event: ExecutionEvent) -> [DeveloperTraceField] {
        let keys = [
            "event_id",
            "parent_event_id",
            "tool_call_id",
            "command",
            "policy_delta_id",
            "state",
            "risk_level",
            "event_classification",
            "correlation_id"
        ]
        var fields = [
            DeveloperTraceField(key: "type", value: event.type.rawValue),
            DeveloperTraceField(key: "sequence", value: String(event.sequence))
        ]
        if let parentEventID = event.parentEventID {
            fields.append(DeveloperTraceField(key: "parent_event", value: parentEventID.uuidString))
        }
        if let policy = event.payload["policy_delta_id"]
            ?? event.payload["policy_namespace"]
            ?? event.payload["governor_strategy"],
            !policy.isEmpty {
            fields.append(DeveloperTraceField(key: "policy", value: policy))
        }
        for key in keys {
            if let value = event.payload[key], !value.isEmpty {
                fields.append(DeveloperTraceField(key: key, value: value))
            }
        }
        return fields
    }

    private static func artifacts(
        task: FDETask?,
        events: [ExecutionEvent],
        feedback: [FeedbackInsight],
        policyDeltas: [ExecutionPolicyDelta],
        graphNodes: [SystemGraphNode],
        contextDiagnostics: ContextCompilerDiagnostics
    ) -> [LiveExecutionArtifact] {
        var artifacts: [LiveExecutionArtifact] = []

        if let task {
            artifacts.append(
                LiveExecutionArtifact(
                    id: "execution-plan",
                    kind: .executionPlan,
                    title: "Execution plan",
                    value: "\(task.plan.count) step\(task.plan.count == 1 ? "" : "s")",
                    detail: task.plan.map(\.title).joined(separator: " -> ")
                )
            )
            artifacts.append(
                LiveExecutionArtifact(
                    id: "risk-score",
                    kind: .riskScore,
                    title: "Risk score",
                    value: String(Int(task.riskScore)),
                    detail: "Failure probability \(Int((task.failureProbability * 100).rounded()))%"
                )
            )
            artifacts.append(
                LiveExecutionArtifact(
                    id: "fde-score",
                    kind: .fdeScore,
                    title: "FDE score",
                    value: String(Int(task.performanceScore)),
                    detail: nil
                )
            )
        }

        if contextDiagnostics.filesScanned > 0 {
            artifacts.append(
                LiveExecutionArtifact(
                    id: "discovered-dependencies",
                    kind: .discoveredDependency,
                    title: "Discovered dependencies",
                    value: "\(contextDiagnostics.filesScanned) files",
                    detail: contextDiagnostics.rootPath.isEmpty ? nil : contextDiagnostics.rootPath
                )
            )
        } else if !graphNodes.isEmpty {
            artifacts.append(
                LiveExecutionArtifact(
                    id: "discovered-dependencies",
                    kind: .discoveredDependency,
                    title: "Discovered dependencies",
                    value: "\(graphNodes.count) graph nodes",
                    detail: graphNodes.prefix(4).map(\.title).joined(separator: ", ")
                )
            )
        }

        if let latestFeedback = feedback.first(where: { $0.taskID == task?.id }) ?? feedback.first {
            artifacts.append(
                LiveExecutionArtifact(
                    id: "report-\(latestFeedback.id.uuidString)",
                    kind: .report,
                    title: "Report",
                    value: latestFeedback.kind.rawValue,
                    detail: latestFeedback.title
                )
            )
        } else if events.contains(where: { $0.type == .feedbackGenerated }) {
            artifacts.append(
                LiveExecutionArtifact(
                    id: "report",
                    kind: .report,
                    title: "Report",
                    value: "Generated",
                    detail: events.last(where: { $0.type == .feedbackGenerated })?.summary
                )
            )
        }

        if let delta = policyDeltas.first(where: { $0.sourceTaskID == task?.id }) ?? policyDeltas.first {
            artifacts.append(
                LiveExecutionArtifact(
                    id: "policy-\(delta.id.uuidString)",
                    kind: .policyUpdate,
                    title: "Policy update",
                    value: delta.kind.rawValue,
                    detail: delta.summary
                )
            )
        } else if events.contains(where: { $0.type == .policyUpdated }) {
            artifacts.append(
                LiveExecutionArtifact(
                    id: "policy-update",
                    kind: .policyUpdate,
                    title: "Policy update",
                    value: "Recorded",
                    detail: events.last(where: { $0.type == .policyUpdated })?.summary
                )
            )
        }

        return artifacts
    }

    private static func agentActivity(
        _ agent: AgentKind,
        activeWhen isActive: Bool,
        completedWhen isCompleted: Bool,
        trace: String,
        events: [ExecutionEvent]
    ) -> LiveAgentActivity {
        let status: LiveAgentStatus
        if isActive {
            status = .active
        } else if isCompleted {
            status = .completed
        } else {
            status = .queued
        }

        return LiveAgentActivity(
            agent: agent,
            status: status,
            workTrace: trace,
            lastEventSequence: events.last(where: { timelineItem(for: $0).agent == agent })?.sequence
        )
    }

    private static func latestTrace(
        from events: [ExecutionEvent],
        matching eventTypes: Set<EventType>,
        fallback: String
    ) -> String {
        guard let event = events.last(where: { eventTypes.contains($0.type) }) else {
            return fallback
        }
        return humanTranslation(for: event).detail.isEmpty ? fallback : humanTranslation(for: event).detail
    }

    private static func toolName(from event: ExecutionEvent) -> String {
        if let command = event.payload["command"], !command.isEmpty {
            return command
        }
        return event.summary
    }
}

private extension Array where Element == ExecutionEvent {
    func sortedByExecutionOrder() -> [ExecutionEvent] {
        sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
    }
}
