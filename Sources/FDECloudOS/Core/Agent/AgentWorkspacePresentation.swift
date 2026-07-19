import Foundation

enum ConversationTitleGenerator {
    static let emptyConversationTitle = "New conversation"

    static func title(for request: String, maximumLength: Int = 58) -> String {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !normalized.isEmpty else { return emptyConversationTitle }

        let firstSentence = normalized
            .split(whereSeparator: { ".!?\n".contains($0) })
            .first
            .map(String.init) ?? normalized
        let words = firstSentence.split(separator: " ")
        var result = ""
        for word in words {
            let candidate = result.isEmpty ? String(word) : "\(result) \(word)"
            guard candidate.count <= maximumLength else { break }
            result = candidate
        }
        if result.isEmpty {
            result = String(firstSentence.prefix(maximumLength))
        }
        if result.count < firstSentence.count || firstSentence.count < normalized.count {
            return result.trimmingCharacters(in: .punctuationCharacters) + "…"
        }
        return result
    }
}

extension AgentSession {
    static func newConversation(in workspace: Workspace, createdAt: Date = Date()) -> AgentSession {
        let sessionID = UUID()
        return AgentSession(
            sessionID: sessionID,
            workspaceID: workspace.id,
            userGoal: ConversationTitleGenerator.emptyConversationTitle,
            createdAt: createdAt,
            currentState: .idle,
            interactionState: .idle,
            planApprovalStatus: .pending,
            conversation: AgentConversation(
                sessionID: sessionID,
                workspaceID: workspace.id,
                messages: [],
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            workspaceContext: AgentWorkspaceContext(workspace: workspace)
        )
    }

    var isEmptyConversation: Bool {
        runtimeTaskID == nil && conversation.messages.isEmpty
    }

    var displayTitle: String {
        if let firstRequest = conversation.messages.first(where: { $0.sender == .user })?.content {
            return ConversationTitleGenerator.title(for: firstRequest)
        }
        guard userGoal != ConversationTitleGenerator.emptyConversationTitle else {
            return ConversationTitleGenerator.emptyConversationTitle
        }
        return ConversationTitleGenerator.title(for: userGoal)
    }

    mutating func beginConversation(with request: String, timestamp: Date = Date()) {
        guard isEmptyConversation else {
            appendUserMessage(request, timestamp: timestamp)
            return
        }
        userGoal = request.trimmingCharacters(in: .whitespacesAndNewlines)
        currentState = .understanding
        interactionState = .understanding
        appendUserMessage(request, timestamp: timestamp)
    }
}

enum StructuredAgentResponseStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case working = "Working"
    case needsInput = "Needs input"
    case warning = "Warning"
    case completed = "Completed"
    case informational = "Informational"
}

enum StructuredAgentSectionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case summary = "Summary"
    case workCompleted = "Work completed"
    case filesChanged = "Files changed"
    case validation = "Validation"
    case risksAndBlockers = "Risks / blockers"
    case nextAction = "Next action"
}

struct StructuredAgentSection: Identifiable, Codable, Hashable, Sendable {
    var kind: StructuredAgentSectionKind
    var content: String

    var id: StructuredAgentSectionKind { kind }
}

struct StructuredAgentResponse: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var status: StructuredAgentResponseStatus
    var summary: String
    var sections: [StructuredAgentSection]
    var artifactReferences: [String]
    var warnings: [String]
    var nextAction: String?
    var evidenceSummary: String?

    init(
        id: UUID = UUID(),
        title: String,
        status: StructuredAgentResponseStatus,
        summary: String,
        sections: [StructuredAgentSection] = [],
        artifactReferences: [String] = [],
        warnings: [String] = [],
        nextAction: String? = nil,
        evidenceSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.sections = sections
        self.artifactReferences = artifactReferences
        self.warnings = warnings
        self.nextAction = nextAction
        self.evidenceSummary = evidenceSummary
    }
}

