import XCTest
@testable import FDECloudOS

final class AssessmentHandoffRegressionTests: XCTestCase {
    func testSyntheticAssessmentFinalizesNormallyPersistsExactHandoffAndCandidatePatchAwaitsApproval() async throws {
        let fixture = try await makeFixture(includeFinalization: true)
        defer { fixture.cleanup() }

        var assessmentSession = AgentSession(workspace: fixture.workspace, userGoal: fixture.assessmentInput)
        let assessmentResult = try await AgentRuntimeCoordinator().startMission(
            input: fixture.assessmentInput,
            workspace: fixture.workspace,
            session: &assessmentSession,
            runtime: fixture.kernel
        )
        let assessmentTask = try XCTUnwrap(assessmentResult.task)
        XCTAssertEqual(assessmentTask.state, .completed)

        let assessmentEvents = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: assessmentTask.id
        )
        let taskCreated = try XCTUnwrap(assessmentEvents.first { $0.type == .taskCreated })
        XCTAssertEqual(taskCreated.payload["mission_workspace_scope"], MissionWorkspaceScope.legacyOnly.rawValue)
        let contextCompiled = try XCTUnwrap(assessmentEvents.first { $0.type == .contextCompiled })
        XCTAssertEqual(contextCompiled.payload["mission_workspace_scope"], MissionWorkspaceScope.legacyOnly.rawValue)
        XCTAssertEqual(contextCompiled.payload["legacy_project_root"], fixture.workspace.localProjectRoot)
        XCTAssertEqual(contextCompiled.payload["agent_project_root"], "")
        let toolEvents = assessmentEvents.filter { $0.type == .toolCalled || $0.type == .stepExecuted }
        XCTAssertFalse(toolEvents.isEmpty)
        XCTAssertTrue(toolEvents.allSatisfy { $0.payload["workspace_identity"] == "legacy" })
        XCTAssertTrue(toolEvents.allSatisfy { $0.payload["trusted_workspace_root"] == fixture.workspace.localProjectRoot })
        XCTAssertFalse(toolEvents.contains { $0.summary.contains("Agent workspace") })
        let normalFallbackEvents = assessmentEvents.filter {
            $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_FALLBACK"
        }
        XCTAssertTrue(normalFallbackEvents.isEmpty, "Unexpected normal-finalization fallback: \(normalFallbackEvents)")
        let completed = try XCTUnwrap(assessmentEvents.last { $0.type == .taskCompleted })
        let report = try XCTUnwrap(completed.payload["detail"])
        XCTAssertTrue(report.contains("customer_support_order_lookup"))
        XCTAssertTrue(report.contains("Customer Support AI Agent — Read-only Order Lookup"))
        XCTAssertTrue(report.contains("src/orders.ts"))
        XCTAssertTrue(report.contains("src/auth.ts"))
        XCTAssertTrue(report.contains("src/audit.ts"))
        XCTAssertTrue(report.contains("docs/architecture.md"))
        XCTAssertTrue(report.contains("config/app.example.json"))
        XCTAssertTrue(report.contains("证据声明 ID"))

