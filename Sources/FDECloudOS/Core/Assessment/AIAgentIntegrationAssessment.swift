import CryptoKit
import Foundation

enum AIIntegrationAssessmentLayer {
    static let id = "AI_INTEGRATION_ASSESSMENT_LAYER"
}

enum AIAgentCapabilityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case unspecified = "unspecified_ai_agent"
    case customerSupport = "customer_support_agent"
    case sales = "sales_agent"
    case workflowAutomation = "workflow_automation_agent"
    case dataAnalysis = "data_analysis_agent"
    case internalKnowledge = "internal_knowledge_agent"
    case developerAssistant = "developer_assistant"

    var displayName: String {
        switch self {
        case .unspecified: return "Unspecified AI Agent"
        case .customerSupport: return "Customer Support Agent"
        case .sales: return "Sales Agent"
        case .workflowAutomation: return "Workflow Automation Agent"
        case .dataAnalysis: return "Data Analysis Agent"
        case .internalKnowledge: return "Internal Knowledge Agent"
        case .developerAssistant: return "Developer Assistant"
        }
    }

    init(request: String) {
        let value = request.lowercased()
        if Self.containsAny(value, ["customer support", "customer service", "support agent", "客服"]) {
            self = .customerSupport
        } else if Self.containsAny(value, ["sales", "crm", "销售"]) {
            self = .sales
        } else if Self.containsAny(value, ["workflow", "automation", "approval", "工作流", "自动化"]) {
            self = .workflowAutomation
        } else if Self.containsAny(value, ["data analysis", "analytics", "分析 agent", "数据分析"]) {
            self = .dataAnalysis
        } else if Self.containsAny(value, ["knowledge", "retrieval", "internal assistant", "知识", "内部助手"]) {
            self = .internalKnowledge
        } else if Self.containsAny(value, ["developer", "coding", "code assistant", "开发", "编程助手"]) {
            self = .developerAssistant
        } else {
            self = .unspecified
        }
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }
}

enum LegacyArchitectureCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case customerData = "customer_data"
    case orderData = "order_data"
    case customerHistory = "customer_history"
    case authenticationBoundary = "authentication_boundary"
    case permissionModel = "permission_model"
    case apiServiceLayer = "api_service_layer"
    case databaseAccess = "database_access"
    case knowledgeSource = "knowledge_source"
    case crmIntegration = "crm_integration"
    case communicationChannel = "communication_channel"
    case eventSystem = "event_system"
    case businessActionAPI = "business_action_api"
    case approvalMechanism = "approval_mechanism"
    case auditLogging = "audit_logging"
    case frontendSurface = "frontend_surface"
    case sourceCodeAccess = "source_code_access"

    var displayName: String {
        rawValue.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }
}

struct AgentCapabilityRequirement: Codable, Hashable, Sendable, Identifiable {
    var capability: LegacyArchitectureCapability
    var required: Bool
    var critical: Bool
    var rationale: String

    var id: String { capability.rawValue }
}

struct AgentCapabilityProfile: Codable, Hashable, Sendable {
    var kind: AIAgentCapabilityKind
    var requiredCapabilities: [AgentCapabilityRequirement]
    var proposesWriteAccess: Bool

    var name: String { kind.displayName }

    static func detect(from request: String) -> AgentCapabilityProfile {
        profile(for: AIAgentCapabilityKind(request: request))
    }