enum StructuredAgentResponseProjector {
    static func response(for message: AgentMessage) -> StructuredAgentResponse {
        let safeContent = normalizedPresentationText(message.content)
        let status: StructuredAgentResponseStatus
        switch message.type {
        case .warning:
            status = .warning
        case .question, .decisionRequest, .approvalRequest:
            status = .needsInput
        case .progressUpdate, .planUpdate, .actionUpdate, .agentStatus:
            status = .working
        case .result, .artifact:
            status = .completed
        default:
            status = .informational
        }

        var sections: [StructuredAgentSection] = [
            StructuredAgentSection(kind: .summary, content: safeContent)
        ]
        if message.type == .result || message.type == .artifact {
            sections.append(StructuredAgentSection(
                kind: .workCompleted,
                content: message.type == .artifact
                    ? "A reviewable artifact is available in this conversation."
                    : "The requested work reached a stable reported outcome."
            ))
        }
        if message.type == .warning {
            sections.append(StructuredAgentSection(kind: .risksAndBlockers, content: safeContent))
        }
        if message.type == .question || message.type == .decisionRequest || message.type == .approvalRequest {
            sections.append(StructuredAgentSection(
                kind: .nextAction,
                content: "Review the request and respond using the available controls."
            ))
        }

        return StructuredAgentResponse(
            id: message.id,
            title: title(for: message.type),
            status: status,
            summary: safeContent,
            sections: sections,
            artifactReferences: message.relatedArtifactID == nil ? [] : ["Attached artifact"],
            warnings: message.type == .warning ? [safeContent] : [],
            nextAction: sections.first(where: { $0.kind == .nextAction })?.content,
            evidenceSummary: message.type == .evidence ? safeContent : nil
        )
    }

    static func normalizedPresentationText(_ input: String) -> String {
        var filteredLines: [String] = []
        var isSkippingDiffFence = false
        var isSkippingRawDiff = false
        var insertedDiffReference = false

        for line in input.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if isSkippingDiffFence {
                if trimmed == "```" {
                    isSkippingDiffFence = false
                }
                continue
            }

            if isSkippingRawDiff {
                if trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
                    isSkippingRawDiff = false
                } else {
                    continue
                }
            }

            if lower.hasPrefix("```diff") {
                appendDiffReferenceIfNeeded(to: &filteredLines, inserted: &insertedDiffReference)
                isSkippingDiffFence = true
                continue
            }

            if lower.contains("unified diff:") {
                appendDiffReferenceIfNeeded(to: &filteredLines, inserted: &insertedDiffReference)
                continue
            }

            if lower.hasPrefix("diff --git ") || trimmed.hasPrefix("--- ") {
                appendDiffReferenceIfNeeded(to: &filteredLines, inserted: &insertedDiffReference)
                isSkippingRawDiff = true
                continue
            }

            if [
                "chain_of_thought", "private reasoning", "session_id", "manifest_id",
                "canonical_json", "raw runtime log", "stdout:", "stderr:"
            ].contains(where: lower.contains) {
                continue
            }

            filteredLines.append(line)
        }

        let filtered = filteredLines.joined(separator: "\n")
        let withoutCompleteHashes = filtered.replacingOccurrences(
            of: #"\b[0-9a-fA-F]{64}\b"#,
            with: "[binding available in Evidence]",
            options: .regularExpression
        )
        return AgentPresentationSanitizer.safeMarkdownContent(
            withoutCompleteHashes,
            fallback: "The agent returned a safe status update."
        )
    }

    private static func appendDiffReferenceIfNeeded(
        to lines: inout [String],
        inserted: inout Bool
    ) {
        guard !inserted else { return }
        lines.append("Unified diff: Open the validated file card to review it in the app-owned viewer.")
        inserted = true
    }

    private static func title(for type: AgentMessageType) -> String {
        switch type {
        case .text: return "Agent response"
        case .progressUpdate, .actionUpdate, .agentStatus: return "Work update"
        case .planUpdate: return "Plan update"
        case .question: return "Question"
        case .decisionRequest, .approvalRequest: return "Review requested"
        case .warning: return "Attention needed"
        case .artifact: return "Artifact ready"
        case .result: return "Result"
        case .observation: return "Observation"
        case .decision: return "Decision recorded"
        case .evidence: return "Evidence summary"
        case .userRequest: return "Request"
        }
    }
}

enum HumanReviewDecision: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case approve = "Approve"
    case requestChanges = "Request changes"
    case reject = "Reject"

    var id: String { rawValue }
}