        let persisted = try XCTUnwrap(assessmentEvents.last {
            $0.payload["lifecycle_event"] == "AI_ASSESSMENT_PERSISTED"
        })
        XCTAssertGreaterThan(persisted.sequence, completed.sequence)
        XCTAssertEqual(persisted.payload["task_state"], TaskState.completed.rawValue)
        XCTAssertEqual(
            persisted.payload["normalized_requested_capability_id"],
            AIAgentCapabilityKind.customerSupportOrderLookup.rawValue
        )
        XCTAssertEqual(persisted.payload["source_snapshot_id"], fixture.inspection.sourceManifest.snapshotID)
        XCTAssertFalse(persisted.payload["evidence_claim_ids"]?.isEmpty ?? true)
        XCTAssertFalse(persisted.payload["supported_capabilities"]?.isEmpty ?? true)
        XCTAssertFalse(persisted.payload["assessment_blockers"]?.isEmpty ?? true)
        XCTAssertEqual(persisted.payload["assessment_finalization_mode"], "normal")
        XCTAssertEqual(persisted.payload["assessment_validation_status"], "validated")
        XCTAssertEqual(persisted.payload["canonical_legacy_root"], fixture.workspace.localProjectRoot)
        XCTAssertTrue(persisted.payload["evidence_paths"]?.contains("src/orders.ts") == true)
        let persistedContext = try decodeAssessmentContext(persisted)
        XCTAssertEqual(persistedContext.finalizationMode, .normal)
        XCTAssertEqual(persistedContext.validationStatus, .validated)
        let structuredValidationPlan = try XCTUnwrap(persistedContext.validationTestPlan)
        XCTAssertFalse(structuredValidationPlan.items.isEmpty)
        XCTAssertFalse(structuredValidationPlan.executionAuthorized)
        XCTAssertTrue(structuredValidationPlan.items.allSatisfy {
            !$0.validationItemID.isEmpty
                && !$0.title.isEmpty
                && !$0.purpose.isEmpty
                && !$0.expectedBehavior.isEmpty
                && $0.runtimeVerificationStatus == .notVerified
        })
        XCTAssertEqual(
            persisted.payload["validation_test_plan_sha256"],
            CandidatePatchArtifactAuthority.validationTestPlanSHA256(structuredValidationPlan)
        )
        XCTAssertEqual(
            persisted.payload["validation_test_plan_item_count"],
            String(structuredValidationPlan.items.count)
        )
        XCTAssertEqual(persisted.payload["validation_test_execution_authorized"], "false")
        XCTAssertTrue(report.contains(persistedContext.requestedCapabilityID))
        XCTAssertTrue(report.contains(persistedContext.requestedCapabilityDisplayLabel))

        let sandboxWorkspace = fixture.storageRoot
            .appendingPathComponent(fixture.inspection.descriptor.sandboxID.rawValue, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        let candidateTarget = sandboxWorkspace.appendingPathComponent(
            "src/fde-customer-support-order-lookup.ts"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateTarget.path))