    static func profile(for kind: AIAgentCapabilityKind) -> AgentCapabilityProfile {
        func requirement(
            _ capability: LegacyArchitectureCapability,
            critical: Bool = true,
            _ rationale: String
        ) -> AgentCapabilityRequirement {
            AgentCapabilityRequirement(
                capability: capability,
                required: true,
                critical: critical,
                rationale: rationale
            )
        }

        switch kind {
        case .unspecified:
            return AgentCapabilityProfile(
                kind: kind,
                requiredCapabilities: [
                    requirement(.apiServiceLayer, "Mediate agent access through a stable service boundary."),
                    requirement(.authenticationBoundary, "Authenticate users and the agent identity."),
                    requirement(.permissionModel, "Authorize every data access and action."),
                    requirement(.auditLogging, critical: false, "Record sensitive access and actions.")
                ],
                proposesWriteAccess: false
            )
        case .customerSupport:
            return AgentCapabilityProfile(
                kind: kind,
                requiredCapabilities: [
                    requirement(.customerData, "Resolve customer context."),
                    requirement(.orderData, "Answer order questions."),
                    requirement(.authenticationBoundary, "Bind requests to an authenticated identity."),
                    requirement(.apiServiceLayer, "Mediate access without direct database connectivity."),
                    requirement(.knowledgeSource, critical: false, "Ground support answers in approved content."),
                    requirement(.permissionModel, "Limit each user and agent to permitted records.")
                ],
                proposesWriteAccess: false
            )
        case .sales:
            return AgentCapabilityProfile(
                kind: kind,
                requiredCapabilities: [
                    requirement(.customerHistory, "Provide relevant account history."),
                    requirement(.crmIntegration, critical: false, "Coordinate with the system of record."),
                    requirement(.communicationChannel, critical: false, "Deliver approved outreach."),
                    requirement(.eventSystem, critical: false, "Track engagement events."),
                    requirement(.authenticationBoundary, "Authenticate users and service identities."),
                    requirement(.permissionModel, "Enforce account-level access."),
                    requirement(.approvalMechanism, "Require human approval before outreach or CRM mutation.")
                ],
                proposesWriteAccess: true
            )
        case .workflowAutomation:
            return AgentCapabilityProfile(
                kind: kind,
                requiredCapabilities: [
                    requirement(.businessActionAPI, "Expose bounded business actions."),
                    requirement(.approvalMechanism, "Gate consequential actions."),
                    requirement(.auditLogging, "Record decisions and actions."),
                    requirement(.authenticationBoundary, "Authenticate the agent identity."),
                    requirement(.permissionModel, "Authorize every action.")
                ],
                proposesWriteAccess: true
            )
        case .dataAnalysis:
            return AgentCapabilityProfile(
                kind: kind,
                requiredCapabilities: [
                    requirement(.databaseAccess, "Provide governed analytical data."),
                    requirement(.apiServiceLayer, "Expose stable read contracts."),
                    requirement(.authenticationBoundary, "Authenticate analytical requests."),
                    requirement(.permissionModel, "Restrict sensitive datasets."),
                    requirement(.auditLogging, critical: false, "Record data access.")
                ],
                proposesWriteAccess: false
            )
        case .internalKnowledge:
            return AgentCapabilityProfile(
                kind: kind,
                requiredCapabilities: [
                    requirement(.knowledgeSource, "Provide an approved grounding corpus."),
                    requirement(.apiServiceLayer, critical: false, "Expose retrieval through a stable boundary."),
                    requirement(.authenticationBoundary, "Authenticate employees."),
                    requirement(.permissionModel, "Filter content by entitlement."),
                    requirement(.auditLogging, critical: false, "Record sensitive retrieval.")
                ],
                proposesWriteAccess: false
            )
        case .developerAssistant:
            return AgentCapabilityProfile(
                kind: kind,
                requiredCapabilities: [
                    requirement(.sourceCodeAccess, "Read the selected code scope."),
                    requirement(.authenticationBoundary, "Authenticate developers."),
                    requirement(.permissionModel, "Respect repository permissions."),
                    requirement(.auditLogging, critical: false, "Record assistant access."),
                    requirement(.approvalMechanism, critical: false, "Review any proposed change.")
                ],
                proposesWriteAccess: false
            )
        }
    }
}

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

    var id: String { "\(source.rawValue):\(path):\(fact)" }

    init(
        source: AssessmentEvidenceSource,
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

struct LegacyArchitectureSignal: Codable, Hashable, Sendable {
    var capability: LegacyArchitectureCapability
    var evidence: AssessmentEvidenceReference
}

struct LegacyArchitectureAbsence: Codable, Hashable, Sendable {
    var capability: LegacyArchitectureCapability
    var reason: String
    var evidence: [AssessmentEvidenceReference]
}

struct LegacyArchitecture: Codable, Hashable, Sendable {
    var signals: [LegacyArchitectureSignal]
    var confirmedAbsences: [LegacyArchitectureAbsence]
    var inspectedPaths: [String]
    var evidenceRecords: [AssessmentEvidenceReference]

    init(
        signals: [LegacyArchitectureSignal] = [],
        confirmedAbsences: [LegacyArchitectureAbsence] = [],
        inspectedPaths: [String] = [],
        evidenceRecords: [AssessmentEvidenceReference] = []
    ) {
        let safeSignals = signals.filter { !ReadOnlySensitivePathPolicy.isSensitive($0.evidence.path) }
        self.signals = Self.uniqueSignals(safeSignals)
        self.confirmedAbsences = confirmedAbsences.map { absence in
            LegacyArchitectureAbsence(
                capability: absence.capability,
                reason: absence.reason,
                evidence: absence.evidence.filter { !ReadOnlySensitivePathPolicy.isSensitive($0.path) }
            )
        }
        self.inspectedPaths = Self.unique(inspectedPaths.filter { !ReadOnlySensitivePathPolicy.isSensitive($0) })
        self.evidenceRecords = Self.uniqueEvidence(evidenceRecords + safeSignals.map(\.evidence))
            .filter { !ReadOnlySensitivePathPolicy.isSensitive($0.path) }
    }

    init(
        ledger: ReadOnlyFinalizationEvidenceLedger,
        evidence: [ReadOnlyInspectionEvidence],
        confirmedAbsences: [LegacyArchitectureAbsence] = []
    ) {
        var derived: [LegacyArchitectureSignal] = []
        var derivedAbsences = confirmedAbsences
        var zeroResultSearches: [(query: String, evidence: AssessmentEvidenceReference)] = []
        let records = Dictionary(uniqueKeysWithValues: ledger.paths.map { ($0.relativePath, $0) })
        let provenanceRecords = evidence
            .filter { !ReadOnlySensitivePathPolicy.isSensitive($0.targetPath) }
            .map { Self.provenanceReference(for: $0, pathRecord: records[$0.targetPath]) }

        for item in evidence where item.toolName == "engineering.search_code" || item.toolName == "engineering.search_files" {
            guard let query = item.query?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty,
                  Self.isZeroResultSearch(item.output) else {
                continue
            }
            let reference = AssessmentEvidenceReference(
                source: .staticSearch,
                path: item.targetPath,
                fact: "Bounded static search for '\(query)' returned zero matches.",
                claimLevel: .discovered,
                observationStatus: .discovered,
                sourceComponent: Self.sourceComponent(for: item.targetPath),
                safeEvidenceSummary: "A bounded static search returned zero matches for the recorded query.",
                workspaceSnapshotIdentifier: Self.snapshotIdentifier(for: item.workspaceID),
                relatedToolEventID: item.toolResultEventID
            )
            zeroResultSearches.append((query.lowercased(), reference))
        }
        for (capability, requiredQueries) in Self.absenceSearchTerms {
            let matching = zeroResultSearches.filter { search in
                requiredQueries.contains(search.query)
            }
            let matchedQueries = Set(matching.map(\.query))
            if requiredQueries.allSatisfy(matchedQueries.contains) {
                derivedAbsences.append(
                    LegacyArchitectureAbsence(
                        capability: capability,
                        reason: "A bounded static inventory found no common \(capability.displayName) patterns.",
                        evidence: matching.map(\.evidence)
                    )
                )
            }
        }

        for item in evidence where item.toolName == "engineering.read_file" {
            let facts = item.structuredFacts
            let path = item.targetPath.lowercased()
            let content = item.output.lowercased()
            let pathExtension = URL(fileURLWithPath: path).pathExtension
            let isSourceFile = ["swift", "ts", "tsx", "js", "jsx", "py", "java", "kt", "go", "rs"].contains(pathExtension)
            let isDatabaseSchema = pathExtension == "sql"
                || URL(fileURLWithPath: path).lastPathComponent == "schema.prisma"
                || path.split(separator: "/").contains { ["database", "prisma", "migrations"].contains(String($0)) }
            let level = records[item.targetPath]?.claimLevels.contains(.sourceBehaviorConfirmed) == true
                ? ReadOnlyEngineeringClaimLevel.sourceBehaviorConfirmed
                : (records[item.targetPath]?.claimLevels.contains(.configurationConfirmed) == true
                    ? .configurationConfirmed
                    : .contentRead)
            let source: AssessmentEvidenceSource = level == .configurationConfirmed
                ? .extractedConfiguration
                : .inspectedFile

            func add(_ capability: LegacyArchitectureCapability, _ fact: String) {
                derived.append(
                    LegacyArchitectureSignal(
                        capability: capability,
                        evidence: AssessmentEvidenceReference(
                            source: source,
                            path: item.targetPath,
                            fact: fact,
                            claimLevel: level,
                            observationStatus: .directlyRead,
                            sourceComponent: Self.sourceComponent(for: item.targetPath),
                            safeEvidenceSummary: fact,
                            lineRange: Self.lineRange(for: item.output),
                            fileHash: Self.sha256(item.output),
                            workspaceSnapshotIdentifier: Self.snapshotIdentifier(for: item.workspaceID),
                            relatedToolEventID: item.toolResultEventID
                        )
                    )
                )
            }

            if !facts.databaseProviders.isEmpty || !facts.ormNames.isEmpty || isDatabaseSchema {
                add(.databaseAccess, "Database or ORM configuration is present.")
            }
            if !facts.frontendFrameworks.isEmpty || Self.containsAny(path, ["frontend/", "pages/"]) {
                add(.frontendSurface, "A frontend integration surface is present.")
            }
            if isSourceFile && (Self.containsAny(path, ["/routes/", "/controllers/", "/api/"])
                || facts.serverBootstrap
                || Self.containsAny(content, ["router.get", "router.post", "app.get(", "app.post(", "@getmapping", "@postmapping", "fastapi("])) {
                add(.apiServiceLayer, "A service or API boundary is present.")
            }
            if isSourceFile && Self.containsAny(path, ["auth", "session", "identity", "middleware"])
                && Self.containsAny(content, ["auth", "session", "jwt", "oauth", "principal", "identity"]) {
                add(.authenticationBoundary, "Authentication or identity handling is present.")
            }
            if isSourceFile && (Self.containsAny(content, ["permission", "authorize", "authorise", "rbac", "accesscontrol", "requiredrole", "canaccess"])
                || path.contains("permission")) {
                add(.permissionModel, "Authorization or permission checks are present.")
            }
            if Self.containsAny(content, ["auditlog", "audit_log", "audit trail", "audit event"])
                || path.contains("audit") {
                add(.auditLogging, "Audit logging is present.")
            }
            if Self.containsAny(content, ["approval", "approvedby", "requiresapproval", "human review"])
                || path.contains("approval") {
                add(.approvalMechanism, "An approval mechanism is present.")
            }
            if Self.containsAny(content, ["webhook", "eventbus", "event bus", "kafka", "rabbitmq", "sqs", "bullmq", "publish(", "subscribe("])
                || Self.containsAny(path, ["events/", "queue/", "webhooks/"]) {
                add(.eventSystem, "An event, queue, or webhook mechanism is present.")
            }
            if (isSourceFile || isDatabaseSchema) && (Self.containsAny(content, ["customer", "account holder", "client record"])
                || facts.modelNames.contains(where: { $0.lowercased().contains("customer") })) {
                add(.customerData, "Customer data structures are present.")
                add(.customerHistory, "Customer-related records are present.")
            }
            if (isSourceFile || isDatabaseSchema) && (content.contains("order")
                || facts.modelNames.contains(where: { $0.lowercased().contains("order") })) {
                add(.orderData, "Order data structures are present.")
            }
            if Self.containsAny(content, ["salesforce", "hubspot", "dynamics crm", "crm"])
                || facts.dependencyFacts.contains(where: { $0.lowercased().contains("salesforce") || $0.lowercased().contains("hubspot") }) {
                add(.crmIntegration, "A CRM integration is present.")
            }
            if Self.containsAny(content, ["email", "sms", "slack", "teams", "notification"])
                || facts.dependencyFacts.contains(where: { Self.containsAny($0.lowercased(), ["sendgrid", "twilio", "slack"]) }) {
                add(.communicationChannel, "A communication channel integration is present.")
            }
            if Self.containsAny(content, ["router.post", "router.put", "router.patch", "router.delete", "app.post(", "@postmapping", "@putmapping"])
                || path.contains("commands/") {
                add(.businessActionAPI, "A write-capable business action boundary is present.")
            }
            if Self.containsAny(path, ["readme", "docs/", "knowledge", "content/"])
                || Self.containsAny(content, ["embedding", "vector store", "knowledge base", "retrieval"])
                || facts.dependencyFacts.contains(where: { Self.containsAny($0.lowercased(), ["pinecone", "weaviate", "qdrant", "pgvector"]) }) {
                add(.knowledgeSource, "An inspectable documentation or retrieval source is present.")
            }
            if isSourceFile {
                add(.sourceCodeAccess, "Source code was successfully read.")
            }
        }

        self.init(
            signals: derived,
            confirmedAbsences: derivedAbsences,
            inspectedPaths: ledger.successfulReadPaths,
            evidenceRecords: provenanceRecords
        )
    }

    func evidence(for capability: LegacyArchitectureCapability) -> [AssessmentEvidenceReference] {
        signals.filter { $0.capability == capability }.map(\.evidence)
    }

    func absence(for capability: LegacyArchitectureCapability) -> LegacyArchitectureAbsence? {
        confirmedAbsences.first { $0.capability == capability }
    }

    var isDatabaseOnly: Bool {
        !evidence(for: .databaseAccess).isEmpty
            && evidence(for: .apiServiceLayer).isEmpty
            && absence(for: .apiServiceLayer) != nil
    }

    private static func uniqueSignals(_ values: [LegacyArchitectureSignal]) -> [LegacyArchitectureSignal] {
        var seen: Set<String> = []
        return values.filter { seen.insert("\($0.capability.rawValue)|\($0.evidence.path)").inserted }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func uniqueEvidence(_ values: [AssessmentEvidenceReference]) -> [AssessmentEvidenceReference] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    private static func provenanceReference(
        for item: ReadOnlyInspectionEvidence,
        pathRecord: ReadOnlyEvidencePathRecord?
    ) -> AssessmentEvidenceReference {
        let directlyRead = item.toolName == "engineering.read_file"
        let referenced = pathRecord?.claimLevels.contains(.referencedButNotRead) == true
        let level: ReadOnlyEngineeringClaimLevel = directlyRead
            ? (pathRecord?.claimLevels.contains(.sourceBehaviorConfirmed) == true
                ? .sourceBehaviorConfirmed
                : (pathRecord?.claimLevels.contains(.configurationConfirmed) == true
                    ? .configurationConfirmed
                    : .contentRead))
            : (referenced ? .referencedButNotRead : .discovered)
        let status: AssessmentEvidenceObservationStatus = directlyRead
            ? .directlyRead
            : (referenced ? .referenced : .discovered)
        let source: AssessmentEvidenceSource = directlyRead
            ? (level == .configurationConfirmed ? .extractedConfiguration : .inspectedFile)
            : (item.toolName.contains("search") ? .staticSearch : .evidenceLedger)
        let safeSummary: String
        if directlyRead {
            safeSummary = "The canonical relative file was successfully read and safe structured facts were extracted."
        } else if item.toolName.contains("search") {
            safeSummary = "A bounded static search recorded discovery evidence without reading file contents."
        } else {
            safeSummary = "The read-only evidence ledger recorded a workspace observation."
        }
        return AssessmentEvidenceReference(
            source: source,
            path: item.targetPath,
            fact: safeSummary,
            claimLevel: level,
            observationStatus: status,
            sourceComponent: sourceComponent(for: item.targetPath),
            safeEvidenceSummary: safeSummary,
            lineRange: directlyRead ? lineRange(for: item.output) : nil,
            fileHash: directlyRead ? sha256(item.output) : nil,
            workspaceSnapshotIdentifier: snapshotIdentifier(for: item.workspaceID),
            relatedToolEventID: item.toolResultEventID
        )
    }

    private static func lineRange(for output: String) -> String? {
        guard !output.isEmpty else { return nil }
        let count = max(1, output.split(separator: "\n", omittingEmptySubsequences: false).count)
        return "1-\(count)"
    }

    private static func sha256(_ output: String) -> String {
        SHA256.hash(data: Data(output.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func snapshotIdentifier(for workspaceID: UUID) -> String {
        "workspace-\(workspaceID.uuidString.lowercased())"
    }

    private static func sourceComponent(for path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? "workspace-root"
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }

    private static func isZeroResultSearch(_ output: String) -> Bool {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty
            || value.contains("found 0 match")
            || value.contains("0 matches")
            || value.contains("no matches")
            || value.contains("no files found")
    }

    private static let absenceSearchTerms: [LegacyArchitectureCapability: Set<String>] = [
        .apiServiceLayer: ["route", "controller", "endpoint"],
        .authenticationBoundary: ["auth", "jwt", "session"],
        .permissionModel: ["permission", "authorize", "rbac"],
        .eventSystem: ["event", "queue", "webhook"],
        .approvalMechanism: ["approval", "human review"],
        .auditLogging: ["audit"],
        .knowledgeSource: ["knowledge", "retrieval", "embedding"]
    ]
}

enum AgentCompatibilityStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case supported = "SUPPORTED"
    case unknown = "UNKNOWN"
    case blocked = "BLOCKED"
}

enum AgentIntegrationVerdict: String, Codable, CaseIterable, Hashable, Sendable {
    case yes = "YES"
    case partial = "PARTIAL"
    case no = "NO"
}

struct CompatibilityMatrixEntry: Codable, Hashable, Sendable, Identifiable {
    var requirement: AgentCapabilityRequirement
    var status: AgentCompatibilityStatus
    var claim: AssessmentClaim

    var id: String { requirement.id }
}

struct CompatibilityMatrix: Codable, Hashable, Sendable {
    var capability: AgentCapabilityProfile
    var entries: [CompatibilityMatrixEntry]
    var verdict: AgentIntegrationVerdict
}

struct IntegrationOpportunity: Codable, Hashable, Sendable, Identifiable {
    var feature: String
    var possibleIntegration: [String]
    var confidence: AssessmentClaimConfidence
    var evidence: [AssessmentEvidenceReference]
    var claim: AssessmentClaim

    var id: String { feature }
}

enum IntegrationBlockerCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case security = "SECURITY"
    case architecture = "ARCHITECTURE"
    case data = "DATA"
    case operational = "OPERATIONAL"
}

enum AssessmentRiskLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
}

struct IntegrationBlocker: Codable, Hashable, Sendable, Identifiable {
    var category: IntegrationBlockerCategory
    var requirement: LegacyArchitectureCapability
    var severity: AssessmentRiskLevel
    var reason: String
    var claim: AssessmentClaim

    var id: String { "\(category.rawValue):\(requirement.rawValue)" }
}

struct IntegrationBlockerReport: Codable, Hashable, Sendable {
    var blockers: [IntegrationBlocker]

    func blockers(in category: IntegrationBlockerCategory) -> [IntegrationBlocker] {
        blockers.filter { $0.category == category }
    }
}

struct AgentSecurityAssessment: Codable, Hashable, Sendable {
    var dataAccessRisk: AssessmentRiskLevel
    var permissionRisk: AssessmentRiskLevel
    var modificationRisk: AssessmentRiskLevel
    var humanApprovalRequired: Bool
    var claims: [AssessmentClaim]
}

struct AgentIntegrationPlanStep: Codable, Hashable, Sendable, Identifiable {
    var phase: Int
    var title: String
    var purpose: String
    var affectedComponents: [String]
    var risk: AssessmentRiskLevel
    var validationRequirement: String

    var id: Int { phase }
}

struct AgentIntegrationPlan: Codable, Hashable, Sendable {
    var capability: AgentCapabilityProfile
    var steps: [AgentIntegrationPlanStep]
}

enum IntegrationValidationTestKind: String, Codable, CaseIterable, Hashable, Sendable {
    case permission = "PERMISSION"
    case dataContract = "DATA_CONTRACT"
    case failure = "FAILURE"
    case rollback = "ROLLBACK"
    case authentication = "AUTHENTICATION"
    case approval = "APPROVAL"
    case audit = "AUDIT"
}

struct IntegrationValidationTest: Codable, Hashable, Sendable, Identifiable {
    var kind: IntegrationValidationTestKind
    var name: String
    var purpose: String
    var expectedResult: String
    var generatedOnly: Bool

    var id: String { "\(kind.rawValue):\(name)" }
}

struct IntegrationValidationPlan: Codable, Hashable, Sendable {
    var tests: [IntegrationValidationTest]
    var executionAuthorized: Bool
}

struct RecommendedAgentArchitecture: Codable, Hashable, Sendable {
    var components: [String]
    var dataFlow: [String]
    var claim: AssessmentClaim
}

enum ExpectedWorkflowVerificationStatus: String, Codable, Hashable, Sendable {
    case proposedNotRuntimeVerified = "PROPOSED_NOT_RUNTIME_VERIFIED"
}

struct ExpectedAgentWorkflow: Codable, Hashable, Sendable, Identifiable {
    var capability: String
    var trigger: String
    var agentDecisionBoundary: String
    var legacyIntegrationCall: String
    var dataReadOrProposedAction: String
    var permissionCheck: String
    var humanApprovalPoint: String
    var expectedOutput: String
    var failureBehavior: String
    var fallbackBehavior: String
    var prohibitedActions: [String]
    var verificationStatus: ExpectedWorkflowVerificationStatus
    var supportingClaimIDs: [String]

    var id: String { capability }
}

struct ExpectedOperationalOutcome: Codable, Hashable, Sendable, Identifiable {
    var capability: String
    var expectedResult: String
    var compatibility: AgentIntegrationVerdict
    var safeWhen: [String]
    var remainsBlocked: [String]
    var verificationStatus: ExpectedWorkflowVerificationStatus

    var id: String { capability }
}

enum LegacySideBlockerCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case missingAPIBoundary = "MISSING_API_BOUNDARY"
    case missingAuthorization = "MISSING_AUTHORIZATION"
    case hiddenBusinessRules = "HIDDEN_BUSINESS_RULES"
    case tightCoupling = "TIGHT_COUPLING"
    case poorDataContracts = "POOR_DATA_CONTRACTS"
    case missingTestEnvironment = "MISSING_TEST_ENVIRONMENT"
    case missingRollbackOrApproval = "MISSING_ROLLBACK_OR_APPROVAL"
}

struct LegacySideBlockerFinding: Codable, Hashable, Sendable, Identifiable {
    var category: LegacySideBlockerCategory
    var description: String
    var integrationImpact: String
    var severity: AssessmentRiskLevel
    var mitigation: String
    var remainingUncertainty: String
    var evidence: [AssessmentEvidenceReference]

    var id: String { category.rawValue }
}

enum AgentUncertaintyCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case nondeterministicModelOutput = "NONDETERMINISTIC_MODEL_OUTPUT"
    case promptSensitivity = "PROMPT_SENSITIVITY"
    case contextWindowLimitations = "CONTEXT_WINDOW_LIMITATIONS"
    case toolSelectionUncertainty = "TOOL_SELECTION_UNCERTAINTY"
    case outputSchemaInstability = "OUTPUT_SCHEMA_INSTABILITY"
    case providerModelBehaviorChanges = "PROVIDER_MODEL_BEHAVIOR_CHANGES"
    case staleOrIncompleteMemory = "STALE_OR_INCOMPLETE_MEMORY"
    case hallucinatedAssumptions = "HALLUCINATED_ASSUMPTIONS"
    case nondeterministicAuthorization = "INABILITY_TO_PROVIDE_DETERMINISTIC_AUTHORIZATION"
    case externalToolProviderOpacity = "EXTERNAL_TOOL_PROVIDER_OPACITY"
}

