import XCTest
@testable import FDECloudOS

final class Phase3B5AssessmentHumanReviewWorkflowTests: XCTestCase {
    func testPreparedReviewIsStableExactAndNonExecutable() throws {
        let source = try makeSource()
        let first = try AssessmentHumanReviewWorkflow.prepare(
            report: source.report,
            recommendationSet: source.recommendationSet
        )
        let second = try AssessmentReviewWorkflow.open(
            report: source.report,
            recommendationSet: source.recommendationSet
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.schemaVersion, "3B.5")
        XCTAssertEqual(first.status, .awaitingReview)
        XCTAssertNil(first.decision)
        XCTAssertEqual(first.sourceReportID, source.report.composition?.reportID)
        XCTAssertEqual(first.recommendationSetID, source.recommendationSet.recommendationSetID)
        XCTAssertEqual(first.binding, source.recommendationSet.binding)
        XCTAssertEqual(first.recommendationIDs, source.recommendationSet.recommendations.map(\.recommendationID))
        XCTAssertEqual(first.sourceClaimIDs, source.recommendationSet.sourceClaimIDs)
        XCTAssertEqual(first.authority, .advisoryReviewOnly)
        XCTAssertFalse(first.executionAuthorized)
        XCTAssertFalse(first.approvalGranted)
        XCTAssertEqual(first.reviewID, AssessmentHumanReviewWorkflow.reconstructReviewID(first))
        XCTAssertTrue(AssessmentHumanReviewWorkflow.validate(
            first,
            against: source.recommendationSet,
            report: source.report
        ).isEmpty)
        let bundle = AssessmentHumanReviewBundle(
            report: source.report,
            recommendationSet: source.recommendationSet,
            review: first
        )
        let context = reviewContext(first)
        XCTAssertEqual(AssessmentHumanReviewWorkflow.eligibility(
            for: bundle,
            submissionBinding: context.submissionBinding
        ), .available)
        var crossSession = context.submissionBinding
        crossSession.agentSessionID = UUID()
        XCTAssertFalse(AssessmentHumanReviewWorkflow.eligibility(
            for: bundle,
            submissionBinding: crossSession
        ).isAvailable)
    }

    func testAcknowledgementRecordsPlanningAdviceWithoutAnyAuthority() throws {
        let source = try makeSource()
        let pending = try prepare(source)
        let context = reviewContext(pending)
        let decidedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let acknowledged = try AssessmentHumanReviewWorkflow.acknowledgeForPlanning(
            pending,
            note: "Acknowledge the assessment as bounded advice for future planning.",
            context: context,
            report: source.report,
            recommendationSet: source.recommendationSet,
            now: decidedAt
        )

        XCTAssertEqual(acknowledged.status, .acknowledgedForPlanning)
        XCTAssertEqual(acknowledged.decision?.disposition, .acknowledgeForPlanning)
        XCTAssertEqual(acknowledged.decision?.reviewerID, context.reviewerID)
        XCTAssertEqual(acknowledged.decision?.reviewedRecommendationIDs, pending.recommendationIDs)
        XCTAssertEqual(acknowledged.decision?.sourceClaimIDs, pending.sourceClaimIDs)
        XCTAssertEqual(acknowledged.decision?.authority, .advisoryReviewOnly)
        XCTAssertEqual(acknowledged.decision?.submissionBinding, context.submissionBinding)
        assertNoAuthority(acknowledged)
        XCTAssertTrue(acknowledged.markdown().contains("advice for future planning only"))
        XCTAssertTrue(AssessmentHumanReviewWorkflow.validate(
            acknowledged,
            against: source.recommendationSet,
            report: source.report
        ).isEmpty)

        XCTAssertThrowsError(try AssessmentHumanReviewWorkflow.acknowledgeForPlanning(
            acknowledged,
            context: context,
            report: source.report,
            recommendationSet: source.recommendationSet,
            now: decidedAt.addingTimeInterval(1)
        )) {
            XCTAssertEqual($0 as? AssessmentHumanReviewFailure, .reviewNotPending)
        }
    }