enum HumanActionDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case controlledEvalResult = "Controlled Eval result review"
    case controlledEvalExecution = "Controlled Eval execution authorization"
    case productionReadiness = "Production Readiness review"
    case aiEvalPlan = "AI Eval Plan review"
    case generatedTest = "Generated Test review"
    case candidatePatch = "Candidate Patch review"
    case genericApproval = "Approval review"
    case undo = "Undo confirmation"

    var priority: Int {
        switch self {
        case .controlledEvalResult: return 800
        case .controlledEvalExecution: return 700
        case .productionReadiness: return 600
        case .aiEvalPlan: return 590
        case .generatedTest: return 500
        case .candidatePatch: return 400
        case .genericApproval: return 300
        case .undo: return 100
        }
    }
}

struct HumanActionDescriptor: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var domain: HumanActionDomain
    var title: String
    var scope: String
    var revision: Int?
    var status: String
    var decisions: [HumanReviewDecision]
    var isEligible: Bool
    var isInFlight: Bool
    var isFinalized: Bool

    var isReadOnly: Bool { isFinalized }

    func canSubmit(decision: HumanReviewDecision?, note: String) -> Bool {
        guard isEligible, !isInFlight, !isFinalized,
              let decision, decisions.contains(decision) else {
            return false
        }
        if decision == .requestChanges {
            return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}

enum HumanActionBarProjector {
    static func highestPriority(in actions: [HumanActionDescriptor]) -> HumanActionDescriptor? {
        actions
            .filter { $0.isEligible || $0.isFinalized }
            .sorted { lhs, rhs in
                if lhs.domain.priority == rhs.domain.priority { return lhs.id < rhs.id }
                return lhs.domain.priority > rhs.domain.priority
            }
            .first
    }
}

enum HumanActionUIOperation: String, CaseIterable, Sendable {
    case accessibilityEnumeration
    case windowFocus
    case screenshotCapture
    case scrolling
    case selectDecision
    case editNote
    case submitDecision

    var emitsMutation: Bool { self == .submitDecision }
}

enum ComposerKeyAction: Equatable, Sendable {
    case submit
    case insertNewline
    case ignore
}

enum ComposerSubmissionPolicy {
    static func action(
        text: String,
        shiftPressed: Bool,
        hasMarkedText: Bool
    ) -> ComposerKeyAction {
        if hasMarkedText { return .ignore }
        if shiftPressed { return .insertNewline }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .ignore : .submit
    }
}

enum AutoGrowingComposerMetrics {
    static let minimumVisibleLines = 1
    static let maximumVisibleLines = 8

    static func visibleLineCount(for logicalLineCount: Int) -> Int {
        min(max(logicalLineCount, minimumVisibleLines), maximumVisibleLines)
    }

    static func shouldScrollInternally(for logicalLineCount: Int) -> Bool {
        logicalLineCount > maximumVisibleLines
    }
}

enum ArtifactFileStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case added = "Added"
    case modified = "Modified"
    case deleted = "Deleted"
    case virtual = "Virtual"
}

enum ArtifactSafeSource: String, Codable, CaseIterable, Hashable, Sendable {
    case legacyReadOnly = "Legacy read-only"
    case safeSandbox = "Safe Sandbox"
    case virtualArtifact = "Virtual artifact"

    var isReadOnly: Bool { self == .legacyReadOnly || self == .virtualArtifact }
}

struct ArtifactMetadataItem: Identifiable, Codable, Hashable, Sendable {
    var label: String
    var value: String

    var id: String { "\(label):\(value)" }
}

struct ArtifactFileCardModel: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var relativePath: String
    var status: ArtifactFileStatus
    var language: String
    var additions: Int?
    var deletions: Int?
    var purpose: String
    var safeSource: ArtifactSafeSource
    var content: String
    var unifiedDiff: String?
    var metadata: [ArtifactMetadataItem]
    var evidence: [String]
    var exactBinding: [ArtifactMetadataItem]

    var expandsLargeDiffInlineByDefault: Bool { false }
}

enum ArtifactPathAuthority {
    static func isValidatedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            component != "." && component != ".." && !component.isEmpty
        }
    }
}

