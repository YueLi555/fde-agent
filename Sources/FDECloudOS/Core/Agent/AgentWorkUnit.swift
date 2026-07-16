import Foundation

enum AgentWorkUnitKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case request = "REQUEST"
    case understanding = "UNDERSTANDING"
    case planning = "PLANNING"
    case execution = "EXECUTION"
    case approval = "APPROVAL"
    case recovery = "RECOVERY"
    case policy = "POLICY"
    case result = "RESULT"
    case system = "SYSTEM"

    var id: String { rawValue }
}

enum AgentWorkUnitStatus: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case planned = "PLANNED"
    case active = "ACTIVE"
    case waitingApproval = "WAITING_APPROVAL"
    case blocked = "BLOCKED"
    case partial = "PARTIAL"
    case completed = "COMPLETED"
    case failed = "FAILED"

    var id: String { rawValue }
}

struct AgentWorkUnit: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var taskID: UUID?
    var kind: AgentWorkUnitKind
    var status: AgentWorkUnitStatus
    var title: String
    var detail: String?
    var agent: AgentKind?
    var startedAt: Date
    var updatedAt: Date
    var eventIDs: [UUID]
    var eventTypes: [EventType]
    var relatedArtifactID: String?

    init(
        id: String,
        workspaceID: UUID,
        taskID: UUID?,
        kind: AgentWorkUnitKind,
        status: AgentWorkUnitStatus,
        title: String,
        detail: String? = nil,
        agent: AgentKind? = nil,
        startedAt: Date,
        updatedAt: Date? = nil,
        eventIDs: [UUID] = [],
        eventTypes: [EventType] = [],
        relatedArtifactID: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.taskID = taskID
        self.kind = kind
        self.status = status
        self.title = title
        self.detail = detail
        self.agent = agent
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.eventIDs = eventIDs
        self.eventTypes = eventTypes
        self.relatedArtifactID = relatedArtifactID
    }

    mutating func append(
        event: ExecutionEvent,
        status nextStatus: AgentWorkUnitStatus,
        title nextTitle: String,
        detail nextDetail: String?,
        relatedArtifactID nextArtifactID: String?
    ) {
        if !eventIDs.contains(event.id) {
            eventIDs.append(event.id)
        }
        if !eventTypes.contains(event.type) {
            eventTypes.append(event.type)
        }
        status = nextStatus
        title = nextTitle
        detail = nextDetail ?? detail
        updatedAt = max(updatedAt, event.timestamp)
        relatedArtifactID = nextArtifactID ?? relatedArtifactID
    }
}
