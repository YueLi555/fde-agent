import Combine
import Foundation

final class RuntimeEventBus: @unchecked Sendable {
    private let subject = PassthroughSubject<ExecutionEvent, Never>()

    var publisher: AnyPublisher<ExecutionEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    func subscribe(_ filter: EventStreamFilter = EventStreamFilter()) -> AnyPublisher<ExecutionEvent, Never> {
        publisher
            .filter { filter.matches($0) }
            .eraseToAnyPublisher()
    }

    func publish(_ event: ExecutionEvent) {
        subject.send(event)
    }
}
