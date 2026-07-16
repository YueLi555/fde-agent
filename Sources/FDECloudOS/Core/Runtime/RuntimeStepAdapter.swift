import Foundation

enum RuntimeStepDirective: Equatable, Sendable {
    case `continue`
    case waitForUser(reason: String)
    case changeApproach(instruction: String)
    case stop(reason: String)
}

enum RuntimeStepPhase: String, Codable, Equatable, Sendable {
    case beforeStep = "before_step"
    case afterStep = "after_step"
}

struct RuntimeStepCheckpoint: Equatable, Sendable {
    var workspaceID: UUID
    var taskID: UUID
    var stepID: String
    var stepIndex: Int
    var stepTitle: String
    var toolCallID: String?
    var command: String?
    var phase: RuntimeStepPhase
}

actor RuntimeStepControlCenter {
    private var pendingDirectives: [UUID: RuntimeStepDirective] = [:]
    private var resumeContinuations: [UUID: CheckedContinuation<RuntimeStepDirective, Never>] = [:]
    private var nextCheckpointDirective: RuntimeStepDirective?

    func requestPauseAtNextCheckpoint(reason: String) {
        nextCheckpointDirective = .waitForUser(reason: reason)
    }

    func requestPause(taskID: UUID, reason: String) {
        pendingDirectives[taskID] = .waitForUser(reason: reason)
    }

    func resume(taskID: UUID, instruction: String? = nil) {
        let directive = RuntimeStepDirective.continue
        if let continuation = resumeContinuations.removeValue(forKey: taskID) {
            continuation.resume(returning: directive)
        } else {
            pendingDirectives.removeValue(forKey: taskID)
        }
    }

    func changeApproach(taskID: UUID, instruction: String) {
        let directive = RuntimeStepDirective.changeApproach(instruction: instruction)
        if let continuation = resumeContinuations.removeValue(forKey: taskID) {
            continuation.resume(returning: directive)
        } else {
            pendingDirectives[taskID] = directive
        }
    }

    func stop(taskID: UUID, reason: String) {
        let directive = RuntimeStepDirective.stop(reason: reason)
        if let continuation = resumeContinuations.removeValue(forKey: taskID) {
            continuation.resume(returning: directive)
        } else {
            pendingDirectives[taskID] = directive
        }
    }

    func directive(for checkpoint: RuntimeStepCheckpoint) -> RuntimeStepDirective {
        if let directive = pendingDirectives.removeValue(forKey: checkpoint.taskID) {
            return directive
        }
        if let directive = nextCheckpointDirective {
            nextCheckpointDirective = nil
            return directive
        }
        return .continue
    }

    func waitForResume(taskID: UUID) async -> RuntimeStepDirective {
        if let directive = pendingDirectives.removeValue(forKey: taskID) {
            if case .waitForUser = directive {
                return await waitForResume(taskID: taskID)
            }
            return directive
        }

        return await withCheckedContinuation { continuation in
            resumeContinuations[taskID] = continuation
        }
    }
}

struct RuntimeStepAdapter: Sendable {
    let controlCenter: RuntimeStepControlCenter

    init(controlCenter: RuntimeStepControlCenter = RuntimeStepControlCenter()) {
        self.controlCenter = controlCenter
    }

    func directive(for checkpoint: RuntimeStepCheckpoint) async -> RuntimeStepDirective {
        await controlCenter.directive(for: checkpoint)
    }

    func waitForResume(taskID: UUID) async -> RuntimeStepDirective {
        await controlCenter.waitForResume(taskID: taskID)
    }

    func requestPause(taskID: UUID, reason: String) async {
        await controlCenter.requestPause(taskID: taskID, reason: reason)
    }

    func requestPauseAtNextCheckpoint(reason: String) async {
        await controlCenter.requestPauseAtNextCheckpoint(reason: reason)
    }

    func resume(taskID: UUID, instruction: String? = nil) async {
        await controlCenter.resume(taskID: taskID, instruction: instruction)
    }

    func changeApproach(taskID: UUID, instruction: String) async {
        await controlCenter.changeApproach(taskID: taskID, instruction: instruction)
    }

    func stop(taskID: UUID, reason: String) async {
        await controlCenter.stop(taskID: taskID, reason: reason)
    }
}