enum ArtifactFileCardProjector {
    static func cards(
        candidateManifest: CandidatePatchManifest?,
        generatedTestArtifact: GeneratedTestArtifact?
    ) -> [ArtifactFileCardModel] {
        var cards: [ArtifactFileCardModel] = []
        if let manifest = candidateManifest {
            for operation in manifest.operations
            where ArtifactPathAuthority.isValidatedRelativePath(operation.relativeCanonicalSandboxPath) {
                cards.append(ArtifactFileCardModel(
                    id: "candidate:\(manifest.stableManifestID):\(operation.operationID)",
                    relativePath: operation.relativeCanonicalSandboxPath,
                    status: operation.operationType == .createTextFile ? .added : .modified,
                    language: language(for: operation.relativeCanonicalSandboxPath),
                    additions: manifest.additions,
                    deletions: manifest.deletions,
                    purpose: operation.purpose,
                    safeSource: .safeSandbox,
                    content: operation.proposedContent,
                    unifiedDiff: manifest.unifiedDiff,
                    metadata: [
                        ArtifactMetadataItem(label: "Risk", value: operation.risk.rawValue),
                        ArtifactMetadataItem(label: "Impact", value: operation.impact),
                        ArtifactMetadataItem(label: "Source integrity", value: manifest.sourceIntegrity.rawValue)
                    ],
                    evidence: operation.evidenceClaimIDs,
                    exactBinding: [
                        ArtifactMetadataItem(label: "Patch", value: manifest.patchID.rawValue),
                        ArtifactMetadataItem(label: "Sandbox", value: manifest.sandboxID.rawValue),
                        ArtifactMetadataItem(label: "Source snapshot", value: manifest.sourceSnapshotID),
                        ArtifactMetadataItem(label: "Resulting SHA-256", value: operation.resultingSHA256 ?? "Not materialized")
                    ]
                ))
            }
        }

        if let revision = generatedTestArtifact?.currentRevision {
            for file in revision.virtualFiles
            where ArtifactPathAuthority.isValidatedRelativePath(file.proposedRelativePath) {
                cards.append(ArtifactFileCardModel(
                    id: "virtual:\(revision.id):\(file.stableID)",
                    relativePath: file.proposedRelativePath,
                    status: .virtual,
                    language: file.language,
                    additions: file.lineCount,
                    deletions: 0,
                    purpose: "Generated test source for \(file.scenarioIDs.count) review scenario(s).",
                    safeSource: .virtualArtifact,
                    content: file.sourceText,
                    unifiedDiff: nil,
                    metadata: [
                        ArtifactMetadataItem(label: "Written", value: file.writtenStatus),
                        ArtifactMetadataItem(label: "Compiled", value: file.compiledStatus),
                        ArtifactMetadataItem(label: "Executed", value: file.executedStatus)
                    ],
                    evidence: file.evidencePaths,
                    exactBinding: [
                        ArtifactMetadataItem(label: "Artifact revision", value: String(revision.revision)),
                        ArtifactMetadataItem(label: "Source SHA-256", value: file.sourceSHA256),
                        ArtifactMetadataItem(label: "Candidate Patch binding", value: file.candidatePatchBindingSHA256)
                    ]
                ))
            }
        }
        return cards
    }

    private static func language(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "Swift"
        case "js": return "JavaScript"
        case "ts": return "TypeScript"
        case "tsx": return "TSX"
        case "jsx": return "JSX"
        case "py": return "Python"
        case "json": return "JSON"
        case "yml", "yaml": return "YAML"
        case "md": return "Markdown"
        default: return "Text"
        }
    }
}

struct AgentWorkspacePersistedUIState: Codable, Hashable, Sendable {
    var sessions: [AgentSession]
    var selectedSessionID: UUID?
    var drafts: [UUID: String]
    var isInspectorPresented: Bool

    static let empty = AgentWorkspacePersistedUIState(
        sessions: [],
        selectedSessionID: nil,
        drafts: [:],
        isInspectorPresented: false
    )
}

@MainActor
final class AgentWorkspaceUIStateStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "fde.agent.workspace.ui-state.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AgentWorkspacePersistedUIState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(AgentWorkspacePersistedUIState.self, from: data) else {
            return .empty
        }
        return state
    }

    func save(_ state: AgentWorkspacePersistedUIState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
