import XCTest
@testable import FDECloudOS

final class Phase2EAdvisoryExecutionContractTests: XCTestCase {
    private let advisory = """
    如果我给你一个 Legacy 传统软件，和一个 AI Agent 的文件，
    你首先会检查什么？
    """

    private let execution = "现在开始只读检查我选中的 Legacy 和 Agent 项目。"

    func testAdvisoryQuestionProducesOneReplyAndZeroRuntimeAuthority() async throws {
        let workspace = Workspace.default()
        let runtime = Phase2ERuntime()
        let messageID = UUID()
        var session = AgentSession.newConversation(in: workspace)
        session.beginConversation(with: advisory, messageID: messageID, turnID: messageID)

        let result = try await AgentRuntimeCoordinator(chatProvider: StateMachineChatProvider()).startMission(
            input: advisory,
            workspace: workspace,
            session: &session,
            runtime: runtime,
            userMessageID: messageID
        )

        let submittedInputs = await runtime.submittedInputs()
        let missionCount = await runtime.missionCount()
        let toolCallCount = await runtime.toolCallCount()
        XCTAssertNil(result.task)
        XCTAssertFalse(result.waitingForUser)
        XCTAssertEqual(submittedInputs, [])
        XCTAssertEqual(missionCount, 0)
        XCTAssertEqual(toolCallCount, 0)
        XCTAssertNil(session.runtimeTaskID)
        XCTAssertTrue(session.artifacts.isEmpty)
        XCTAssertTrue(session.evidence.isEmpty)
        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertTrue(
            session.conversation.messages.last?.content.contains("通用评估框架") == true,
            session.conversation.messages.last?.content ?? "<missing agent response>"
        )
        XCTAssertTrue(AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: session.conversation,
            events: result.recordedEvents
        ).isEmpty)
        XCTAssertNotEqual(session.interactionState, .waitingForApproval)
        XCTAssertEqual(
            AgentMissionClassifier().executionIntentClassification(for: advisory),
            .advisoryConversation
        )
    }

    func testGreetingCreatesOneReplyAndNoAssessmentMissionArtifactOrHumanAction() async throws {
        let workspace = Workspace.default()
        let runtime = Phase2ERuntime()
        let messageID = UUID()
        var session = AgentSession.newConversation(in: workspace)
        session.beginConversation(with: "你好", messageID: messageID, turnID: messageID)

        let result = try await AgentRuntimeCoordinator(chatProvider: StateMachineChatProvider()).startMission(
            input: "你好",
            workspace: workspace,
            session: &session,
            runtime: runtime,
            userMessageID: messageID
        )

        let missionCount = await runtime.missionCount()
        let toolCallCount = await runtime.toolCallCount()
        XCTAssertNil(result.task)
        XCTAssertEqual(missionCount, 0)
        XCTAssertEqual(toolCallCount, 0)
        XCTAssertNil(session.runtimeTaskID)
        XCTAssertTrue(session.artifacts.isEmpty)
        XCTAssertTrue(session.evidence.isEmpty)
        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertFalse([.blocked, .waitingForApproval].contains(session.interactionState))
    }

    func testExplicitReadOnlyRequestCreatesOneExactComparisonMission() async throws {
        let workspace = Workspace.default()
        let runtime = Phase2ERuntime()
        let messageID = UUID()
        var session = AgentSession.newConversation(in: workspace)
        session.beginConversation(with: execution, messageID: messageID, turnID: messageID)

        let result = try await AgentRuntimeCoordinator(chatProvider: StateMachineChatProvider()).startMission(
            input: execution,
            workspace: workspace,
            session: &session,
            runtime: runtime,
            userMessageID: messageID
        )

        let task = try XCTUnwrap(result.task)
        let submittedInputs = await runtime.submittedInputs()
        let missionCount = await runtime.missionCount()
        let createdTaskIDs = await runtime.createdTaskIDs()
        XCTAssertEqual(submittedInputs, [execution])
        XCTAssertEqual(missionCount, 1)
        XCTAssertEqual(Set(createdTaskIDs), [task.id])
        XCTAssertEqual(MissionWorkspaceScope(request: execution), .legacyAndAgentComparison)
        XCTAssertEqual(
            AgentMissionClassifier().executionIntentClassification(for: execution),
            .executableReadOnly
        )
        let route = await runtime.auditEvents().first?.payload["selected_route"]
        XCTAssertEqual(route, AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue)
        XCTAssertEqual(task.workspaceID, workspace.id)
        XCTAssertEqual(task.state, .running)
    }

    func testReadOnlyExecutionPolicyAllowsOnlyBoundedInspectionTools() {
        XCTAssertEqual(ReadOnlyInspectionPolicy.allowedTools, [
            "engineering.inspect_project",
            "engineering.list_directory",
            "engineering.search_files",
            "engineering.search_code",
            "engineering.read_file"
        ])
        XCTAssertEqual(Set(ReadOnlyToolSchemas.all.keys), ReadOnlyInspectionPolicy.allowedTools)
        XCTAssertFalse(ReadOnlyInspectionPolicy.allowedTools.contains("engineering.write_file"))
        XCTAssertFalse(ReadOnlyInspectionPolicy.allowedTools.contains("shell"))
        XCTAssertFalse(ReadOnlyInspectionPolicy.allowedTools.contains("git"))
        XCTAssertFalse(ReadOnlyInspectionPolicy.allowedTools.contains("deploy"))
    }

    func testAdvisoryQualityExceptionKeepsUnrelatedAndFabricatedClaimGuards() {
        let ordinaryRequest = AgentChatRequest(
            message: "你好",
            detectedLanguage: "zh",
            intentType: .answerQuestion,
            workspaceName: "FDE",
            interactionState: .idle,
            hasRuntimeTask: false,
            selectedMode: .casualConversation,
            recentMessages: []
        )
        let unrelatedCapabilities = AgentChatResponse(
            content: "我可以检查、修改、运行测试、构建和部署项目。",
            confidence: 0.9
        )
        XCTAssertEqual(
            FDEChatQualityGuard().rejectionReason(
                for: unrelatedCapabilities,
                request: ordinaryRequest
            ),
            "capability_enumeration_for_unrelated_question"
        )

        let advisoryRequest = AgentChatRequest(
            message: advisory,
            detectedLanguage: "zh",
            intentType: .aiAgentCompatibilityAssessment,
            workspaceName: "FDE",
            interactionState: .idle,
            hasRuntimeTask: false,
            selectedMode: .legacyTransformationAdvisory,
            recentMessages: []
        )
        let fabricatedInspection = AgentChatResponse(
            content: "我已读取 Package.swift，并确认了当前项目的依赖。",
            confidence: 0.9
        )
        XCTAssertTrue(
            FDEChatQualityGuard().rejectionReason(
                for: fabricatedInspection,
                request: advisoryRequest
            )?.hasPrefix("unsupported_evidence_claim") == true
        )
    }

    func testAmbiguousExecutionAsksOneClarificationWithoutCreatingMission() async throws {
        let workspace = Workspace.default()
        let runtime = Phase2ERuntime()
        let input = "Assess an AI integration"
        let messageID = UUID()
        var session = AgentSession.newConversation(in: workspace)
        session.beginConversation(with: input, messageID: messageID, turnID: messageID)

        let result = try await AgentRuntimeCoordinator(chatProvider: StateMachineChatProvider()).startMission(
            input: input,
            workspace: workspace,
            session: &session,
            runtime: runtime,
            userMessageID: messageID
        )

        let missionCount = await runtime.missionCount()
        let toolCallCount = await runtime.toolCallCount()
        XCTAssertTrue(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(missionCount, 0)
        XCTAssertEqual(toolCallCount, 0)
        XCTAssertEqual(session.interactionState, .waitingForUser)
        XCTAssertEqual(session.conversation.messages.filter { $0.type == .question }.count, 1)
    }

    func testTranscriptUsesOneUpdatingWorkStatusAndOneFinalAgentAssessment() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = transcriptEvents(workspaceID: workspaceID, taskID: taskID)
        var conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: execution,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        conversation.append(contentsOf: AgentResponseComposer.messages(for: events))

        let live = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: Array(events.dropLast())
        )
        let completed = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: events
        )
        let messages = AgentResponseComposer.messages(for: events)

        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(live.first?.id, completed.first?.id)
        XCTAssertEqual(live.first?.status, .active)
        XCTAssertEqual(completed.first?.status, .completed)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.type, .result)
        XCTAssertTrue(messages.first?.content.contains("# FDE AI Integration Assessment Report") == true)
        XCTAssertEqual(completed.first?.toolsUsed, ["Read file · Sources/App.swift"])
        XCTAssertTrue(completed.first?.rawEvents.contains { $0.eventType == .toolCalled } == true)
        XCTAssertTrue(completed.first?.rawEvents.contains { $0.eventType == .stepExecuted } == true)
        XCTAssertEqual(
            AgentConversationWorkUnitAdapter.displayItems(conversation: conversation, events: events).count,
            2
        )
    }

    func testInternalUngroundedFailureIsNeverUserVisibleAndPartialIsNotBlocked() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let blocked = event(
            .stateUpdated,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "state": TaskState.blocked.rawValue,
                "blocker_reason": PlanReadinessBlocker.ungroundedFinalAnswer.rawValue,
                "response_language": "en"
            ]
        )
        let safeMessage = try XCTUnwrap(AgentResponseComposer.messages(for: [blocked]).first)
        XCTAssertFalse(safeMessage.content.contains(PlanReadinessBlocker.ungroundedFinalAnswer.rawValue))

        let partial = event(
            .stateUpdated,
            sequence: 2,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "state": TaskState.waiting.rawValue,
                "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
                "partial_result_kind": "GROUNDED_PARTIAL_RESULT",
                "grounded_answer": "true",
                "final_answer": "Observed fact: Package.swift was read. Unknown: runtime behavior.",
                "success": "true"
            ]
        )
        let conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: execution
        )
        let card = try XCTUnwrap(AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: [partial]
        ).first)
        let response = try XCTUnwrap(AgentResponseComposer.messages(for: [partial]).first)
        XCTAssertEqual(card.status, .partial)
        XCTAssertNotEqual(card.status, .blocked)
        XCTAssertEqual(response.type, .result)
    }

    func testStructuredGroundingBindsFactsAndRepairsUnsupportedClaimOnce() {
        let request = "Assess a customer-support AI Agent for read-only order lookup."
        let evidence = assessmentEvidence()
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: ReadOnlyEvidenceRequirements(request: request),
            evidence: evidence
        )
        let raw = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .detect(from: request),
            evidenceLedger: ledger,
            legacyArchitecture: LegacyArchitecture(ledger: ledger, evidence: evidence)
        )
        let grounded = FDEAssessmentGroundingValidator.repair(raw, evidence: evidence)
        XCTAssertTrue(FDEAssessmentGroundingValidator.validate(grounded, evidence: evidence).accepted)
        XCTAssertTrue(ReadOnlyFinalAnswerContract.validateAssessment(
            report: grounded,
            answer: grounded.markdown(language: .english),
            request: request,
            requirements: ReadOnlyEvidenceRequirements(request: request),
            evidence: evidence,
            requireComplete: false
        ).accepted)

        var unsupported = grounded
        unsupported.executiveSummary.statement = "The inspected Agent already enforces every permission boundary."
        unsupported.executiveSummary.confidence = .high
        unsupported.executiveSummary.evidence = []
        XCTAssertFalse(FDEAssessmentGroundingValidator.validate(unsupported, evidence: evidence).accepted)

        let repaired = FDEAssessmentGroundingValidator.repair(unsupported, evidence: evidence)
        XCTAssertEqual(repaired.executiveSummary.confidence, .low)
        XCTAssertTrue(repaired.executiveSummary.statement.hasPrefix("Inference (not directly evidenced):"))
        XCTAssertTrue(repaired.executiveSummary.evidence.isEmpty)
        XCTAssertEqual(FDEAssessmentGroundingValidator.repair(repaired, evidence: evidence), repaired)
    }

    func testAssessmentCoversRequiredDecisionSectionsInEnglishAndChinese() {
        let request = "Assess a customer-support AI Agent for read-only order lookup."
        let evidence = assessmentEvidence()
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: ReadOnlyEvidenceRequirements(request: request),
            evidence: evidence
        )
        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .detect(from: request),
            evidenceLedger: ledger,
            legacyArchitecture: LegacyArchitecture(ledger: ledger, evidence: evidence)
        )
        let english = report.markdown(language: .english)
        let chinese = report.markdown(language: .chinese)

        for section in [
            "Readiness:", "Business and workflow objective", "AI Agent Contract",
            "Candidate Integration Seams", "Security Assessment", "Validation Test Plan",
            "Observed facts", "Inferences", "Unknowns", "Recommendations", "Recommended next action"
        ] {
            XCTAssertTrue(english.contains(section), section)
        }
        for section in [
            "就绪度：", "业务目标与工作流", "AI Agent 契约", "候选接入缝隙", "安全评估",
            "验证测试计划", "观察事实", "推断", "未知项", "建议", "推荐的下一动作"
        ] {
            XCTAssertTrue(chinese.contains(section), section)
        }
        XCTAssertTrue(english.contains("Production restrictions"))
        XCTAssertTrue(english.contains("Required coverage"))
        XCTAssertTrue(english.contains("Highest-priority blocker"))
    }

    func testAssessmentArtifactRequiresExactProvenanceAndLegacyInvalidArtifactHasNoAuthority() throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        var session = AgentSession(workspace: workspace, userGoal: execution)
        let created = event(.taskCreated, sequence: 1, workspaceID: workspace.id, taskID: taskID)
        let evidence = event(
            .stepExecuted,
            sequence: 2,
            workspaceID: workspace.id,
            taskID: taskID,
            payload: [
                "command": "engineering.read_file",
                "tool_name": "engineering.read_file",
                "target_path": "Sources/App.swift",
                "success": "true",
                "actual_result": "struct App {}"
            ]
        )
        let completed = event(
            .taskCompleted,
            sequence: 3,
            workspaceID: workspace.id,
            taskID: taskID,
            payload: [
                "state": TaskState.completed.rawValue,
                "completion_gate_passed": "true",
                "grounded_answer": "true",
                "ai_assessment_capability": "read_only_integration",
                "detail": "# FDE AI Integration Assessment Report\n\nObserved fact with evidence.",
                "success": "true"
            ]
        )
        [created, evidence, completed].forEach { session.apply(event: $0) }

        let artifact = try XCTUnwrap(session.artifacts.first { $0.title == "FDE Assessment" })
        let provenance = try XCTUnwrap(artifact.assessmentProvenance)
        let initialRequest = try XCTUnwrap(session.conversation.messages.first { $0.sender == .user })
        XCTAssertEqual(artifact.authorityClassification, .authoritativeAssessment)
        XCTAssertEqual(provenance.sessionID, session.sessionID)
        XCTAssertEqual(provenance.workspaceID, workspace.id)
        XCTAssertEqual(provenance.turnID, initialRequest.turnID ?? initialRequest.id)
        XCTAssertEqual(provenance.requestID, initialRequest.id)
        XCTAssertEqual(provenance.executableIntentClassification, .executableReadOnly)
        XCTAssertEqual(provenance.runtimeTaskID, taskID)
        XCTAssertEqual(provenance.missionID, taskID)
        XCTAssertEqual(provenance.evidenceLineageEventIDs, [evidence.id])
        XCTAssertEqual(provenance.artifactDigest.count, 64)

        let invalid = AgentArtifact(
            id: "legacy-invalid",
            title: "Assessment",
            detail: "# FDE AI Integration Assessment Report\nHistorical invalid output",
            authorityClassification: .legacyInvalidAssessment
        )
        XCTAssertFalse(invalid.hasCurrentAuthority)
        XCTAssertTrue(AgentWorkspaceProjection.events(
            session: nil,
            task: nil,
            events: [],
            artifacts: [invalid]
        ).isEmpty)
    }

    func testSafetyCountersRemainZeroAndDeploymentAuthorityIsUnavailable() {
        let controlledEval = ControlledEvalSafetyCounters()
        let readiness = ProductionReadinessSafetyCounters()
        XCTAssertTrue(controlledEval.hasZeroExternalAuthority)
        XCTAssertTrue(readiness.hasZeroExecutionAuthority)
        XCTAssertEqual(controlledEval.deploymentOperations, 0)
        XCTAssertEqual(controlledEval.productionAccesses, 0)
        XCTAssertEqual(readiness.deploymentOperations, 0)
        XCTAssertEqual(readiness.productionAccesses, 0)
    }

    private func transcriptEvents(workspaceID: UUID, taskID: UUID) -> [ExecutionEvent] {
        [
            event(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID),
            event(.planGenerated, sequence: 2, workspaceID: workspaceID, taskID: taskID),
            event(
                .toolCalled,
                sequence: 3,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "command": "engineering.read_file",
                    "tool_name": "engineering.read_file",
                    "target_path": "Sources/App.swift",
                    "normalized_relative_path": "Sources/App.swift",
                    "workspace_identity": "legacy"
                ]
            ),
            event(
                .stepExecuted,
                sequence: 4,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "command": "engineering.read_file",
                    "tool_name": "engineering.read_file",
                    "target_path": "Sources/App.swift",
                    "normalized_relative_path": "Sources/App.swift",
                    "workspace_identity": "legacy",
                    "success": "true",
                    "actual_result": "struct App {}"
                ]
            ),
            event(
                .taskCompleted,
                sequence: 5,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "state": TaskState.completed.rawValue,
                    "completion_gate_passed": "true",
                    "completion_contract": RuntimeCompletionContractKind.readOnlyInspection.rawValue,
                    "grounded_answer": "true",
                    "detail": "# FDE AI Integration Assessment Report\n\nObserved facts are evidence-backed.",
                    "success": "true"
                ]
            )
        ]
    }

    private func assessmentEvidence() -> [ReadOnlyInspectionEvidence] {
        let workspaceID = UUID()
        func item(
            _ id: String,
            _ path: String,
            _ output: String
        ) -> ReadOnlyInspectionEvidence {
            ReadOnlyInspectionEvidence(
                toolCallID: id,
                toolName: path == "." ? "engineering.inspect_project" : "engineering.read_file",
                workspaceID: workspaceID,
                workspaceIdentity: "legacy",
                targetPath: path,
                output: output,
                toolCalledEventID: UUID(),
                toolResultEventID: UUID()
            )
        }
        return [
            item("root", ".", "src/orders.ts\nsrc/auth.ts\nsrc/audit.ts\ndocs/architecture.md"),
            item("orders", "src/orders.ts", "router.get('/orders', authenticateJWT, requireRole('support')); return order.customerId;"),
            item("auth", "src/auth.ts", "function authenticateJWT(token) { return authorize(token, 'support'); }"),
            item("audit", "src/audit.ts", "recordAuditEvent({ action: 'orders.read', outcome: 'allowed' });"),
            item("architecture", "docs/architecture.md", "Read-only order service boundary. Direct database mutation is prohibited.")
        ]
    }

    private func event(
        _ type: EventType,
        sequence: Int64,
        workspaceID: UUID,
        taskID: UUID?,
        payload: [String: String] = [:]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            summary: type.rawValue,
            payload: payload
        )
    }
}