    func testChangeRequestRequiresInstructionsAndStaleBindingFailsClosed() throws {
        let source = try makeSource()
        let pending = try prepare(source)
        let context = reviewContext(pending)

        XCTAssertThrowsError(try AssessmentHumanReviewWorkflow.requestChanges(
            pending,
            instructions: "   ",
            context: context,
            report: source.report,
            recommendationSet: source.recommendationSet
        )) {
            XCTAssertEqual($0 as? AssessmentHumanReviewFailure, .reviewerNoteRequired)
        }

        var stale = context
        stale.submissionBinding.taskID = UUID()
        XCTAssertThrowsError(try AssessmentHumanReviewWorkflow.reject(
            pending,
            context: stale,
            report: source.report,
            recommendationSet: source.recommendationSet
        )) {
            XCTAssertEqual($0 as? AssessmentHumanReviewFailure, .bindingMismatch)
        }

        let changed = try AssessmentHumanReviewWorkflow.requestChanges(
            pending,
            instructions: "Collect direct authentication and authorization evidence, then recompose the report.",
            context: context,
            report: source.report,
            recommendationSet: source.recommendationSet,
            now: Date(timeIntervalSince1970: 1_700_000_101)
        )
        XCTAssertEqual(changed.status, .changesRequested)
        XCTAssertEqual(changed.decision?.disposition, .requestChanges)
        XCTAssertEqual(
            changed.decision?.reviewerNote,
            "Collect direct authentication and authorization evidence, then recompose the report."
        )
        assertNoAuthority(changed)
    }

    func testReviewValidationRejectsAuthorityScopeAndDecisionTampering() throws {
        let source = try makeSource()
        let pending = try prepare(source)
        var authorityTamper = pending
        authorityTamper.executionAuthorized = true
        XCTAssertTrue(AssessmentHumanReviewWorkflow.validate(
            authorityTamper,
            against: source.recommendationSet,
            report: source.report
        ).contains { $0.code == .invalidAuthority })

        var scopeTamper = pending
        scopeTamper.recommendationIDs.removeLast()
        XCTAssertTrue(AssessmentHumanReviewWorkflow.validate(
            scopeTamper,
            against: source.recommendationSet,
            report: source.report
        ).contains { $0.code == .recommendationScopeMismatch })

        let context = reviewContext(pending)
        var acknowledged = try AssessmentHumanReviewWorkflow.acknowledgeForPlanning(
            pending,
            context: context,
            report: source.report,
            recommendationSet: source.recommendationSet,
            now: Date(timeIntervalSince1970: 1_700_000_102)
        )
        acknowledged.decision?.sourceClaimIDs = ["invented-claim"]
        XCTAssertTrue(AssessmentHumanReviewWorkflow.validate(
            acknowledged,
            against: source.recommendationSet,
            report: source.report
        ).contains {
            $0.code == .invalidReviewState || $0.code == .decisionIdentityMismatch
        })
    }

    func testPersistenceAndEventProjectionRestoreExactFinalDisposition() throws {
        let source = try makeSource()
        let pending = try prepare(source)
        let reviewed = try AssessmentHumanReviewWorkflow.reject(
            pending,
            note: "The advisory set is not suitable for the requested scope.",
            context: reviewContext(pending),
            report: source.report,
            recommendationSet: source.recommendationSet,
            now: Date(timeIntervalSince1970: 1_700_000_103)
        )
        XCTAssertEqual(reviewed.status, .rejected)
        XCTAssertEqual(reviewed.decision?.disposition, .rejectRecommendations)
        XCTAssertEqual(
            reviewed.decision?.reviewerNote,
            "The advisory set is not suitable for the requested scope."
        )
        let payload = try reviewed.persistenceEventPayload()
        let reloaded = try AssessmentHumanReviewRecord.reload(from: payload)
        XCTAssertEqual(reloaded, reviewed)
        XCTAssertEqual(payload["assessment_human_review_execution_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_approval_request_created"], "false")
        XCTAssertEqual(payload["assessment_human_review_approval_queue_authority_created"], "false")
        XCTAssertEqual(payload["assessment_human_review_candidate_patch_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_eval_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_execution_admission_granted"], "false")
        XCTAssertEqual(payload["assessment_human_review_validation_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_mutation_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_shell_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_git_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_deployment_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_production_access_authorized"], "false")
        XCTAssertEqual(payload["assessment_human_review_mission_id"], pending.missionID.uuidString)
        XCTAssertEqual(
            payload["assessment_human_review_source_report_sha256"],
            pending.sourceDigests.reportSHA256
        )
        XCTAssertEqual(
            payload["assessment_human_review_recommendation_set_sha256"],
            pending.sourceDigests.recommendationSetSHA256
        )
        assertNoAuthority(reviewed)

        let projection = AssessmentHumanReviewProjector.project(events: try sourceEvents(
            source: source,
            reviewPayload: payload
        ))
        XCTAssertTrue(projection.failures.isEmpty)
        XCTAssertEqual(projection.bundles.count, 1)
        XCTAssertEqual(projection.bundles.first?.review, reviewed)
        XCTAssertEqual(projection.bundles.first?.recommendationSet, source.recommendationSet)
    }