        let activeSandboxesBeforePlanning = try fixture.kernelSandboxCount()
        let candidateInput = "基于刚刚完成并验证的评估，为客户支持 AI Agent 的只读订单查询创建 Candidate Patch 修改计划。"
        var candidateSession = AgentSession(workspace: fixture.workspace, userGoal: candidateInput)
        let candidateResult = try await AgentRuntimeCoordinator().startMission(
            input: candidateInput,
            workspace: fixture.workspace,
            session: &candidateSession,
            runtime: fixture.kernel
        )
        let candidateTask = try XCTUnwrap(candidateResult.task)
        XCTAssertEqual(candidateTask.state, .pendingApproval)
        XCTAssertEqual(try fixture.kernelSandboxCount(), activeSandboxesBeforePlanning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateTarget.path))
        let candidateEvents = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: candidateTask.id
        )
        let approval = try XCTUnwrap(candidateEvents.last { $0.type == .humanApprovalRequested })
        XCTAssertEqual(approval.payload["workspace_mutation_count"], "0")
        XCTAssertEqual(approval.payload["candidate_patch_status"], CandidatePatchStatus.awaitingApproval.rawValue)
        XCTAssertEqual(approval.payload["sandbox_readiness_checked"], "false")
        XCTAssertEqual(approval.payload["unified_diff_exists"], "false")
        for key in [
            "legacy_writes", "sandbox_writes", "patch_files_created", "build_test_executions",
            "shell_calls", "git_operations", "deployment_operations"
        ] {
            XCTAssertEqual(approval.payload[key], "0", key)
        }
        XCTAssertFalse(candidateEvents.contains {
            $0.payload["candidate_patch_activity_phase"] == CandidatePatchActivityPhase.checkingSandboxReadiness.rawValue
        })
        let plan = try XCTUnwrap(approval.payload["detail"])
        XCTAssertTrue(plan.contains("# Candidate Patch Plan"))
        XCTAssertTrue(plan.contains("src/fde-customer-support-order-lookup.ts"))
        XCTAssertTrue(plan.contains("Record Level Authorization"))
        XCTAssertTrue(plan.contains("Sensitive Response Field Controls"))
        XCTAssertTrue(plan.contains("customer_support_order_lookup"))
        XCTAssertTrue(plan.contains("No patch bytes or Unified Diff exist"))
        let pendingApprovals = try await fixture.persistence.loadApprovalRequests(
            workspaceID: fixture.workspace.id,
            state: .pending
        )
        XCTAssertEqual(pendingApprovals.count, 1)
        XCTAssertEqual(pendingApprovals[0].targetKind, .candidatePatchPlan)
        XCTAssertTrue(
            pendingApprovals[0].metadata["candidate_patch_plan_summary"]?
                .contains(pendingApprovals[0].id.uuidString) == true
        )
        let candidateManifest = try XCTUnwrap(
            CandidatePatchManifestStore(
                lifecycle: SandboxLifecycleService(storageRoot: fixture.storageRoot)
            ).loadAll().first { $0.plan.approvalRequestID == pendingApprovals[0].id }
        )
        XCTAssertEqual(candidateManifest.plan.assessmentContext?.validationTestPlan, structuredValidationPlan)
        XCTAssertEqual(
            candidateManifest.validationTestPlanSHA256,
            CandidatePatchArtifactAuthority.validationTestPlanSHA256(structuredValidationPlan)
        )
        XCTAssertEqual(candidateManifest.plan.validationTestPlanSHA256, candidateManifest.validationTestPlanSHA256)

        let mismatchedInput = "基于刚刚的销售 Agent 评估，创建 Candidate Patch 修改计划。"
        var mismatchedSession = AgentSession(workspace: fixture.workspace, userGoal: mismatchedInput)
        let mismatchedResult = try await AgentRuntimeCoordinator().startMission(
            input: mismatchedInput,
            workspace: fixture.workspace,
            session: &mismatchedSession,
            runtime: fixture.kernel
        )
        let mismatchedTask = try XCTUnwrap(mismatchedResult.task)
        XCTAssertEqual(mismatchedTask.state, .failed)
        let mismatchedEvents = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: mismatchedTask.id
        )
        XCTAssertEqual(
            mismatchedEvents.last { $0.payload["failure_category"] != nil }?.payload["failure_category"],
            CandidatePatchFailureCode.assessmentCapabilityMismatch.rawValue
        )
    }

    func testAssessmentFallbackPreservesCapabilityConcreteEvidenceAndReadableDecision() async throws {
        let fixture = try await makeFixture(includeFinalization: false)
        defer { fixture.cleanup() }
        var session = AgentSession(workspace: fixture.workspace, userGoal: fixture.assessmentInput)

        let result = try await AgentRuntimeCoordinator().startMission(
            input: fixture.assessmentInput,
            workspace: fixture.workspace,
            session: &session,
            runtime: fixture.kernel
        )

        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.state, .completed)
        let events = try await fixture.persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
        XCTAssertTrue(events.contains { $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_FALLBACK" })
        let final = try XCTUnwrap(events.last { $0.type == .taskCompleted }?.payload["detail"])
        XCTAssertTrue(final.contains("customer_support_order_lookup"))
        XCTAssertTrue(final.contains("src/orders.ts"))
        XCTAssertTrue(final.contains("src/auth.ts"))
        XCTAssertTrue(final.contains("src/audit.ts"))
        XCTAssertTrue(final.contains("### 4.1"))
        XCTAssertTrue(final.contains("证据声明 ID"))
        XCTAssertTrue(final.contains("**SUPPORTED**") || final.contains("**BLOCKED**") || final.contains("**UNKNOWN**"))
        let persisted = try XCTUnwrap(events.last {
            $0.payload["lifecycle_event"] == "AI_ASSESSMENT_PERSISTED"
        })
        let persistedContext = try decodeAssessmentContext(persisted)
        XCTAssertEqual(persistedContext.finalizationMode, .fallback)
        XCTAssertEqual(persistedContext.validationStatus, .validated)
        XCTAssertFalse(try XCTUnwrap(persistedContext.validationTestPlan).items.isEmpty)
        XCTAssertTrue(final.contains(persistedContext.requestedCapabilityID))
        XCTAssertTrue(final.contains(persistedContext.requestedCapabilityDisplayLabel))
        XCTAssertFalse(persistedContext.evidenceClaimIDs.isEmpty)
    }

    func testNegatedCandidatePatchAssessmentCreatesNoPatchPlanApprovalSandboxOrArtifact() async throws {
        let fixture = try await makeFixture(includeFinalization: true)
        defer { fixture.cleanup() }
        let input = """
        Inspect the selected TestableLegacy project in read-only mode.

        Determine the test framework and grounded test location from repository evidence.

        Assess the customer_support_order_lookup capability.

        Do not modify files, create a Candidate Patch, run builds or tests, execute Shell or Git, install packages, deploy, or access credentials.
        """
        let activeSandboxesBefore = try fixture.kernelSandboxCount()
        var session = AgentSession(workspace: fixture.workspace, userGoal: input)

        let result = try await AgentRuntimeCoordinator().startMission(
            input: input,
            workspace: fixture.workspace,
            session: &session,
            runtime: fixture.kernel
        )

        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.state, .blocked)
        let events = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: task.id
        )
        let created = try XCTUnwrap(events.first { $0.type == .taskCreated })
        XCTAssertEqual(
            created.payload["intent_type"],
            MissionIntentType.aiAgentCompatibilityAssessment.rawValue
        )
        XCTAssertEqual(created.payload["mission_workspace_scope"], MissionWorkspaceScope.legacyOnly.rawValue)
        XCTAssertFalse(events.contains {
            $0.payload["intent_type"] == MissionIntentType.candidatePatchGeneration.rawValue
                || $0.payload["candidate_patch_activity_phase"] != nil
                || $0.type == .humanApprovalRequested
        })
        let pendingApprovals = try await fixture.persistence.loadApprovalRequests(
            workspaceID: fixture.workspace.id,
            state: .pending
        )
        XCTAssertTrue(pendingApprovals.isEmpty)
        XCTAssertEqual(try fixture.kernelSandboxCount(), activeSandboxesBefore)
        let manifests = try CandidatePatchManifestStore(
            lifecycle: SandboxLifecycleService(storageRoot: fixture.storageRoot)
        ).loadAll()
        XCTAssertTrue(manifests.isEmpty)
    }

    func testCanonicalCapabilityIDSurvivesApprovalKeywordDuringCandidatePatchHandoff() async throws {
        let fixture = try await makeFixture(includeFinalization: true)
        defer { fixture.cleanup() }
        var assessmentSession = AgentSession(workspace: fixture.workspace, userGoal: fixture.assessmentInput)
        let assessment = try await AgentRuntimeCoordinator().startMission(
            input: fixture.assessmentInput,
            workspace: fixture.workspace,
            session: &assessmentSession,
            runtime: fixture.kernel
        )
        XCTAssertEqual(try XCTUnwrap(assessment.task).state, .completed)

        let candidateInput = """
        Using the validated TestableLegacy assessment for the customer_support_order_lookup capability, prepare an evidence-grounded Candidate Patch.

        The Patch should address the validated record-level authorization and response-field allowlist findings.

        Create the Candidate Patch plan only. Do not apply changes until explicit approval.

        Keep the original Legacy read-only. Use only an app-managed Safe Sandbox for any later approved mutation.

        Do not run builds, tests, Shell, Git, package management, deployment, or credential access.
        """
        XCTAssertEqual(AIAgentCapabilityKind(request: candidateInput), .customerSupportOrderLookup)
        let activeSandboxesBefore = try fixture.kernelSandboxCount()
        var candidateSession = AgentSession(workspace: fixture.workspace, userGoal: candidateInput)
        let candidate = try await AgentRuntimeCoordinator().startMission(
            input: candidateInput,
            workspace: fixture.workspace,
            session: &candidateSession,
            runtime: fixture.kernel
        )

        let task = try XCTUnwrap(candidate.task)
        XCTAssertEqual(task.state, .pendingApproval)
        XCTAssertEqual(try fixture.kernelSandboxCount(), activeSandboxesBefore)
        let events = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: task.id
        )
        let approval = try XCTUnwrap(events.last { $0.type == .humanApprovalRequested })
        XCTAssertEqual(
            approval.payload["candidate_patch_capability_id"],
            AIAgentCapabilityKind.customerSupportOrderLookup.rawValue
        )
        XCTAssertFalse(events.contains {
            $0.payload["failure_category"] == CandidatePatchFailureCode.assessmentCapabilityMismatch.rawValue
        })
    }

    private func decodeAssessmentContext(_ event: ExecutionEvent) throws -> CandidatePatchAssessmentContext {
        let json = try XCTUnwrap(event.payload["candidate_patch_assessment_context"])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CandidatePatchAssessmentContext.self, from: data)
    }

    private struct Fixture {
        var workspace: Workspace
        var persistence: InMemoryPersistenceStore
        var kernel: RuntimeKernel
        var storageRoot: URL
        var inspection: SandboxInspection
        var assessmentInput: String

        func cleanup() {
            try? FileManager.default.removeItem(at: storageRoot.deletingLastPathComponent())
        }

        func kernelSandboxCount() throws -> Int {
            try SandboxLifecycleService(storageRoot: storageRoot).listActiveSandboxes().count
        }
    }

    private func makeFixture(includeFinalization: Bool) async throws -> Fixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let legacy = repositoryRoot.appendingPathComponent("demo/SyntheticLegacy", isDirectory: true)
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEAssessmentHandoff-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = container.appendingPathComponent("sandboxes", isDirectory: true)
        let lifecycle = SandboxLifecycleService(storageRoot: storageRoot)
        let inspection = try lifecycle.createSandbox(sourceRoot: legacy, approvedLegacyRoot: legacy)
        let workspace = Workspace(
            id: UUID(),
            name: "Synthetic assessment handoff",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacy.path,
            localAgentProjectRoot: repositoryRoot.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        var outputs: [StructuredAgentOutput] = [
            inspectionOutput(id: "inspect", command: "engineering.inspect_project"),
            inspectionOutput(id: "orders", command: "engineering.read_file", path: "src/orders.ts"),
            inspectionOutput(id: "auth", command: "engineering.read_file", path: "src/auth.ts"),
            inspectionOutput(id: "audit", command: "engineering.read_file", path: "src/audit.ts"),
            inspectionOutput(id: "architecture", command: "engineering.read_file", path: "docs/architecture.md"),
            inspectionOutput(id: "config", command: "engineering.read_file", path: "config/app.example.json")
        ]
        if includeFinalization {
            outputs.append(finalizationOutput("已完成所有相关只读证据检查；请生成一致的评估报告。"))
        }
        let provider = AssessmentSequenceProvider(outputs: outputs)
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [provider]),
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: lifecycle
        )
        return Fixture(
            workspace: workspace,
            persistence: persistence,
            kernel: kernel,
            storageRoot: storageRoot,
            inspection: inspection,
            assessmentInput: """
            请评估客户支持 AI Agent 的订单查询能力。

            请只读检查订单数据边界、API、身份验证、记录级授权、权限模型、审计日志、修改路径和敏感字段。

            本次只进行分析，不修改任何文件。
            """
        )
    }

    private func inspectionOutput(id: String, command: String, path: String? = nil) -> StructuredAgentOutput {
        let callID = "tool.\(id)"
        let arguments = path.map { ["workspace=legacy", "path=\($0)"] } ?? ["workspace=legacy", "path=."]
        return StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.\(id)",
                    title: id,
                    intent: "Inspect bounded Legacy evidence.",
                    kind: .tool,
                    toolCallID: callID,
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [
                ToolCall(
                    id: callID,
                    type: .api,
                    command: command,
                    arguments: arguments,
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            risks: [],
            confidence: 1
        )
    }

    private func finalizationOutput(_ answer: String) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "final",
                    title: "Grounded assessment",
                    intent: answer,
                    kind: .finalization,
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [],
            risks: [],
            confidence: 1
        )
    }
}

private actor AssessmentSequenceProvider: ModelProvider {
    nonisolated let kind: ModelProviderKind = .openAI
    nonisolated let isAvailable = true
    private var outputs: [StructuredAgentOutput]

    init(outputs: [StructuredAgentOutput]) {
        self.outputs = outputs
    }

    func generatePlan(for input: String, context: ExecutionContext) throws -> StructuredAgentOutput {
        guard !outputs.isEmpty else {
            throw ModelRoutingError.providerOutputInvalid("Synthetic assessment finalizer intentionally unavailable.")
        }
        return outputs.removeFirst()
    }
}