private actor Phase2ERuntime: AgentRuntimeExecuting {
    private var inputs: [String] = []
    private var tasks: [FDETask] = []
    private var events: [ExecutionEvent] = []
    private var tools = 0

    func submitTask(input: String, workspace: Workspace) async throws -> FDETask {
        inputs.append(input)
        let task = FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: input,
            rawInput: input,
            state: .running,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        tasks.append(task)
        return task
    }

    func requestStepPause(taskID: UUID, reason: String) async {}
    func resumeTask(taskID: UUID, instruction: String?) async {}
    func changeTaskApproach(taskID: UUID, instruction: String) async {}
    func stopTask(taskID: UUID, reason: String) async {}

    func recordAuditEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        let item = ExecutionEvent(
            id: UUID(),
            parentEventID: events.last?.id,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: Int64(events.count + 1),
            timestamp: Date(timeIntervalSince1970: TimeInterval(events.count + 1)),
            summary: summary,
            payload: payload
        )
        events.append(item)
        return item
    }

    func submittedInputs() -> [String] { inputs }
    func missionCount() -> Int { tasks.count }
    func createdTaskIDs() -> [UUID] { tasks.map(\.id) }
    func auditEvents() -> [ExecutionEvent] { events }
    func toolCallCount() -> Int { tools }
}