struct AgentUncertaintyFinding: Codable, Hashable, Sendable, Identifiable {
    var category: AgentUncertaintyCategory
    var description: String
    var integrationImpact: String
    var severity: AssessmentRiskLevel
    var mitigation: String
    var remainingUncertainty: String
    var evidenceOrInherentReason: String

    var id: String { category.rawValue }
}

struct AgentBlackBoxAssessment: Codable, Hashable, Sendable {
    var legacySideBlockers: [LegacySideBlockerFinding]
    var agentSideBlackBoxes: [AgentUncertaintyFinding]
}

enum AIAssessmentMissionState: String, Codable, CaseIterable, Hashable, Sendable {
    case understandingCapability = "Understanding requested AI capability"
    case mappingLegacyArchitecture = "Mapping Legacy architecture"
    case checkingIntegrationCapabilities = "Checking required integration capabilities"
    case inspectingPermissionBoundaries = "Inspecting permission boundaries"
    case evaluatingAgentUncertainty = "Evaluating Agent-side uncertainty"
    case identifyingBlockers = "Identifying blockers"
    case buildingCompatibilityMatrix = "Building compatibility matrix"
    case designingOperationalWorkflow = "Designing proposed integration workflow"
    case preparingValidationPlan = "Preparing validation plan"
    case finalizingGroundedAssessment = "Finalizing grounded assessment"
}