    func testEveryArtifactAndMissionBindingDimensionFailsClosed() throws {
        let source = try makeSource()
        let pending = try prepare(source)
        let base = reviewContext(pending)
        let mutations: [(String, (inout AssessmentHumanReviewContext) -> Void)] = [
            ("workspace", { $0.submissionBinding.workspaceID = UUID() }),
            ("Mission", { $0.submissionBinding.missionID = UUID() }),
            ("task", { $0.submissionBinding.taskID = UUID() }),
            ("Agent session", { $0.submissionBinding.agentSessionID = UUID() }),
            ("report", { $0.submissionBinding.sourceReportID += "-stale" }),
            ("report digest", { $0.submissionBinding.sourceReportSHA256 = String(repeating: "0", count: 64) }),
            ("recommendation set", { $0.submissionBinding.recommendationSetID += "-stale" }),
            ("recommendation digest", { $0.submissionBinding.recommendationSetSHA256 = String(repeating: "0", count: 64) }),
            ("review", { $0.submissionBinding.reviewID += "-stale" }),
            ("authenticated session", {
                $0.submissionBinding.authenticatedLocalSessionID = UUID()
            }),
            ("workspace session", {
                $0.submissionBinding.workspaceSessionID = UUID(
                    uuidString: "00000000-0000-0000-0000-000000000000"
                )!
            }),
            ("app session", {
                $0.submissionBinding.appSessionID = UUID(
                    uuidString: "00000000-0000-0000-0000-000000000000"
                )!
            })
        ]

        for (dimension, mutate) in mutations {
            var stale = base
            mutate(&stale)
            XCTAssertThrowsError(try AssessmentHumanReviewWorkflow.reject(
                pending,
                context: stale,
                report: source.report,
                recommendationSet: source.recommendationSet
            ), "Expected \(dimension) drift to fail closed") {
                XCTAssertEqual($0 as? AssessmentHumanReviewFailure, .bindingMismatch)
            }
        }
    }

    func testSourceDigestAndFinalSessionTamperingFailClosed() throws {
        let source = try makeSource()
        let pending = try prepare(source)
        var sourceTamper = pending
        sourceTamper.sourceDigests.reportSHA256 = String(repeating: "0", count: 64)
        XCTAssertTrue(AssessmentHumanReviewWorkflow.validate(
            sourceTamper,
            against: source.recommendationSet,
            report: source.report
        ).contains { $0.code == .sourceIdentityMismatch })

        var finalized = try AssessmentHumanReviewWorkflow.acknowledgeForPlanning(
            pending,
            context: reviewContext(pending),
            report: source.report,
            recommendationSet: source.recommendationSet,
            now: Date(timeIntervalSince1970: 1_700_000_106)
        )
        finalized.decision?.submissionBinding.appSessionID = UUID()
        XCTAssertTrue(AssessmentHumanReviewWorkflow.validate(
            finalized,
            against: source.recommendationSet,
            report: source.report
        ).contains { $0.code == .decisionIdentityMismatch })
        XCTAssertThrowsError(try finalized.persistenceEventPayload()) {
            XCTAssertEqual($0 as? AssessmentHumanReviewFailure, .invalidReviewRecord)
        }
    }

