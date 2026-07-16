import Foundation

enum ReplayIntegrityError: LocalizedError, Equatable {
    case duplicateOrNonIncreasingSequence(Int64)
    case brokenParentChain(eventID: UUID, expectedParentID: UUID?, actualParentID: UUID?)

    var errorDescription: String? {
        switch self {
        case .duplicateOrNonIncreasingSequence(let sequence):
            return "Replay sequence is not strictly increasing at \(sequence)."
        case .brokenParentChain(let eventID, let expectedParentID, let actualParentID):
            return "Replay parent chain is broken for \(eventID). Expected \(expectedParentID?.uuidString ?? "nil"), got \(actualParentID?.uuidString ?? "nil")."
        }
    }
}

struct ReplayEngine: Sendable {
    func frames(events: [ExecutionEvent], graph: ([SystemGraphNode], [SystemGraphEdge])) throws -> [ReplayFrame] {
        let orderedEvents = events.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
        try validate(events: orderedEvents)

        return orderedEvents.map { event in
            ReplayFrame(
                id: event.id,
                sequence: event.sequence,
                timestamp: event.timestamp,
                title: "\(event.type.rawValue): \(event.summary)",
                state: event.payload["state"].flatMap(TaskState.init(rawValue:)),
                graphNodeCount: graph.0.count,
                graphEdgeCount: graph.1.count
            )
        }
    }

    func validate(events: [ExecutionEvent]) throws {
        var previousSequence: Int64?
        var previousEventID: UUID?

        for event in events {
            if let previousSequence, event.sequence <= previousSequence {
                throw ReplayIntegrityError.duplicateOrNonIncreasingSequence(event.sequence)
            }

            if event.parentEventID != previousEventID {
                throw ReplayIntegrityError.brokenParentChain(
                    eventID: event.id,
                    expectedParentID: previousEventID,
                    actualParentID: event.parentEventID
                )
            }

            previousSequence = event.sequence
            previousEventID = event.id
        }
    }
}
