import Foundation

enum AgentSessionEventScope {
    static func events(from events: [ExecutionEvent], for session: AgentSession?) -> [ExecutionEvent] {
        guard let session else {
            return events
        }

        return events.filter { event in
            belongsToSession(event, session: session)
        }
    }

    static func belongsToSession(_ event: ExecutionEvent, session: AgentSession) -> Bool {
        let sessionID = session.sessionID.uuidString
        if let runtimeTaskID = session.runtimeTaskID {
            return event.taskID == runtimeTaskID || event.payload["session_id"] == sessionID
        }

        return event.taskID == nil && event.payload["session_id"] == sessionID
    }
}