struct AIAssessmentActivitySnapshot: Codable, Hashable, Sendable {
    var capability: String
    var missionState: AIAssessmentMissionState
    var compatibility: AgentIntegrationVerdict?
    var risk: AssessmentRiskLevel?
    var blockerCount: Int?
    var evidenceCount: Int

    static func pending(for profile: AgentCapabilityProfile) -> AIAssessmentActivitySnapshot {
        AIAssessmentActivitySnapshot(
            capability: profile.name,
            missionState: .understandingCapability,
            compatibility: nil,
            risk: nil,
            blockerCount: nil,
            evidenceCount: 0
        )
    }

    var eventPayload: [String: String] {
        [
            "ai_assessment_capability": capability,
            "ai_assessment_mission_state": missionState.rawValue,
            "ai_assessment_compatibility": compatibility?.rawValue ?? "",
            "ai_assessment_risk": risk?.rawValue ?? "",
            "ai_assessment_blocker_count": blockerCount.map(String.init) ?? "",
            "ai_assessment_evidence_count": String(evidenceCount)
        ]
    }

    init?(eventPayload: [String: String]) {
        guard let capability = eventPayload["ai_assessment_capability"], !capability.isEmpty else {
            return nil
        }
        self.capability = capability
        missionState = eventPayload["ai_assessment_mission_state"]
            .flatMap(AIAssessmentMissionState.init(rawValue:))
            ?? .understandingCapability
        compatibility = eventPayload["ai_assessment_compatibility"].flatMap(AgentIntegrationVerdict.init(rawValue:))
        risk = eventPayload["ai_assessment_risk"].flatMap(AssessmentRiskLevel.init(rawValue:))
        blockerCount = eventPayload["ai_assessment_blocker_count"].flatMap(Int.init)
        evidenceCount = eventPayload["ai_assessment_evidence_count"].flatMap(Int.init) ?? 0
    }

    init(
        capability: String,
        missionState: AIAssessmentMissionState = .understandingCapability,
        compatibility: AgentIntegrationVerdict?,
        risk: AssessmentRiskLevel?,
        blockerCount: Int?,
        evidenceCount: Int
    ) {
        self.capability = capability
        self.missionState = missionState
        self.compatibility = compatibility
        self.risk = risk
        self.blockerCount = blockerCount
        self.evidenceCount = evidenceCount
    }
}

struct FDEAIIntegrationAssessmentReport: Codable, Hashable, Sendable {
    var assessmentLayerID: String
    var executiveSummary: AssessmentClaim
    var legacySystemUnderstanding: [AssessmentClaim]
    var requestedAICapability: AgentCapabilityProfile
    var compatibilityMatrix: CompatibilityMatrix
    var integrationOpportunities: [IntegrationOpportunity]
    var securityAssessment: AgentSecurityAssessment
    var integrationBlockers: IntegrationBlockerReport
    var recommendedArchitecture: RecommendedAgentArchitecture
    var integrationPlan: AgentIntegrationPlan
    var validationTestPlan: IntegrationValidationPlan
    var expectedAgentWorkflows: [ExpectedAgentWorkflow]
    var expectedOperationalOutcomes: [ExpectedOperationalOutcome]
    var agentBlackBoxAssessment: AgentBlackBoxAssessment
    var evidenceRecords: [AssessmentEvidenceReference]
    var unknownsAndNextInvestigationSteps: [String]

    var verdict: AgentIntegrationVerdict { compatibilityMatrix.verdict }

    var activitySnapshot: AIAssessmentActivitySnapshot {
        AIAssessmentActivitySnapshot(
            capability: requestedAICapability.name,
            missionState: .finalizingGroundedAssessment,
            compatibility: verdict,
            risk: [
                securityAssessment.dataAccessRisk,
                securityAssessment.permissionRisk,
                securityAssessment.modificationRisk
            ].max(by: { Self.riskRank($0) < Self.riskRank($1) }),
            blockerCount: integrationBlockers.blockers.count,
            evidenceCount: Set(compatibilityMatrix.entries.flatMap(\.claim.evidence).map(\.id)).count
        )
    }

