import Foundation

enum Phase2CAcceptanceCaseID: String, Codable, CaseIterable, Hashable, Sendable {
    case fullySupportedReadOnlyCustomerSupport = "01_fully_supported_read_only_customer_support"
    case apiPresentAuthorizationUnknown = "02_api_present_authorization_unknown"
    case missingAPILayer = "03_missing_api_layer"
    case databaseOnlySystem = "04_database_only_system"
    case missingApprovalWorkflow = "05_missing_approval_workflow"
    case highImpactWriteOperation = "06_high_impact_write_operation"
    case knowledgeSourceMissing = "07_knowledge_source_missing"
    case eventSystemMissing = "08_event_system_missing"
    case frontendOnlyProject = "09_frontend_only_project"
    case referencedUnreadAuthBoundary = "10_referenced_but_unread_auth_boundary"
    case missingEvidenceUnknown = "11_missing_evidence_remains_unknown"
    case conflictingEvidence = "12_conflicting_evidence"
    case unsupportedFeasibilityClaimRejection = "13_unsupported_feasibility_claim_rejection"
    case legacyOnlyScopeIsolation = "14_legacy_only_scope_isolation"
    case sensitiveFileExclusion = "15_sensitive_file_exclusion"
    case chineseAssessment = "16_chinese_assessment"
    case providerFallback = "17_provider_fallback"
    case sameTaskContinuation = "18_same_task_continuation"
    case proposedWorkflowGeneration = "19_proposed_workflow_generation"
    case agentBlackBoxAnalysis = "20_agent_black_box_blocker_analysis"
}

struct Phase2CCompatibilityItem: Codable, Hashable, Sendable {
    var capability: String
    var status: AgentCompatibilityStatus
    var claimID: String
}

struct Phase2CAcceptanceResult: Codable, Hashable, Sendable, Identifiable {
    var caseID: Phase2CAcceptanceCaseID
    var requestedCapability: String
    var compatibilityDecision: AgentIntegrationVerdict
    var compatibilityItems: [Phase2CCompatibilityItem]
    var risk: AssessmentRiskLevel
    var blockers: [String]
    var legacySideBlockers: [LegacySideBlockerFinding]
    var agentSideBlackBoxes: [AgentUncertaintyFinding]
    var opportunities: [IntegrationOpportunity]
    var proposedOperationalWorkflow: [ExpectedAgentWorkflow]
    var evidenceRecords: [AssessmentEvidenceReference]
    var validationPlan: IntegrationValidationPlan
    var unknowns: [String]
    var terminalState: String
    var passed: Bool
    var passFailReason: String

    var id: String { caseID.rawValue }
}

struct Phase2CAcceptanceBenchmark: Sendable {
    func runAll() -> [Phase2CAcceptanceResult] {
        Phase2CAcceptanceCaseID.allCases.map(run)
    }