    func testInvalidOrDuplicateHistoricalSourcesCreateNoReviewAuthority() throws {
        let source = try makeSource()
        var invalidEvents = try sourceEvents(source: source)
        invalidEvents[0].payload["assessment_report_sha256"] = String(repeating: "0", count: 64)
        let invalid = AssessmentHumanReviewProjector.project(events: invalidEvents)
        XCTAssertTrue(invalid.bundles.isEmpty)
        XCTAssertTrue(invalid.failures.contains(.invalidSourceReport))

        var duplicateEvents = try sourceEvents(source: source)
        duplicateEvents.append(duplicateEvents[0])
        let duplicate = AssessmentHumanReviewProjector.project(events: duplicateEvents)
        XCTAssertTrue(duplicate.bundles.isEmpty)
        XCTAssertTrue(duplicate.failures.contains(.duplicateSourceReport))
    }

    func testReviewEventHasNoApprovalOrRuntimeAuthorityConsumer() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let workflow = try String(contentsOf: root.appendingPathComponent(
            "Sources/FDECloudOS/Core/Assessment/AssessmentHumanReviewWorkflow.swift"
        ))
        let appStore = try String(contentsOf: root.appendingPathComponent(
            "Sources/FDECloudOS/App/AppStore.swift"
        ))
        let runtime = try String(contentsOf: root.appendingPathComponent(
            "Sources/FDECloudOS/Core/Runtime/RuntimeKernel.swift"
        ))
        let missionUI = try String(contentsOf: root.appendingPathComponent(
            "Sources/FDECloudOS/UI/Components/MissionPresentationView.swift"
        ))
        let reviewStart = try XCTUnwrap(appStore.range(of: "func reviewAssessmentRecommendations("))
        let reviewTail = appStore[reviewStart.lowerBound...]
        let nextFunction = try XCTUnwrap(reviewTail.range(of: "func reviewProductionReadiness("))
        let reviewFunction = String(reviewTail[..<nextFunction.lowerBound])

