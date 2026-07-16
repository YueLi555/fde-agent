import Combine
import Foundation

protocol EventStream: Sendable {
    func publish(_ event: ExecutionEvent)
    func subscribe(_ filter: EventStreamFilter) -> AnyPublisher<ExecutionEvent, Never>
    func replay(_ range: EventReplayRange) -> [ExecutionEvent]
    func persist(_ event: ExecutionEvent)
}

struct EventStreamFilter: Equatable, Sendable {
    var workspaceID: UUID?
    var taskID: UUID?
    var eventTypes: Set<EventType>?
    var minimumSequence: Int64?
    var maximumSequence: Int64?

    init(
        workspaceID: UUID? = nil,
        taskID: UUID? = nil,
        eventTypes: Set<EventType>? = nil,
        minimumSequence: Int64? = nil,
        maximumSequence: Int64? = nil
    ) {
        self.workspaceID = workspaceID
        self.taskID = taskID
        self.eventTypes = eventTypes
        self.minimumSequence = minimumSequence
        self.maximumSequence = maximumSequence
    }

    func matches(_ event: ExecutionEvent) -> Bool {
        if let workspaceID, event.workspaceID != workspaceID {
            return false
        }
        if let taskID, event.taskID != taskID {
            return false
        }
        if let eventTypes, !eventTypes.contains(event.type) {
            return false
        }
        if let minimumSequence, event.sequence < minimumSequence {
            return false
        }
        if let maximumSequence, event.sequence > maximumSequence {
            return false
        }
        return true
    }
}

struct EventReplayRange: Equatable, Sendable {
    var filter: EventStreamFilter

    init(filter: EventStreamFilter = EventStreamFilter()) {
        self.filter = filter
    }

    static func workspace(
        _ workspaceID: UUID,
        minimumSequence: Int64? = nil,
        maximumSequence: Int64? = nil
    ) -> EventReplayRange {
        EventReplayRange(
            filter: EventStreamFilter(
                workspaceID: workspaceID,
                minimumSequence: minimumSequence,
                maximumSequence: maximumSequence
            )
        )
    }

    static func task(
        workspaceID: UUID,
        taskID: UUID,
        minimumSequence: Int64? = nil,
        maximumSequence: Int64? = nil
    ) -> EventReplayRange {
        EventReplayRange(
            filter: EventStreamFilter(
                workspaceID: workspaceID,
                taskID: taskID,
                minimumSequence: minimumSequence,
                maximumSequence: maximumSequence
            )
        )
    }

    func contains(_ event: ExecutionEvent) -> Bool {
        filter.matches(event)
    }
}

protocol RemoteEventSink: Sendable {
    func enqueue(_ event: ExecutionEvent)
}

struct NoOpRemoteEventSink: RemoteEventSink {
    func enqueue(_ event: ExecutionEvent) {}
}

struct CloudEventIngestionPoint: Equatable, Sendable {
    enum State: String, Sendable {
        case disabled
    }

    var state: State = .disabled
    var remoteSink: any RemoteEventSink = NoOpRemoteEventSink()

    static let disabled = CloudEventIngestionPoint()
}

extension CloudEventIngestionPoint {
    static func == (lhs: CloudEventIngestionPoint, rhs: CloudEventIngestionPoint) -> Bool {
        lhs.state == rhs.state
    }
}

struct EventStreamNodeRegistration: Identifiable, Equatable, Sendable {
    let id: String
    var workspaceID: UUID?
    var registeredAt: Date
    var metadata: [String: String]

    static func placeholder(workspaceID: UUID? = nil) -> EventStreamNodeRegistration {
        EventStreamNodeRegistration(
            id: "local-node-placeholder",
            workspaceID: workspaceID,
            registeredAt: Date(timeIntervalSince1970: 0),
            metadata: ["mode": "offline"]
        )
    }
}

protocol EventStreamNodeRegistry: Sendable {
    func register(_ node: EventStreamNodeRegistration)
}

struct NoOpEventStreamNodeRegistry: EventStreamNodeRegistry {
    func register(_ node: EventStreamNodeRegistration) {}
}

final class InMemoryEventStream: EventStream, @unchecked Sendable {
    private let bus: RuntimeEventBus
    private let ingestionPoint: CloudEventIngestionPoint
    private let nodeRegistry: any EventStreamNodeRegistry
    private let bufferLimit: Int?
    private let lock = NSLock()
    private var buffer: [ExecutionEvent] = []

    init(
        eventBus: RuntimeEventBus = RuntimeEventBus(),
        bufferLimit: Int? = nil,
        ingestionPoint: CloudEventIngestionPoint = .disabled,
        nodeRegistry: any EventStreamNodeRegistry = NoOpEventStreamNodeRegistry(),
        nodeRegistration: EventStreamNodeRegistration = .placeholder()
    ) {
        self.bus = eventBus
        self.bufferLimit = bufferLimit
        self.ingestionPoint = ingestionPoint
        self.nodeRegistry = nodeRegistry
        self.nodeRegistry.register(nodeRegistration)
    }

    func publish(_ event: ExecutionEvent) {
        bus.publish(event)
    }

    func subscribe(_ filter: EventStreamFilter) -> AnyPublisher<ExecutionEvent, Never> {
        bus.subscribe(filter)
    }

    func replay(_ range: EventReplayRange) -> [ExecutionEvent] {
        lock.withLock {
            buffer
                .filter { range.contains($0) }
                .sorted { lhs, rhs in
                    if lhs.sequence == rhs.sequence {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.sequence < rhs.sequence
                }
        }
    }

    func persist(_ event: ExecutionEvent) {
        lock.withLock {
            buffer.append(event)
            if let bufferLimit, buffer.count > bufferLimit {
                buffer.removeFirst(buffer.count - bufferLimit)
            }
        }
        switch ingestionPoint.state {
        case .disabled:
            break
        }
    }
}