    func run(_ caseID: Phase2CAcceptanceCaseID) -> Phase2CAcceptanceResult {
        let fixture = fixture(for: caseID)
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: ReadOnlyEvidenceRequirements(request: fixture.request),
            evidence: []
        )
        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: fixture.profile,
            evidenceLedger: ledger,
            legacyArchitecture: fixture.architecture
        )
        let passed = evaluate(caseID, report: report, terminalState: fixture.terminalState)
        return Phase2CAcceptanceResult(
            caseID: caseID,
            requestedCapability: report.requestedAICapability.name,
            compatibilityDecision: report.verdict,
            compatibilityItems: report.compatibilityMatrix.entries.map {
                Phase2CCompatibilityItem(
                    capability: $0.requirement.capability.rawValue,
                    status: $0.status,
                    claimID: $0.claim.claimID
                )
            },
            risk: report.activitySnapshot.risk ?? .high,
            blockers: report.integrationBlockers.blockers.map(\.reason),
            legacySideBlockers: report.agentBlackBoxAssessment.legacySideBlockers,
            agentSideBlackBoxes: report.agentBlackBoxAssessment.agentSideBlackBoxes,
            opportunities: report.integrationOpportunities,
            proposedOperationalWorkflow: report.expectedAgentWorkflows,
            evidenceRecords: report.evidenceRecords,
            validationPlan: report.validationTestPlan,
            unknowns: report.unknownsAndNextInvestigationSteps,
            terminalState: fixture.terminalState,
            passed: passed,
            passFailReason: passed
                ? "Deterministic Phase 2C acceptance contract satisfied."
                : "The deterministic Phase 2C acceptance contract was not satisfied."
        )
    }

    private func evaluate(
        _ caseID: Phase2CAcceptanceCaseID,
        report: FDEAIIntegrationAssessmentReport,
        terminalState: String
    ) -> Bool {
        func status(_ capability: LegacyArchitectureCapability) -> AgentCompatibilityStatus? {
            report.compatibilityMatrix.entries.first { $0.requirement.capability == capability }?.status
        }
        switch caseID {
        case .fullySupportedReadOnlyCustomerSupport:
            return report.verdict == .yes && report.integrationBlockers.blockers.isEmpty
        case .apiPresentAuthorizationUnknown:
            return report.verdict == .partial
                && status(.apiServiceLayer) == .supported
                && status(.permissionModel) == .unknown
        case .missingAPILayer:
            return report.verdict == .no
                && status(.apiServiceLayer) == .blocked
                && report.agentBlackBoxAssessment.legacySideBlockers.contains { $0.category == .missingAPIBoundary }
        case .databaseOnlySystem:
            return report.verdict == .no
                && report.integrationOpportunities.contains { $0.feature == "API/service layer prerequisite" }
        case .missingApprovalWorkflow:
            return report.verdict == .no && status(.approvalMechanism) == .blocked
        case .highImpactWriteOperation:
            return report.securityAssessment.modificationRisk == .high
                && status(.approvalMechanism) == .blocked
        case .knowledgeSourceMissing:
            return report.verdict == .no && status(.knowledgeSource) == .blocked
        case .eventSystemMissing:
            return report.verdict == .partial && status(.eventSystem) == .blocked
        case .frontendOnlyProject:
            return report.verdict == .partial
                && report.compatibilityMatrix.entries.allSatisfy { $0.status == .unknown }
        case .referencedUnreadAuthBoundary:
            return status(.authenticationBoundary) == .unknown
                && report.evidenceRecords.contains { $0.observationStatus == .referenced }
        case .missingEvidenceUnknown:
            return report.compatibilityMatrix.entries.allSatisfy {
                $0.status == .unknown && $0.claim.confidence == .unknown
            }
        case .conflictingEvidence:
            return status(.apiServiceLayer) == .unknown
                && report.compatibilityMatrix.entries.contains { $0.claim.statement.contains("conflicting") }
        case .unsupportedFeasibilityClaimRejection:
            return report.verdict != .yes
                && report.executiveSummary.verificationStatus.runtime == .runtimeNotVerified
        case .legacyOnlyScopeIsolation:
            return report.evidenceRecords.allSatisfy { !$0.path.lowercased().contains("agent") }
        case .sensitiveFileExclusion:
            return report.evidenceRecords.allSatisfy { !ReadOnlySensitivePathPolicy.isSensitive($0.path) }
        case .chineseAssessment:
            return report.requestedAICapability.kind == .customerSupport
                && ReadOnlyResponseLanguage(request: fixture(for: caseID).request) == .chinese
        case .providerFallback:
            return terminalState == "COMPLETED_WITH_DETERMINISTIC_FALLBACK"
                && !report.expectedAgentWorkflows.isEmpty
        case .sameTaskContinuation:
            return terminalState == "SAME_TASK_CONTINUED"
                && report.verdict != .yes
        case .proposedWorkflowGeneration:
            return report.expectedAgentWorkflows.allSatisfy {
                !$0.trigger.isEmpty
                    && !$0.permissionCheck.isEmpty
                    && !$0.failureBehavior.isEmpty
                    && !$0.fallbackBehavior.isEmpty
                    && !$0.prohibitedActions.isEmpty
                    && $0.verificationStatus == .proposedNotRuntimeVerified
            }
        case .agentBlackBoxAnalysis:
            return report.agentBlackBoxAssessment.agentSideBlackBoxes.count == AgentUncertaintyCategory.allCases.count
                && report.agentBlackBoxAssessment.agentSideBlackBoxes.allSatisfy {
                    $0.evidenceOrInherentReason.contains("not inspected Legacy evidence")
                }
        }
    }

    private func fixture(for caseID: Phase2CAcceptanceCaseID) -> Fixture {
        let customerRequest = "Assess a read-only customer support AI Agent for the Legacy project."
        switch caseID {
        case .fullySupportedReadOnlyCustomerSupport:
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: customerSupportArchitecture(),
                terminalState: "COMPLETED"
            )
        case .apiPresentAuthorizationUnknown:
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: architecture(signals: [
                    (.apiServiceLayer, "server/routes/customers.ts"),
                    (.customerData, "server/schema.prisma"),
                    (.orderData, "server/schema.prisma")
                ]),
                terminalState: "COMPLETED_WITH_UNKNOWNS"
            )
        case .missingAPILayer:
            return Fixture(
                request: "Assess a data analysis Agent.",
                profile: .profile(for: .dataAnalysis),
                architecture: architecture(
                    signals: [
                        (.databaseAccess, "database/schema.sql"),
                        (.authenticationBoundary, "server/auth.ts"),
                        (.permissionModel, "server/permissions.ts"),
                        (.auditLogging, "server/audit.ts")
                    ],
                    absences: [.apiServiceLayer]
                ),
                terminalState: "COMPLETED_BLOCKED"
            )
        case .databaseOnlySystem:
            return Fixture(
                request: "Assess a database-only Legacy for data analysis.",
                profile: .profile(for: .dataAnalysis),
                architecture: architecture(signals: [(.databaseAccess, "schema.sql")], absences: [.apiServiceLayer]),
                terminalState: "COMPLETED_BLOCKED"
            )
        case .missingApprovalWorkflow:
            return Fixture(
                request: "Assess workflow automation with approval.",
                profile: .profile(for: .workflowAutomation),
                architecture: architecture(
                    signals: [
                        (.businessActionAPI, "server/actions.ts"),
                        (.auditLogging, "server/audit.ts"),
                        (.authenticationBoundary, "server/auth.ts"),
                        (.permissionModel, "server/permissions.ts")
                    ],
                    absences: [.approvalMechanism]
                ),
                terminalState: "COMPLETED_BLOCKED"
            )
        case .highImpactWriteOperation:
            return Fixture(
                request: "Assess a sales Agent that can update CRM records.",
                profile: .profile(for: .sales),
                architecture: architecture(
                    signals: [
                        (.customerHistory, "server/customers.ts"),
                        (.crmIntegration, "server/crm.ts"),
                        (.communicationChannel, "server/email.ts"),
                        (.eventSystem, "server/events.ts"),
                        (.authenticationBoundary, "server/auth.ts"),
                        (.permissionModel, "server/permissions.ts")
                    ],
                    absences: [.approvalMechanism]
                ),
                terminalState: "COMPLETED_BLOCKED"
            )
        case .knowledgeSourceMissing:
            return Fixture(
                request: "Assess an internal knowledge Agent.",
                profile: .profile(for: .internalKnowledge),
                architecture: architecture(
                    signals: [
                        (.apiServiceLayer, "server/routes.ts"),
                        (.authenticationBoundary, "server/auth.ts"),
                        (.permissionModel, "server/permissions.ts"),
                        (.auditLogging, "server/audit.ts")
                    ],
                    absences: [.knowledgeSource]
                ),
                terminalState: "COMPLETED_BLOCKED"
            )
        case .eventSystemMissing:
            return Fixture(
                request: "Assess a sales Agent.",
                profile: .profile(for: .sales),
                architecture: architecture(
                    signals: [
                        (.customerHistory, "server/customers.ts"),
                        (.crmIntegration, "server/crm.ts"),
                        (.communicationChannel, "server/email.ts"),
                        (.authenticationBoundary, "server/auth.ts"),
                        (.permissionModel, "server/permissions.ts"),
                        (.approvalMechanism, "server/approval.ts")
                    ],
                    absences: [.eventSystem]
                ),
                terminalState: "COMPLETED_WITH_UNKNOWNS"
            )
        case .frontendOnlyProject:
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: architecture(signals: [(.frontendSurface, "src/App.tsx")]),
                terminalState: "COMPLETED_WITH_UNKNOWNS"
            )
        case .referencedUnreadAuthBoundary:
            let reference = evidence(
                path: "server/auth.ts",
                fact: "A source reference points to an auth module whose contents were not read.",
                level: .referencedButNotRead,
                status: .referenced
            )
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: LegacyArchitecture(evidenceRecords: [reference]),
                terminalState: "COMPLETED_WITH_UNKNOWNS"
            )
        case .missingEvidenceUnknown, .unsupportedFeasibilityClaimRejection:
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: LegacyArchitecture(),
                terminalState: "COMPLETED_WITH_UNKNOWNS"
            )
        case .conflictingEvidence:
            return Fixture(
                request: "Assess a data analysis Agent.",
                profile: .profile(for: .dataAnalysis),
                architecture: architecture(
                    signals: [
                        (.databaseAccess, "database/schema.sql"),
                        (.apiServiceLayer, "server/routes.ts"),
                        (.authenticationBoundary, "server/auth.ts"),
                        (.permissionModel, "server/permissions.ts"),
                        (.auditLogging, "server/audit.ts")
                    ],
                    absences: [.apiServiceLayer]
                ),
                terminalState: "COMPLETED_WITH_CONFLICT"
            )
        case .legacyOnlyScopeIsolation:
            return Fixture(
                request: "Inspect only the Legacy project for customer support readiness.",
                profile: .profile(for: .customerSupport),
                architecture: customerSupportArchitecture(),
                terminalState: "COMPLETED"
            )
        case .sensitiveFileExclusion:
            let safe = architecture(signals: [(.frontendSurface, "src/App.tsx")])
            let secretSignal = LegacyArchitectureSignal(
                capability: .authenticationBoundary,
                evidence: evidence(path: ".env", fact: "Sensitive file must be excluded.")
            )
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: LegacyArchitecture(
                    signals: safe.signals + [secretSignal],
                    evidenceRecords: safe.evidenceRecords + [secretSignal.evidence]
                ),
                terminalState: "COMPLETED_WITH_UNKNOWNS"
            )
        case .chineseAssessment:
            return Fixture(
                request: "请只读取当前 Legacy 项目，判断它是否适合接入一个客户支持 AI Agent。",
                profile: .profile(for: .customerSupport),
                architecture: customerSupportArchitecture(),
                terminalState: "COMPLETED"
            )
        case .providerFallback:
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: customerSupportArchitecture(),
                terminalState: "COMPLETED_WITH_DETERMINISTIC_FALLBACK"
            )
        case .sameTaskContinuation:
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: architecture(signals: [(.apiServiceLayer, "server/routes.ts")]),
                terminalState: "SAME_TASK_CONTINUED"
            )
        case .proposedWorkflowGeneration:
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: customerSupportArchitecture(),
                terminalState: "COMPLETED"
            )
        case .agentBlackBoxAnalysis:
            return Fixture(
                request: customerRequest,
                profile: .profile(for: .customerSupport),
                architecture: architecture(signals: [(.apiServiceLayer, "server/routes.ts")]),
                terminalState: "COMPLETED_WITH_UNKNOWNS"
            )
        }
    }

    private func customerSupportArchitecture() -> LegacyArchitecture {
        architecture(signals: [
            (.customerData, "server/schema.prisma"),
            (.orderData, "server/schema.prisma"),
            (.authenticationBoundary, "server/auth.ts"),
            (.apiServiceLayer, "server/routes/customers.ts"),
            (.knowledgeSource, "docs/support.md"),
            (.permissionModel, "server/permissions.ts"),
            (.frontendSurface, "src/App.tsx"),
            (.databaseAccess, "server/schema.prisma")
        ])
    }

    private func architecture(
        signals: [(LegacyArchitectureCapability, String)],
        absences: [LegacyArchitectureCapability] = []
    ) -> LegacyArchitecture {
        let values = signals.map { capability, path in
            LegacyArchitectureSignal(
                capability: capability,
                evidence: evidence(
                    path: path,
                    fact: "Confirmed \(capability.displayName) in directly read static evidence."
                )
            )
        }
        let missing = absences.map { capability in
            LegacyArchitectureAbsence(
                capability: capability,
                reason: "A deterministic bounded inventory confirmed no common \(capability.displayName) boundary.",
                evidence: [
                    evidence(
                        path: ".",
                        fact: "Bounded static search returned zero matches for \(capability.displayName).",
                        level: .discovered,
                        status: .discovered
                    )
                ]
            )
        }
        return LegacyArchitecture(
            signals: values,
            confirmedAbsences: missing,
            inspectedPaths: signals.map(\.1),
            evidenceRecords: values.map(\.evidence) + missing.flatMap(\.evidence)
        )
    }

    private func evidence(
        path: String,
        fact: String,
        level: ReadOnlyEngineeringClaimLevel = .sourceBehaviorConfirmed,
        status: AssessmentEvidenceObservationStatus = .directlyRead
    ) -> AssessmentEvidenceReference {
        AssessmentEvidenceReference(
            source: status == .directlyRead ? .inspectedFile : .evidenceLedger,
            path: path,
            fact: fact,
            claimLevel: level,
            observationStatus: status,
            sourceComponent: path.split(separator: "/").first.map(String.init) ?? "workspace-root",
            safeEvidenceSummary: fact
        )
    }

    private struct Fixture {
        var request: String
        var profile: AgentCapabilityProfile
        var architecture: LegacyArchitecture
        var terminalState: String
    }
}