        XCTAssertFalse(workflow.contains("ApprovalRequest("))
        XCTAssertFalse(workflow.contains("ApprovalQueue("))
        XCTAssertFalse(reviewFunction.contains("environment.runtime.approve"))
        XCTAssertFalse(reviewFunction.contains("environment.runtime.confirm"))
        XCTAssertFalse(reviewFunction.contains("runCandidatePatch"))
        XCTAssertFalse(reviewFunction.contains("runSafeSandbox"))
        XCTAssertTrue(reviewFunction.contains("recordAuditEvent"))
        XCTAssertFalse(runtime.contains("AI_ASSESSMENT_HUMAN_REVIEW_RECORDED"))
        XCTAssertTrue(missionUI.contains("Phase 3B Controlled Rollout and production deployment remain unavailable."))
    }

    func testProjectionDerivesOnePendingReviewFromExactSourceEvents() throws {
        let source = try makeSource()
        let projection = AssessmentHumanReviewProjector.project(
            events: try sourceEvents(source: source)
        )

        XCTAssertTrue(projection.failures.isEmpty)
        XCTAssertEqual(projection.bundles.count, 1)
        XCTAssertEqual(projection.bundles.first?.review.status, .awaitingReview)
        XCTAssertNil(projection.bundles.first?.review.decision)
        XCTAssertFalse(projection.bundles.first?.review.executionAuthorized ?? true)
    }

    func testProjectionAcceptsOpenedThenOneAppendOnlyFinalDisposition() throws {
        let source = try makeSource()
        let pending = try prepare(source)
        let reviewed = try AssessmentHumanReviewWorkflow.acknowledgeForPlanning(
            pending,
            context: reviewContext(pending),
            report: source.report,
            recommendationSet: source.recommendationSet,
            now: Date(timeIntervalSince1970: 1_700_000_105)
        )
        var events = try sourceEvents(
            source: source,
            reviewPayload: pending.persistenceEventPayload()
        )
        events.append(ExecutionEvent(
            id: uuid("00000000-0000-0000-0000-000000000523"),
            parentEventID: nil,
            workspaceID: source.context.workspaceID,
            taskID: source.context.taskID,
            type: .stateUpdated,
            sequence: 13,
            timestamp: Date(timeIntervalSince1970: 1_700_000_013),
            summary: "Assessment human review finalized.",
            payload: try reviewed.persistenceEventPayload()
        ))

        let projection = AssessmentHumanReviewProjector.project(events: events)
        XCTAssertTrue(projection.failures.isEmpty)
        XCTAssertEqual(projection.bundles.map(\.review), [reviewed])
    }

    func testTamperedPersistedDecisionCannotReopenAsPendingReview() throws {
        let source = try makeSource()
        let pending = try prepare(source)
        let reviewed = try AssessmentHumanReviewWorkflow.acknowledgeForPlanning(
            pending,
            context: reviewContext(pending),
            report: source.report,
            recommendationSet: source.recommendationSet,
            now: Date(timeIntervalSince1970: 1_700_000_104)
        )
        var tampered = try reviewed.persistenceEventPayload()
        tampered["assessment_human_review_sha256"] = String(repeating: "0", count: 64)

        XCTAssertThrowsError(try AssessmentHumanReviewRecord.reload(from: tampered)) {
            XCTAssertEqual($0 as? AssessmentHumanReviewFailure, .persistenceDigestMismatch)
        }
        let projection = AssessmentHumanReviewProjector.project(events: try sourceEvents(
            source: source,
            reviewPayload: tampered
        ))
        XCTAssertTrue(projection.bundles.isEmpty)
        XCTAssertTrue(projection.failures.contains(.invalidReviewRecord))
    }

    func testConversationAndWorkspaceExposeDistinctAdvisoryReviewSurface() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let conversation = try String(contentsOf: root.appendingPathComponent(
            "Sources/FDECloudOS/UI/Components/AgentConversationView.swift"
        ))
        let workspace = try String(contentsOf: root.appendingPathComponent(
            "Sources/FDECloudOS/UI/Components/AgentWorkspaceConsolidationViews.swift"
        ))
        let runtime = try String(contentsOf: root.appendingPathComponent(
            "Sources/FDECloudOS/Core/Runtime/RuntimeKernel.swift"
        ))

        XCTAssertTrue(conversation.contains("AssessmentHumanReviewCard"))
        XCTAssertTrue(conversation.contains("Acknowledgement accepts this assessment as advice for future planning"))
        XCTAssertTrue(conversation.contains("No execution is authorized"))
        XCTAssertTrue(conversation.contains("No code change is authorized"))
        XCTAssertTrue(conversation.contains("No deployment is authorized"))
        XCTAssertTrue(conversation.contains("Finalized read-only history"))
        XCTAssertTrue(workspace.contains("Acknowledge assessment"))
        XCTAssertTrue(workspace.contains("Request assessment changes"))
        XCTAssertTrue(workspace.contains("Reject assessment"))
        XCTAssertFalse(workspace.contains("Accept advisory"))
        XCTAssertFalse(runtime.contains("AI_ASSESSMENT_HUMAN_REVIEW_RECORDED"))
    }

    private struct Source {
        var report: FDEAIIntegrationAssessmentReport
        var recommendationSet: AssessmentRecommendationSet
        var context: AssessmentReportCompositionContext
    }

    private func prepare(_ source: Source) throws -> AssessmentHumanReviewRecord {
        try AssessmentHumanReviewWorkflow.prepare(
            report: source.report,
            recommendationSet: source.recommendationSet
        )
    }

    private func reviewContext(
        _ record: AssessmentHumanReviewRecord
    ) -> AssessmentHumanReviewContext {
        AssessmentHumanReviewContext(
            record: record,
            missionID: record.missionID,
            authenticatedLocalSessionID: uuid("00000000-0000-0000-0000-000000000504"),
            workspaceSessionID: uuid("00000000-0000-0000-0000-000000000505"),
            appSessionID: uuid("00000000-0000-0000-0000-000000000506")
        )
    }

    private func assertNoAuthority(
        _ record: AssessmentHumanReviewRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(record.approvalGranted, file: file, line: line)
        XCTAssertFalse(record.executionApprovalGranted, file: file, line: line)
        XCTAssertFalse(record.approvalRequestCreated, file: file, line: line)
        XCTAssertFalse(record.candidatePatchAuthorized, file: file, line: line)
        XCTAssertFalse(record.evalAuthorized, file: file, line: line)
        XCTAssertFalse(record.executionAdmissionGranted, file: file, line: line)
        XCTAssertFalse(record.validationAuthorized, file: file, line: line)
        XCTAssertFalse(record.mutationAuthorized, file: file, line: line)
        XCTAssertFalse(record.shellAuthorized, file: file, line: line)
        XCTAssertFalse(record.gitAuthorized, file: file, line: line)
        XCTAssertFalse(record.deploymentAuthorized, file: file, line: line)
        XCTAssertFalse(record.productionAccessAuthorized, file: file, line: line)
        XCTAssertFalse(record.executionAuthorized, file: file, line: line)
        XCTAssertFalse(record.decision?.approvalRequestCreated ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.candidatePatchAuthorized ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.evalAuthorized ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.executionAdmissionGranted ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.validationAuthorized ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.mutationAuthorized ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.shellAuthorized ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.gitAuthorized ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.deploymentAuthorized ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.productionAccessAuthorized ?? true, file: file, line: line)
        XCTAssertFalse(record.decision?.executionAuthorized ?? true, file: file, line: line)
    }

    private func makeSource() throws -> Source {
        let workspaceID = uuid("00000000-0000-0000-0000-000000000501")
        let taskID = uuid("00000000-0000-0000-0000-000000000502")
        let sessionID = uuid("00000000-0000-0000-0000-000000000503")
        let calledID = uuid("00000000-0000-0000-0000-000000000510")
        let resultID = uuid("00000000-0000-0000-0000-000000000511")
        let evidence = ReadOnlyInspectionEvidence(
            toolCallID: "read-manifest",
            toolName: "engineering.read_file",
            workspaceID: workspaceID,
            workspaceIdentity: "legacy",
            targetPath: "package.json",
            output: #"{"name":"legacy","dependencies":{"express":"1.0.0"}}"#,
            toolCalledEventID: calledID,
            toolResultEventID: resultID
        )
        let requirements = try XCTUnwrap(ReadOnlyEvidenceRequirements(
            planRequirementIDs: [ReadOnlyEvidenceRequirementKind.projectManifest.rawValue]
        ))
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: [evidence]
        )
        let reference = AssessmentEvidenceReference(
            source: .extractedConfiguration,
            workspaceIdentity: "legacy",
            path: "package.json",
            fact: "The inspected manifest declares the express dependency.",
            claimLevel: .configurationConfirmed,
            observationStatus: .directlyRead,
            sourceComponent: "package.json",
            safeEvidenceSummary: "package.json declares dependency express.",
            lineRange: "1-1",
            workspaceSnapshotIdentifier: "workspace-\(workspaceID.uuidString.lowercased())",
            relatedToolEventID: resultID
        )
        func claim(_ id: String, _ statement: String) -> AssessmentClaim {
            AssessmentClaim(
                claimID: id,
                statement: statement,
                evidence: [reference],
                confidence: .high,
                unknowns: ["Runtime behavior remains unverified."]
            )
        }
        let summary = claim("review-summary", "The manifest provides one bounded static assessment fact.")
        let unknown = claim("review-unknown", "Authentication is not established by the inspected manifest.")
        let risk = claim("review-risk", "Permission enforcement is not established by the inspected manifest.")
        let recommendation = claim("review-design", "A mediated service boundary should be investigated.")
        let context = AssessmentReportCompositionContext(
            workspaceID: workspaceID,
            taskID: taskID,
            sessionID: sessionID,
            requestedCapability: AgentCapabilityProfile(
                kind: .unspecified,
                requiredCapabilities: [
                    AgentCapabilityRequirement(
                        capability: .authenticationBoundary,
                        required: true,
                        critical: true,
                        rationale: "Required by the Phase 3B.5 fixture."
                    )
                ],
                proposesWriteAccess: false
            ),
            scopeDescription: "Bounded Phase 3B.5 human-review fixture."
        )
        let placements = [
            AssessmentReportClaimPlacement(
                claim: summary,
                section: .executiveSummary,
                disposition: .advisory
            ),
            AssessmentReportClaimPlacement(
                claim: unknown,
                section: .capabilityCompatibility,
                disposition: .unknown,
                capability: .authenticationBoundary
            ),
            AssessmentReportClaimPlacement(
                claim: unknown,
                section: .unknown,
                disposition: .unknown,
                required: true,
                capability: .authenticationBoundary
            ),
            AssessmentReportClaimPlacement(
                claim: risk,
                section: .securityAndAuthorization,
                disposition: .partial,
                riskLevel: .medium,
                riskDomain: .permission
            ),
            AssessmentReportClaimPlacement(
                claim: recommendation,
                section: .recommendation,
                disposition: .advisory,
                title: "Mediated service boundary",
                integrationPath: ["AI Agent", "Permission-aware adapter", "Legacy API"],
                architectureComponents: ["Permission-aware adapter"]
            )
        ]
        let sourceEvents = [
            ExecutionEvent(
                id: calledID,
                parentEventID: nil,
                workspaceID: workspaceID,
                taskID: taskID,
                type: .toolCalled,
                sequence: 1,
                timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                summary: "Read-only tool called.",
                payload: [
                    "lifecycle_event": ExecutionPlanLifecycleEvent.toolCalled.rawValue,
                    "tool_call_id": evidence.toolCallID
                ]
            ),
            ExecutionEvent(
                id: resultID,
                parentEventID: calledID,
                workspaceID: workspaceID,
                taskID: taskID,
                type: .stepExecuted,
                sequence: 2,
                timestamp: Date(timeIntervalSince1970: 1_700_000_002),
                summary: "Read-only tool result recorded.",
                payload: [
                    "lifecycle_event": ExecutionPlanLifecycleEvent.toolResult.rawValue,
                    "tool_call_id": evidence.toolCallID,
                    "success": "true",
                    "evidence_eligible": "true"
                ]
            )
        ]
        let composition = AssessmentReportComposer.compose(
            context: context,
            claims: placements,
            evidenceLedger: ledger,
            evidence: [evidence],
            executionEvents: sourceEvents
        )
        let report = try XCTUnwrap(composition.report)
        let recommendationSet = try XCTUnwrap(
            AssessmentRecommendationEngine.generate(from: report).recommendationSet
        )
        return Source(report: report, recommendationSet: recommendationSet, context: context)
    }

    private func sourceEvents(
        source: Source,
        reviewPayload: [String: String]? = nil
    ) throws -> [ExecutionEvent] {
        let reportPayload = try source.report.persistenceEventPayload()
        let recommendationPayload = try source.recommendationSet.persistenceEventPayload()
        var values = [
            ExecutionEvent(
                id: uuid("00000000-0000-0000-0000-000000000520"),
                parentEventID: nil,
                workspaceID: source.context.workspaceID,
                taskID: source.context.taskID,
                type: .stateUpdated,
                sequence: 10,
                timestamp: Date(timeIntervalSince1970: 1_700_000_010),
                summary: "Assessment report composed.",
                payload: reportPayload
            ),
            ExecutionEvent(
                id: uuid("00000000-0000-0000-0000-000000000521"),
                parentEventID: nil,
                workspaceID: source.context.workspaceID,
                taskID: source.context.taskID,
                type: .stateUpdated,
                sequence: 11,
                timestamp: Date(timeIntervalSince1970: 1_700_000_011),
                summary: "Assessment recommendations generated.",
                payload: recommendationPayload
            )
        ]
        if let reviewPayload {
            values.append(ExecutionEvent(
                id: uuid("00000000-0000-0000-0000-000000000522"),
                parentEventID: nil,
                workspaceID: source.context.workspaceID,
                taskID: source.context.taskID,
                type: .stateUpdated,
                sequence: 12,
                timestamp: Date(timeIntervalSince1970: 1_700_000_012),
                summary: "Assessment human review recorded.",
                payload: reviewPayload
            ))
        }
        return values
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