    func markdown() -> String {
        var lines: [String] = [
            "# FDE AI Integration Assessment Report",
            "",
            "## 1. Executive Summary",
            "",
            "**\(verdict.rawValue)** — \(executiveSummary.statement)",
            claimDetails(executiveSummary),
            "",
            "## 2. Legacy System Understanding",
            ""
        ]
        lines.append(contentsOf: legacySystemUnderstanding.flatMap { ["- \($0.statement)", "  \(claimDetails($0))"] })
        lines += [
            "",
            "## 3. Requested AI Capability",
            "",
            "\(requestedAICapability.name). Required capabilities: \(requestedAICapability.requiredCapabilities.map { $0.capability.displayName }.joined(separator: ", ")).",
            "",
            "## 4. Compatibility Matrix",
            "",
            "| Requirement | Status | Evidence / Unknown |",
            "|---|---|---|"
        ]
        for entry in compatibilityMatrix.entries {
            let support = entry.claim.evidence.isEmpty
                ? entry.claim.unknowns.joined(separator: "; ")
                : entry.claim.evidence.map(\.path).joined(separator: ", ")
            lines.append("| \(entry.requirement.capability.displayName) | \(entry.status.rawValue) | \(support) |")
        }
        lines += ["", "## 5. Integration Opportunities", ""]
        if integrationOpportunities.isEmpty {
            lines.append("- No supported integration opportunity is confirmed yet.")
        } else {
            lines.append(contentsOf: integrationOpportunities.map {
                "- **\($0.feature):** \($0.possibleIntegration.joined(separator: " → ")) (\($0.confidence.rawValue); evidence: \($0.evidence.map(\.path).joined(separator: ", ")))"
            })
        }
        lines += [
            "",
            "## 6. Security Assessment",
            "",
            "- Data Access Risk: \(securityAssessment.dataAccessRisk.rawValue)",
            "- Permission Risk: \(securityAssessment.permissionRisk.rawValue)",
            "- Modification Risk: \(securityAssessment.modificationRisk.rawValue)",
            "- Human Approval Required: \(securityAssessment.humanApprovalRequired ? "YES" : "NO")",
            "",
            "## 7. Integration Blockers",
            ""
        ]
        if integrationBlockers.blockers.isEmpty {
            lines.append("- No blocker is confirmed by the available static evidence.")
        } else {
            lines.append(contentsOf: integrationBlockers.blockers.map {
                "- [\($0.category.rawValue)] **\($0.severity.rawValue)** — \($0.reason) Evidence: \($0.claim.evidence.map(\.path).joined(separator: ", "))."
            })
        }
        lines += [
            "",
            "## 8. Recommended Architecture",
            "",
            recommendedArchitecture.dataFlow.joined(separator: " → "),
            "",
            "Integration phases:"
        ]
        lines.append(contentsOf: integrationPlan.steps.map {
            "- Phase \($0.phase), **\($0.title):** \($0.purpose) Validation: \($0.validationRequirement)"
        })
        lines += ["", "## 9. Validation Test Plan", "", "Generated only; no tests were executed."]
        lines.append(contentsOf: validationTestPlan.tests.map {
            "- **\($0.name):** \($0.purpose) Expected: \($0.expectedResult)"
        })
        lines += ["", "## 10. Unknowns and Next Investigation Steps", ""]
        lines.append(contentsOf: unknownsAndNextInvestigationSteps.map { "- \($0)" })
        lines += ["", "## 11. Proposed Operational Workflow", "", "These workflows are proposed and are not runtime-verified."]
        lines.append(contentsOf: expectedAgentWorkflows.flatMap { workflow in
            [
                "- **\(workflow.capability)** [\(workflow.verificationStatus.rawValue)]",
                "  Trigger: \(workflow.trigger)",
                "  Agent decision boundary: \(workflow.agentDecisionBoundary)",
                "  Legacy integration call: \(workflow.legacyIntegrationCall)",
                "  Data read or proposed action: \(workflow.dataReadOrProposedAction)",
                "  Permission check: \(workflow.permissionCheck)",
                "  Human approval point: \(workflow.humanApprovalPoint)",
                "  Expected output: \(workflow.expectedOutput)",
                "  Failure behavior: \(workflow.failureBehavior)",
                "  Fallback behavior: \(workflow.fallbackBehavior)",
                "  Prohibited: \(workflow.prohibitedActions.joined(separator: ", "))"
            ]
        })
        lines += ["", "## 12. Expected Operational Outcomes", ""]
        lines.append(contentsOf: expectedOperationalOutcomes.map {
            "- **\($0.capability):** \($0.expectedResult) [\($0.compatibility.rawValue); \($0.verificationStatus.rawValue)] Blocked: \($0.remainsBlocked.joined(separator: "; "))"
        })
        lines += ["", "## 13. Legacy-side Blockers vs Agent-side Black Boxes", "", "Legacy-side blockers below require inspected Legacy evidence. Agent-side findings are inherent model/runtime limitations and are not presented as Legacy evidence."]
        if agentBlackBoxAssessment.legacySideBlockers.isEmpty {
            lines.append("- Legacy-side: no additional blocker is confirmed beyond the compatibility matrix.")
        } else {
            lines.append(contentsOf: agentBlackBoxAssessment.legacySideBlockers.map {
                "- Legacy-side [\($0.category.rawValue)] **\($0.severity.rawValue)** — \($0.description) Evidence: \($0.evidence.map(\.path).joined(separator: ", "))."
            })
        }
        lines.append(contentsOf: agentBlackBoxAssessment.agentSideBlackBoxes.map {
            "- Agent-side [\($0.category.rawValue)] **\($0.severity.rawValue)** — \($0.description) Mitigation: \($0.mitigation) Remaining uncertainty: \($0.remainingUncertainty) Basis: \($0.evidenceOrInherentReason)"
        })
        lines += ["", "## 14. Evidence Provenance", ""]
        if evidenceRecords.isEmpty {
            lines.append("- No material Legacy evidence record is available.")
        } else {
            lines.append(contentsOf: evidenceRecords.map { evidence in
                let optional = [
                    evidence.lineRange.map { "lines=\($0)" },
                    evidence.fileHash.map { "sha256=\($0)" },
                    evidence.workspaceSnapshotIdentifier.map { "snapshot=\($0)" },
                    evidence.relatedToolEventID.map { "tool_event=\($0.uuidString)" }
                ].compactMap { $0 }.joined(separator: "; ")
                return "- \(evidence.id) | path=\(evidence.path) | maturity=\(evidence.claimLevel?.rawValue ?? "not_applicable") | status=\(evidence.observationStatus.rawValue) | component=\(evidence.sourceComponent) | \(evidence.safeEvidenceSummary)\(optional.isEmpty ? "" : " | \(optional)")"
            })
        }
        return lines.joined(separator: "\n")
    }

    private func claimDetails(_ claim: AssessmentClaim) -> String {
        let evidence = claim.evidence.isEmpty ? "none confirmed" : claim.evidence.map(\.path).joined(separator: ", ")
        let unknowns = claim.unknowns.isEmpty ? "none recorded" : claim.unknowns.joined(separator: "; ")
        return "Claim ID: \(claim.claimID). Evidence: \(evidence). Confidence: \(claim.confidence.rawValue). Unknown: \(unknowns). Runtime: \(claim.verificationStatus.runtime.rawValue). Build: \(claim.verificationStatus.build.rawValue). Test: \(claim.verificationStatus.test.rawValue)."
    }

