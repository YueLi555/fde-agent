import Foundation

enum AssessmentClaimConfidence: String, Codable, CaseIterable, Hashable, Sendable {
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
    case unknown = "UNKNOWN"
}

enum AssessmentEvidenceSource: String, Codable, Hashable, Sendable {
    case inspectedFile = "INSPECTED_FILE"
    case staticSearch = "STATIC_SEARCH"
    case extractedConfiguration = "EXTRACTED_CONFIGURATION"
    case evidenceLedger = "EVIDENCE_LEDGER"
    case userIntent = "USER_INTENT"
}

enum AssessmentEvidenceObservationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case directlyRead = "DIRECTLY_READ"
    case referenced = "REFERENCED"
    case discovered = "DISCOVERED"
    case userProvided = "USER_PROVIDED"
}

struct AssessmentVerificationStatus: Codable, Hashable, Sendable {
    var runtime: ReadOnlyEngineeringClaimLevel
    var build: ReadOnlyEngineeringClaimLevel
    var test: ReadOnlyEngineeringClaimLevel

    static let staticOnly = AssessmentVerificationStatus(
        runtime: .runtimeNotVerified,
        build: .buildNotExecuted,
        test: .testNotExecuted
    )
}

struct AssessmentEvidenceReference: Codable, Hashable, Sendable, Identifiable {
    var source: AssessmentEvidenceSource
    var workspaceIdentity: String?
    var path: String
    var fact: String
    var claimLevel: ReadOnlyEngineeringClaimLevel?
    var observationStatus: AssessmentEvidenceObservationStatus
    var sourceComponent: String
    var safeEvidenceSummary: String
    var lineRange: String?
    var fileHash: String?
    var workspaceSnapshotIdentifier: String?
    var relatedToolEventID: UUID?

    var id: String { "\(source.rawValue):\(workspaceIdentity ?? "request"):\(path):\(fact)" }

    init(
        source: AssessmentEvidenceSource,
        workspaceIdentity: String? = nil,
        path: String,
        fact: String,
        claimLevel: ReadOnlyEngineeringClaimLevel?,
        observationStatus: AssessmentEvidenceObservationStatus? = nil,
        sourceComponent: String? = nil,
        safeEvidenceSummary: String? = nil,
        lineRange: String? = nil,
        fileHash: String? = nil,
        workspaceSnapshotIdentifier: String? = nil,
        relatedToolEventID: UUID? = nil
    ) {
        self.source = source
        self.workspaceIdentity = workspaceIdentity
        self.path = path
        self.fact = fact
        self.claimLevel = claimLevel
        self.observationStatus = observationStatus ?? Self.defaultObservationStatus(source: source, claimLevel: claimLevel)
        self.sourceComponent = sourceComponent ?? Self.component(for: path)
        self.safeEvidenceSummary = safeEvidenceSummary ?? fact
        self.lineRange = lineRange
        self.fileHash = fileHash
        self.workspaceSnapshotIdentifier = workspaceSnapshotIdentifier
        self.relatedToolEventID = relatedToolEventID
    }

    static func userIntent(_ fact: String) -> AssessmentEvidenceReference {
        AssessmentEvidenceReference(
            source: .userIntent,
            path: "user-intent://desired-agent-capability",
            fact: fact,
            claimLevel: nil,
            observationStatus: .userProvided,
            sourceComponent: "requested-capability"
        )
    }

    private static func defaultObservationStatus(
        source: AssessmentEvidenceSource,
        claimLevel: ReadOnlyEngineeringClaimLevel?
    ) -> AssessmentEvidenceObservationStatus {
        if source == .userIntent { return .userProvided }
        if claimLevel == .referencedButNotRead { return .referenced }
        if claimLevel == .contentRead
            || claimLevel == .configurationConfirmed
            || claimLevel == .sourceBehaviorConfirmed {
            return .directlyRead
        }
        return .discovered
    }

    private static func component(for path: String) -> String {
        guard !path.contains("://") else { return "request" }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.first.map(String.init) ?? "workspace-root"
    }
}

struct AssessmentClaim: Codable, Hashable, Sendable, Identifiable {
    var claimID: String
    var statement: String
    var evidence: [AssessmentEvidenceReference]
    var confidence: AssessmentClaimConfidence
    var unknowns: [String]
    var verificationStatus: AssessmentVerificationStatus

    var id: String { claimID }

    init(
        claimID: String? = nil,
        statement: String,
        evidence: [AssessmentEvidenceReference],
        confidence: AssessmentClaimConfidence,
        unknowns: [String],
        verificationStatus: AssessmentVerificationStatus = .staticOnly
    ) {
        self.claimID = claimID ?? Self.stableClaimID(statement)
        self.statement = statement
        self.evidence = evidence
        self.confidence = confidence
        self.unknowns = unknowns
        self.verificationStatus = verificationStatus
    }

    private static func stableClaimID(_ statement: String) -> String {
        let slug = statement.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let normalized = String(slug)
            .split(separator: "-", omittingEmptySubsequences: true)
            .prefix(10)
            .joined(separator: "-")
        return "claim-\(normalized.isEmpty ? "assessment" : normalized)"
    }
}

/// An immutable, validated link from one assessment claim reference to the
/// successful Phase 3B.2B tool result and ledger record that support it.
struct AssessmentClaimEvidenceBinding: Codable, Hashable, Sendable, Identifiable {
    let claimID: String
    let evidenceReferenceID: String
    let toolCallID: String
    let toolResultEventID: UUID
    let workspaceID: UUID
    let workspaceIdentity: String
    let relativePath: String
    let claimLevel: ReadOnlyEngineeringClaimLevel
    let observationStatus: AssessmentEvidenceObservationStatus
    let sourceOutputSHA256: String
    let extractedFactKinds: [String]

    var id: String { "\(claimID):\(evidenceReferenceID):\(toolResultEventID.uuidString.lowercased())" }
}
