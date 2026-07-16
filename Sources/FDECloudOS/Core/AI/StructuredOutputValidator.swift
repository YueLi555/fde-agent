import Foundation

enum StructuredOutputError: LocalizedError, Equatable {
    case emptyPlan
    case invalidConfidence
    case invalidRetryBudget(String)
    case duplicateToolCall(String)
    case duplicatePlanStep(String)

    var errorDescription: String? {
        switch self {
        case .emptyPlan:
            return "Planner output must include at least one plan step."
        case .invalidConfidence:
            return "Planner confidence must be between 0 and 1."
        case .invalidRetryBudget(let id):
            return "Plan step has invalid retry budget: \(id)"
        case .duplicateToolCall(let id):
            return "Duplicate tool call id: \(id)"
        case .duplicatePlanStep(let id):
            return "Duplicate plan step id: \(id)"
        }
    }
}

protocol StructuredOutputValidating: Sendable {
    func validate(_ output: StructuredAgentOutput) throws
}

struct StructuredOutputValidator: StructuredOutputValidating {
    func validate(_ output: StructuredAgentOutput) throws {
        guard !output.plan.isEmpty else {
            throw StructuredOutputError.emptyPlan
        }
        guard (0...1).contains(output.confidence) else {
            throw StructuredOutputError.invalidConfidence
        }

        var seenSteps: Set<String> = []
        for step in output.plan {
            guard seenSteps.insert(step.id).inserted else {
                throw StructuredOutputError.duplicatePlanStep(step.id)
            }
            guard step.retryBudget >= 0 else {
                throw StructuredOutputError.invalidRetryBudget(step.id)
            }
        }

        _ = try JSONCoding.encode(output)
    }
}