    private static func riskRank(_ level: AssessmentRiskLevel) -> Int {
        switch level {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}

struct LegacyAgentCompatibilityAnalyzer: Sendable {
    func assess(
        capability profile: AgentCapabilityProfile,
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger,
        legacyArchitecture architecture: LegacyArchitecture
    ) -> FDEAIIntegrationAssessmentReport {
        let entries = profile.requiredCapabilities.map { requirement in
            compatibilityEntry(for: requirement, architecture: architecture)
        }
        let verdict = verdict(for: entries)
        let matrix = CompatibilityMatrix(capability: profile, entries: entries, verdict: verdict)
        let blockers = blockerReport(entries: entries, architecture: architecture)
        let security = securityAssessment(profile: profile, entries: entries, architecture: architecture)
        let opportunities = integrationOpportunities(profile: profile, entries: entries, architecture: architecture)
        let validation = validationPlan(profile: profile)
        let plan = integrationPlan(profile: profile, architecture: architecture)
        let unknowns = unknowns(entries: entries, evidenceLedger: evidenceLedger)
        let allEvidence = uniqueEvidence(entries.flatMap(\.claim.evidence))
        let workflows = expectedWorkflows(profile: profile, entries: entries, verdict: verdict)
        let outcomes = expectedOperationalOutcomes(
            profile: profile,
            entries: entries,
            verdict: verdict
        )
        let blackBoxes = agentBlackBoxAssessment(
            profile: profile,
            entries: entries,
            architecture: architecture
        )
        let summary = AssessmentClaim(
            statement: summaryStatement(verdict: verdict, blockers: blockers.blockers.count),
            evidence: allEvidence,
            confidence: verdict == .yes && !allEvidence.isEmpty ? .high : (allEvidence.isEmpty ? .unknown : .medium),
            unknowns: unknowns
        )

        return FDEAIIntegrationAssessmentReport(
            assessmentLayerID: AIIntegrationAssessmentLayer.id,
            executiveSummary: summary,
            legacySystemUnderstanding: legacyClaims(architecture: architecture),
            requestedAICapability: profile,
            compatibilityMatrix: matrix,
            integrationOpportunities: opportunities,
            securityAssessment: security,
            integrationBlockers: blockers,
            recommendedArchitecture: recommendedArchitecture(profile: profile, entries: entries),
            integrationPlan: plan,
            validationTestPlan: validation,
            expectedAgentWorkflows: workflows,
            expectedOperationalOutcomes: outcomes,
            agentBlackBoxAssessment: blackBoxes,
            evidenceRecords: uniqueEvidence(architecture.evidenceRecords + allEvidence),
            unknownsAndNextInvestigationSteps: unknowns
        )
    }

    private func compatibilityEntry(
        for requirement: AgentCapabilityRequirement,
        architecture: LegacyArchitecture
    ) -> CompatibilityMatrixEntry {
        let evidence = architecture.evidence(for: requirement.capability)
        let absence = architecture.absence(for: requirement.capability)
        if !evidence.isEmpty, let absence {
            return CompatibilityMatrixEntry(
                requirement: requirement,
                status: .unknown,
                claim: AssessmentClaim(
                    statement: "\(requirement.capability.displayName) has conflicting inspected evidence and remains unknown.",
                    evidence: uniqueEvidence(evidence + absence.evidence),
                    confidence: .low,
                    unknowns: ["Resolve the conflict between a positive static signal and an evidence-backed bounded-search absence before feasibility is claimed."]
                )
            )
        }
        if !evidence.isEmpty {
            return CompatibilityMatrixEntry(
                requirement: requirement,
                status: .supported,
                claim: AssessmentClaim(
                    statement: "\(requirement.capability.displayName) is supported by confirmed static evidence.",
                    evidence: evidence,
                    confidence: .high,
                    unknowns: ["Runtime and production behavior were not tested."]
                )
            )
        }
        if let absence {
            return CompatibilityMatrixEntry(
                requirement: requirement,
                status: .blocked,
                claim: AssessmentClaim(
                    statement: "\(requirement.capability.displayName) is blocked: \(absence.reason)",
                    evidence: absence.evidence,
                    confidence: absence.evidence.isEmpty ? .low : .high,
                    unknowns: absence.evidence.isEmpty ? ["The reported absence has no supporting static-search evidence."] : []
                )
            )
        }
        return CompatibilityMatrixEntry(
            requirement: requirement,
            status: .unknown,
            claim: AssessmentClaim(
                statement: "\(requirement.capability.displayName) compatibility is unknown.",
                evidence: [],
                confidence: .unknown,
                unknowns: ["No confirmed supporting signal or evidence-backed absence is recorded."]
            )
        )
    }

    private func verdict(for entries: [CompatibilityMatrixEntry]) -> AgentIntegrationVerdict {
        if entries.contains(where: { $0.requirement.critical && $0.status == .blocked }) {
            return .no
        }
        if entries.contains(where: { $0.status != .supported }) {
            return .partial
        }
        return .yes
    }

    private func blockerReport(
        entries: [CompatibilityMatrixEntry],
        architecture: LegacyArchitecture
    ) -> IntegrationBlockerReport {
        var blockers = entries.compactMap { entry -> IntegrationBlocker? in
            guard entry.status == .blocked else { return nil }
            let category = blockerCategory(for: entry.requirement.capability)
            let severity: AssessmentRiskLevel = entry.requirement.critical ? .high : .medium
            return IntegrationBlocker(
                category: category,
                requirement: entry.requirement.capability,
                severity: severity,
                reason: entry.claim.statement,
                claim: entry.claim
            )
        }
        if architecture.isDatabaseOnly,
           !blockers.contains(where: { $0.requirement == .apiServiceLayer }) {
            let absence = architecture.absence(for: .apiServiceLayer)
            blockers.append(
                IntegrationBlocker(
                    category: .architecture,
                    requirement: .apiServiceLayer,
                    severity: .high,
                    reason: "Database-only access must not be exposed directly to an AI agent; an API/service boundary is required first.",
                    claim: AssessmentClaim(
                        statement: "The database-only system is blocked from direct agent integration until a service boundary exists.",
                        evidence: uniqueEvidence(architecture.evidence(for: .databaseAccess) + (absence?.evidence ?? [])),
                        confidence: .high,
                        unknowns: []
                    )
                )
            )
        }
        return IntegrationBlockerReport(blockers: blockers)
    }

    private func blockerCategory(for capability: LegacyArchitectureCapability) -> IntegrationBlockerCategory {
        switch capability {
        case .authenticationBoundary, .permissionModel, .approvalMechanism, .auditLogging:
            return .security
        case .customerData, .orderData, .customerHistory, .databaseAccess, .knowledgeSource:
            return .data
        case .apiServiceLayer, .crmIntegration, .communicationChannel, .eventSystem,
             .businessActionAPI, .frontendSurface, .sourceCodeAccess:
            return .architecture
        }
    }

    private func securityAssessment(
        profile: AgentCapabilityProfile,
        entries: [CompatibilityMatrixEntry],
        architecture: LegacyArchitecture
    ) -> AgentSecurityAssessment {
        let permission = entries.first { $0.requirement.capability == .permissionModel }
        let authentication = entries.first { $0.requirement.capability == .authenticationBoundary }
        let approval = architecture.evidence(for: .approvalMechanism)
        let dataCapabilities: Set<LegacyArchitectureCapability> = [
            .customerData, .orderData, .customerHistory, .databaseAccess, .knowledgeSource
        ]
        let accessesData = profile.requiredCapabilities.contains { dataCapabilities.contains($0.capability) }
        let permissionRisk: AssessmentRiskLevel = permission?.status == .supported
            ? .low
            : (permission?.status == .blocked ? .high : .medium)
        let dataRisk: AssessmentRiskLevel = accessesData
            && (permission?.status == .blocked || authentication?.status == .blocked) ? .high : (accessesData ? .medium : .low)
        let modificationRisk: AssessmentRiskLevel = profile.proposesWriteAccess
            ? (approval.isEmpty ? .high : .medium)
            : .low
        let approvalRequired = profile.proposesWriteAccess || dataRisk == .high || permissionRisk == .high
        let evidence = uniqueEvidence(
            [permission, authentication].compactMap { $0?.claim.evidence }.flatMap { $0 }
                + approval
                + [.userIntent("\(profile.name) proposes write access: \(profile.proposesWriteAccess).")]
        )
        let unknowns = [permission, authentication].compactMap { entry in
            entry?.status == .unknown ? "\(entry?.requirement.capability.displayName ?? "Security boundary") is not confirmed." : nil
        }
        return AgentSecurityAssessment(
            dataAccessRisk: dataRisk,
            permissionRisk: permissionRisk,
            modificationRisk: modificationRisk,
            humanApprovalRequired: approvalRequired,
            claims: [
                AssessmentClaim(
                    statement: "Security risk is derived from confirmed authentication, permission, approval, and requested-access evidence.",
                    evidence: evidence,
                    confidence: evidence.isEmpty ? .unknown : .medium,
                    unknowns: unknowns
                )
            ]
        )
    }

    private func integrationOpportunities(
        profile: AgentCapabilityProfile,
        entries: [CompatibilityMatrixEntry],
        architecture: LegacyArchitecture
    ) -> [IntegrationOpportunity] {
        var values: [IntegrationOpportunity] = []
        func add(_ feature: String, _ flow: [String], capabilities: [LegacyArchitectureCapability]) {
            guard capabilities.allSatisfy({ !architecture.evidence(for: $0).isEmpty }) else { return }
            let evidence = uniqueEvidence(capabilities.flatMap { architecture.evidence(for: $0) })
            let claim = AssessmentClaim(
                statement: "\(feature) is a possible integration based on confirmed static boundaries.",
                evidence: evidence,
                confidence: .high,
                unknowns: ["The integration has not been executed or load-tested."]
            )
            values.append(
                IntegrationOpportunity(
                    feature: feature,
                    possibleIntegration: flow,
                    confidence: claim.confidence,
                    evidence: evidence,
                    claim: claim
                )
            )
        }
        add(
            profile.name,
            ["Frontend Chat UI", "Agent Adapter", "Legacy API Layer"],
            capabilities: [.frontendSurface, .apiServiceLayer]
        )
        add(
            "Read-only governed data access",
            ["AI Agent", "Read-only Service Contract", "Legacy Data Layer"],
            capabilities: [.apiServiceLayer, .databaseAccess]
        )
        add(
            "Knowledge retrieval",
            ["AI Agent", "Permission Filter", "Approved Knowledge Source"],
            capabilities: [.knowledgeSource]
        )
        if architecture.isDatabaseOnly {
            let evidence = uniqueEvidence(
                architecture.evidence(for: .databaseAccess)
                    + (architecture.absence(for: .apiServiceLayer)?.evidence ?? [])
            )
            values.append(
                IntegrationOpportunity(
                    feature: "API/service layer prerequisite",
                    possibleIntegration: ["AI Agent", "New Read-only Service Boundary", "Legacy Database"],
                    confidence: .high,
                    evidence: evidence,
                    claim: AssessmentClaim(
                        statement: "A read-only service layer can create a safe future integration point without direct agent database access.",
                        evidence: evidence,
                        confidence: .high,
                        unknowns: ["Service contracts and ownership still require design review."]
                    )
                )
            )
        }
        return values
    }

    private func recommendedArchitecture(
        profile: AgentCapabilityProfile,
        entries: [CompatibilityMatrixEntry]
    ) -> RecommendedAgentArchitecture {
        var flow = ["AI Agent", "Authentication Gateway", "Permission-aware Agent Adapter", "Legacy API/Service Layer", "Legacy Data and Knowledge Sources"]
        if profile.proposesWriteAccess {
            flow.insert("Human Approval Gate", at: 3)
            flow.append("Append-only Audit Log")
        }
        let evidence = uniqueEvidence(entries.flatMap(\.claim.evidence))
        return RecommendedAgentArchitecture(
            components: flow,
            dataFlow: flow,
            claim: AssessmentClaim(
                statement: "Use a mediated, permission-aware service boundary; never connect the agent directly to the legacy database.",
                evidence: evidence + [.userIntent("Requested capability: \(profile.name).")],
                confidence: evidence.isEmpty ? .low : .medium,
                unknowns: ["Deployment topology and production traffic behavior were not inspected."]
            )
        )
    }

    private func expectedWorkflows(
        profile: AgentCapabilityProfile,
        entries: [CompatibilityMatrixEntry],
        verdict: AgentIntegrationVerdict
    ) -> [ExpectedAgentWorkflow] {
        let statusByCapability = Dictionary(uniqueKeysWithValues: entries.map { ($0.requirement.capability, $0.status) })
        let apiConfirmed = statusByCapability[.apiServiceLayer] == .supported
        let permissionConfirmed = statusByCapability[.permissionModel] == .supported
        let authenticationConfirmed = statusByCapability[.authenticationBoundary] == .supported
        let legacyCall = apiConfirmed
            ? "Call the confirmed Legacy API/service boundary through a read-only Agent adapter."
            : "No Legacy call is authorized until a stable API/service boundary is confirmed or created."
        let permissionCheck = permissionConfirmed && authenticationConfirmed
            ? "Propagate authenticated user context and enforce the confirmed permission boundary before each read or proposed action."
            : "Fail closed until authentication and record-level authorization are both confirmed."
        let proposedAction = profile.proposesWriteAccess
            ? "Read the minimum authorized context and prepare a bounded action proposal; do not execute it."
            : "Read only the minimum authorized data required to answer the request."
        let approvalPoint = profile.proposesWriteAccess
            ? "Require explicit human approval after the proposed action is shown and before any Legacy mutation call."
            : "No approval is needed for an authorized read-only lookup; any transition to mutation requires a new explicit human approval."

        let trigger: String
        let decisionBoundary: String
        let expectedOutput: String
        var prohibited = [
            "direct database access",
            "authorization bypass",
            "credential or secret access",
            "unapproved Legacy mutation"
        ]
        switch profile.kind {
        case .customerSupport:
            trigger = "A customer asks for support, account, or order information."
            decisionBoundary = "Classify the support intent and choose only an evidence-backed read-only lookup; ambiguous identity or action requests must stop."
            expectedOutput = "Return a grounded support answer with permitted customer/order status and a clear uncertainty or escalation notice."
            prohibited += ["refund", "order modification", "payment modification"]
        case .sales:
            trigger = "An authorized user requests account context or a sales follow-up proposal."
            decisionBoundary = "Separate read-only account context from outreach or CRM mutation; produce proposals only until approval is recorded."
            expectedOutput = "Return authorized account context or an approval-ready outreach proposal."
            prohibited += ["unapproved outreach", "automatic CRM record mutation"]
        case .workflowAutomation:
            trigger = "A user requests execution of a bounded business workflow."
            decisionBoundary = "Select only allowlisted actions and stop before any consequential operation without deterministic policy checks and approval."
            expectedOutput = "Return an approval-ready action plan or a safe refusal with the blocking control."
            prohibited += ["approval bypass", "unbounded tool execution"]
        case .dataAnalysis:
            trigger = "An authorized user asks an analytical question about approved Legacy data."
            decisionBoundary = "Translate the question into a bounded read contract; reject requests needing unapproved fields or direct database queries."
            expectedOutput = "Return a schema-conformant analysis with source scope, confidence, and limitations."
            prohibited += ["direct SQL from model output", "write-back to analytical sources"]
        case .internalKnowledge:
            trigger = "An authenticated user asks a question covered by approved internal knowledge."
            decisionBoundary = "Retrieve only entitlement-filtered passages and abstain when grounding is missing or conflicting."
            expectedOutput = "Return a cited answer or an explicit no-grounding result."
            prohibited += ["retrieval across entitlement boundaries", "uncited policy claims"]
        case .developerAssistant:
            trigger = "An authorized developer asks for codebase explanation or a change proposal."
            decisionBoundary = "Keep inspection read-only and separate analysis from any later mutation workflow."
            expectedOutput = "Return evidence-linked engineering findings or a reviewable change proposal."
            prohibited += ["repository mutation", "deployment", "Git operations"]
        case .unspecified:
            trigger = "An authenticated user requests an AI-assisted Legacy capability."
            decisionBoundary = "Clarify the capability and restrict execution to confirmed read-only boundaries."
            expectedOutput = "Return a scoped proposal with explicit unknowns and prohibited actions."
        }

        return [
            ExpectedAgentWorkflow(
                capability: profile.name,
                trigger: trigger,
                agentDecisionBoundary: decisionBoundary,
                legacyIntegrationCall: legacyCall,
                dataReadOrProposedAction: proposedAction,
                permissionCheck: permissionCheck,
                humanApprovalPoint: approvalPoint,
                expectedOutput: expectedOutput,
                failureBehavior: "Fail closed on missing identity, authorization, schema validation, timeout, provider failure, or conflicting evidence; record a safe audit event without sensitive values.",
                fallbackBehavior: "Return the existing Legacy-only path or route to a human; do not claim success or retry mutations automatically.",
                prohibitedActions: uniqueStrings(prohibited),
                verificationStatus: .proposedNotRuntimeVerified,
                supportingClaimIDs: entries.map(\.claim.claimID)
            )
        ]
    }

    private func expectedOperationalOutcomes(
        profile: AgentCapabilityProfile,
        entries: [CompatibilityMatrixEntry],
        verdict: AgentIntegrationVerdict
    ) -> [ExpectedOperationalOutcome] {
        let supported = entries.filter { $0.status == .supported }.map { $0.requirement.capability.displayName }
        let unresolved = entries.filter { $0.status != .supported }.map {
            "\($0.requirement.capability.displayName) remains \($0.status.rawValue)"
        }
        let result: String
        switch verdict {
        case .yes:
            result = "A staged read-only integration is statically supportable, subject to non-production runtime validation."
        case .partial:
            result = "Only the confirmed subset can be proposed; unresolved boundaries must fail closed."
        case .no:
            result = "No integration should proceed until the confirmed Legacy-side blockers are resolved."
        }
        return [
            ExpectedOperationalOutcome(
                capability: profile.name,
                expectedResult: result,
                compatibility: verdict,
                safeWhen: supported.isEmpty ? ["No safe runtime capability is confirmed yet."] : supported,
                remainsBlocked: unresolved.isEmpty ? ["All mutations remain prohibited until separately authorized and validated."] : unresolved,
                verificationStatus: .proposedNotRuntimeVerified
            )
        ]
    }

    private func agentBlackBoxAssessment(
        profile: AgentCapabilityProfile,
        entries: [CompatibilityMatrixEntry],
        architecture: LegacyArchitecture
    ) -> AgentBlackBoxAssessment {
        func entry(_ capability: LegacyArchitectureCapability) -> CompatibilityMatrixEntry? {
            entries.first { $0.requirement.capability == capability }
        }
        var legacy: [LegacySideBlockerFinding] = []
        if let api = entry(.apiServiceLayer), api.status == .blocked {
            legacy.append(
                LegacySideBlockerFinding(
                    category: .missingAPIBoundary,
                    description: "A stable Legacy API/service boundary is confirmed absent for the requested capability.",
                    integrationImpact: "The Agent cannot safely call Legacy behavior and direct database access remains prohibited.",
                    severity: .high,
                    mitigation: "Create a versioned, read-only service contract with bounded inputs and outputs.",
                    remainingUncertainty: "Runtime behavior and operational ownership remain unverified.",
                    evidence: api.claim.evidence
                )
            )
        }
        let blockedAuthorization = [entry(.authenticationBoundary), entry(.permissionModel)]
            .compactMap { $0 }
            .filter { $0.status == .blocked }
        if !blockedAuthorization.isEmpty {
            legacy.append(
                LegacySideBlockerFinding(
                    category: .missingAuthorization,
                    description: "Required authentication or authorization controls are confirmed absent.",
                    integrationImpact: "Identity-bound data access cannot be enforced deterministically.",
                    severity: .high,
                    mitigation: "Add deterministic authentication and least-privilege authorization outside the model.",
                    remainingUncertainty: "Tenant, record, and field-level rules still require owner validation.",
                    evidence: uniqueEvidence(blockedAuthorization.flatMap(\.claim.evidence))
                )
            )
        }
        let dataCapabilities: Set<LegacyArchitectureCapability> = [.customerData, .orderData, .customerHistory, .databaseAccess, .knowledgeSource]
        let blockedData = entries.filter { dataCapabilities.contains($0.requirement.capability) && $0.status == .blocked }
        if !blockedData.isEmpty {
            legacy.append(
                LegacySideBlockerFinding(
                    category: .poorDataContracts,
                    description: "A required Legacy data or knowledge contract is confirmed absent.",
                    integrationImpact: "The requested Agent output cannot be grounded in an approved stable contract.",
                    severity: blockedData.contains(where: \.requirement.critical) ? .high : .medium,
                    mitigation: "Define a versioned, redacted data contract and validate it with approved fixtures.",
                    remainingUncertainty: "Data quality and production completeness were not tested.",
                    evidence: uniqueEvidence(blockedData.flatMap(\.claim.evidence))
                )
            )
        }
        if profile.proposesWriteAccess,
           let approval = entry(.approvalMechanism),
           approval.status == .blocked {
            legacy.append(
                LegacySideBlockerFinding(
                    category: .missingRollbackOrApproval,
                    description: "A required approval boundary is confirmed absent for a proposed write capability.",
                    integrationImpact: "Consequential actions cannot proceed safely.",
                    severity: .high,
                    mitigation: "Add explicit human approval, idempotency, audit, rollback, and feature-disable controls.",
                    remainingUncertainty: "Rollback ownership and recovery time are not verified.",
                    evidence: approval.claim.evidence
                )
            )
        }

        func inherent(
            _ category: AgentUncertaintyCategory,
            _ description: String,
            _ impact: String,
            severity: AssessmentRiskLevel = .medium,
            mitigation: String,
            uncertainty: String
        ) -> AgentUncertaintyFinding {
            AgentUncertaintyFinding(
                category: category,
                description: description,
                integrationImpact: impact,
                severity: severity,
                mitigation: mitigation,
                remainingUncertainty: uncertainty,
                evidenceOrInherentReason: "Inherent AI Agent/model or external-provider limitation; this is not inspected Legacy evidence."
            )
        }
        let agent = [
            inherent(.nondeterministicModelOutput, "Equivalent inputs may produce different model outputs.", "Responses and action proposals may vary across runs.", mitigation: "Use deterministic policy gates, constrained schemas, low-variance settings, and repeatable evaluations.", uncertainty: "Semantic variation cannot be eliminated completely."),
            inherent(.promptSensitivity, "Small prompt or context changes can alter behavior.", "Safety and routing performance can regress after prompt edits.", mitigation: "Version prompts and run regression benchmarks before release.", uncertainty: "Unseen phrasing can still change behavior."),
            inherent(.contextWindowLimitations, "Relevant Legacy context can be omitted or truncated.", "The Agent may miss a required rule or dependency.", severity: .high, mitigation: "Use bounded retrieval, evidence ledgers, and explicit unknown states.", uncertainty: "Completeness depends on retrieval quality and context budget."),
            inherent(.toolSelectionUncertainty, "The model may choose an incorrect or unnecessary tool.", "A wrong call can yield incomplete evidence or unsafe intent.", severity: .high, mitigation: "Allowlist tools, validate arguments, enforce scope, and require one bounded action at a time.", uncertainty: "Selection quality remains probabilistic."),
            inherent(.outputSchemaInstability, "Model output may fail the required schema.", "Automation can stop or misinterpret a response.", mitigation: "Validate structured output and permit one bounded repair before failing closed.", uncertainty: "Provider responses can remain invalid after repair."),
            inherent(.providerModelBehaviorChanges, "Provider or model upgrades can change behavior.", "Previously passing prompts and schemas can regress.", severity: .high, mitigation: "Pin model versions where possible and gate upgrades with the acceptance benchmark.", uncertainty: "Provider-side changes may not be fully observable."),
            inherent(.staleOrIncompleteMemory, "Conversation or retrieval memory may be stale or incomplete.", "The Agent can rely on outdated customer or system context.", mitigation: "Treat Legacy systems as the source of truth and attach freshness metadata.", uncertainty: "External freshness cannot be inferred by the model."),
            inherent(.hallucinatedAssumptions, "The model can invent unsupported facts or business rules.", "Feasibility or customer answers can be overstated.", severity: .high, mitigation: "Require claim IDs, canonical evidence, confidence, unknowns, and abstention on missing evidence.", uncertainty: "Hallucination risk remains even with grounding."),
            inherent(.nondeterministicAuthorization, "A model cannot serve as a deterministic authorization engine.", "Model-only access decisions can expose data or actions.", severity: .high, mitigation: "Enforce authentication and authorization in deterministic Legacy-side code before every call.", uncertainty: "Natural-language policy interpretation must never grant access."),
            inherent(.externalToolProviderOpacity, "External tools and providers can fail or change outside Legacy visibility.", "Results, latency, availability, and retention behavior may be opaque.", severity: .high, mitigation: "Use timeouts, circuit breakers, audit-safe telemetry, contractual controls, and a Legacy-only fallback.", uncertainty: "Third-party internal behavior cannot be fully inspected.")
        ]
        _ = architecture
        return AgentBlackBoxAssessment(legacySideBlockers: legacy, agentSideBlackBoxes: agent)
    }

    private func integrationPlan(
        profile: AgentCapabilityProfile,
        architecture: LegacyArchitecture
    ) -> AgentIntegrationPlan {
        var steps = [
            AgentIntegrationPlanStep(
                phase: 1,
                title: "Establish safe boundaries",
                purpose: "Confirm or create read-only API, authentication, and permission boundaries before agent access.",
                affectedComponents: ["Authentication", "Authorization", "Legacy API/service layer"],
                risk: .high,
                validationRequirement: "Permission and authentication isolation tests pass."
            ),
            AgentIntegrationPlanStep(
                phase: 2,
                title: "Connect read-only context",
                purpose: "Map approved data and knowledge into versioned agent contracts.",
                affectedComponents: ["Agent adapter", "Data contracts", "Knowledge retrieval"],
                risk: .medium,
                validationRequirement: "Data-contract and sensitive-data filtering tests pass."
            ),
            AgentIntegrationPlanStep(
                phase: 3,
                title: "Add failure isolation",
                purpose: "Keep the legacy system operational when the AI service is unavailable.",
                affectedComponents: ["Feature flag", "Timeouts", "Fallback path", "Observability"],
                risk: .medium,
                validationRequirement: "Failure and rollback tests pass in a non-production environment."
            )
        ]
        if profile.proposesWriteAccess {
            steps.append(
                AgentIntegrationPlanStep(
                    phase: 4,
                    title: "Enable limited approved actions",
                    purpose: "Expose narrowly scoped actions only after human approval and audit controls exist.",
                    affectedComponents: ["Business action API", "Approval gate", "Audit log"],
                    risk: .high,
                    validationRequirement: "Approval-bypass, least-privilege, idempotency, and audit tests pass."
                )
            )
        }
        if architecture.isDatabaseOnly {
            steps[0].purpose = "Create a read-only service/API boundary before any agent connection; direct database access is prohibited."
        }
        return AgentIntegrationPlan(capability: profile, steps: steps)
    }

    private func validationPlan(profile: AgentCapabilityProfile) -> IntegrationValidationPlan {
        var tests = [
            IntegrationValidationTest(kind: .permission, name: "Agent cannot modify customer records", purpose: "Verify least privilege and deny direct mutation.", expectedResult: "All unauthorized writes are rejected and recorded.", generatedOnly: true),
            IntegrationValidationTest(kind: .dataContract, name: "Legacy response matches agent schema", purpose: "Verify stable types, required fields, and redaction.", expectedResult: "Approved fixtures conform; sensitive fields are absent.", generatedOnly: true),
            IntegrationValidationTest(kind: .failure, name: "Legacy operates when AI service fails", purpose: "Verify timeout, fallback, and circuit-breaker behavior.", expectedResult: "Legacy user workflows remain available.", generatedOnly: true),
            IntegrationValidationTest(kind: .rollback, name: "AI integration can be disabled safely", purpose: "Verify feature-flag rollback without data repair.", expectedResult: "Disabling the integration restores the legacy-only path.", generatedOnly: true),
            IntegrationValidationTest(kind: .authentication, name: "Agent identity cannot cross tenant or user boundaries", purpose: "Verify authentication context propagation.", expectedResult: "Cross-boundary requests are denied.", generatedOnly: true)
        ]
        if profile.proposesWriteAccess {
            tests += [
                IntegrationValidationTest(kind: .approval, name: "Consequential actions require human approval", purpose: "Attempt action execution without a valid approval token.", expectedResult: "The action is blocked before legacy mutation.", generatedOnly: true),
                IntegrationValidationTest(kind: .audit, name: "Approved actions produce complete audit records", purpose: "Verify actor, approver, input, outcome, and correlation ID.", expectedResult: "Every attempted action is traceable.", generatedOnly: true)
            ]
        }
        return IntegrationValidationPlan(tests: tests, executionAuthorized: false)
    }

    private func unknowns(
        entries: [CompatibilityMatrixEntry],
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger
    ) -> [String] {
        var values = entries.filter { $0.status == .unknown }.map {
            "Inspect or run a bounded static search for \($0.requirement.capability.displayName); current status remains UNKNOWN."
        }
        if !evidenceLedger.unsatisfied.isEmpty {
            values.append("Complete evidence-ledger requirements: \(evidenceLedger.unsatisfied.map(\.rawValue).joined(separator: ", ")).")
        }
        values += [
            "Validate production traffic behavior in an authorized non-production environment.",
            "Confirm data classification, retention, and tenant boundaries with system owners.",
            "Confirm rollback ownership and operational runbooks before implementation."
        ]
        return uniqueStrings(values)
    }

    private func legacyClaims(architecture: LegacyArchitecture) -> [AssessmentClaim] {
        LegacyArchitectureCapability.allCases.compactMap { capability in
            let evidence = architecture.evidence(for: capability)
            guard !evidence.isEmpty else { return nil }
            return AssessmentClaim(
                statement: "Confirmed \(capability.displayName).",
                evidence: evidence,
                confidence: .high,
                unknowns: ["Runtime behavior was not verified."]
            )
        }
    }

    private func summaryStatement(verdict: AgentIntegrationVerdict, blockers: Int) -> String {
        switch verdict {
        case .yes:
            return "The requested agent capability has confirmed static integration support; implementation still requires staged validation."
        case .partial:
            return "The requested agent capability has partial static support, with unknown or non-critical blocked areas requiring investigation."
        case .no:
            return "The requested agent capability cannot safely integrate yet because \(blockers) confirmed blocker(s) must be resolved first."
        }
    }

    private func uniqueEvidence(_ values: [AssessmentEvidenceReference]) -> [AssessmentEvidenceReference] {
        var seen: Set<String> = []
        return values.filter { seen.insert("\($0.source.rawValue)|\($0.path)|\($0.fact)").inserted }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}
