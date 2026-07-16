import Foundation

struct AgentTimeline: Equatable, Sendable {
    var missionID: UUID?
    var missionTitle: String
    var semanticProgress: String
    var entries: [AgentTimelineEntry]

    var currentActivity: AgentTimelineEntry? {
        entries.last
    }

    var requiresUserAction: Bool {
        currentActivity?.requiresUserAction == true
    }

    static let empty = AgentTimeline(
        missionID: nil,
        missionTitle: "No active mission",
        semanticProgress: "Idle",
        entries: []
    )

    static func build(
        missionID: UUID?,
        missionTitle: String,
        events: [AgentWorkspaceEvent]
    ) -> AgentTimeline {
        let orderedEvents = events.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.eventID.uuidString < rhs.eventID.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }
        let latestEventID = orderedEvents.last?.eventID
        let entries = orderedEvents.map { event in
            AgentTimelineEntry(
                event: event,
                status: timelineStatus(for: event, latestEventID: latestEventID)
            )
        }
        let progress = semanticProgress(for: entries.last?.stage)

        return AgentTimeline(
            missionID: missionID,
            missionTitle: missionTitle,
            semanticProgress: progress,
            entries: entries
        )
    }

    private static func timelineStatus(
        for event: AgentWorkspaceEvent,
        latestEventID: UUID?
    ) -> AgentWorkspaceEventStatus {
        if event.requiresUserAction {
            return .waitingHuman
        }
        return event.status
    }

    private static func semanticProgress(for stage: AgentWorkspaceStage?) -> String {
        switch stage {
        case .understanding:
            return "Understanding environment"
        case .planning:
            return "Planning solution"
        case .ready:
            return "Ready to execute"
        case .deciding:
            return "Choosing next action"
        case .executing:
            return "Executing changes"
        case .observing:
            return "Validating outcome"
        case .verifying:
            return "Verifying results"
        case .adapting:
            return "Adapting recovery path"
        case .waitingHuman:
            return "Waiting for approval"
        case .blocked:
            return "Blocked"
        case .failed:
            return "Failed"
        case .completed:
            return "Mission completed"
        case nil:
            return "Idle"
        }
    }
}

struct AgentTimelineEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var eventID: UUID
    var timestamp: Date
    var missionID: UUID
    var stage: AgentWorkspaceStage
    var title: String
    var summary: String
    var status: AgentWorkspaceEventStatus
    var evidence: [AgentWorkspaceEvidence]
    var requiresUserAction: Bool

    init(event: AgentWorkspaceEvent, status: AgentWorkspaceEventStatus? = nil) {
        self.id = event.eventID
        self.eventID = event.eventID
        self.timestamp = event.timestamp
        self.missionID = event.missionID
        self.stage = event.stage
        self.title = event.title
        self.summary = event.summary
        self.status = status ?? event.status
        self.evidence = event.evidence
        self.requiresUserAction = event.requiresUserAction
    }
}
