import XCTest
@testable import FDECloudOS

final class ReadOnlyInspectionRuntimeTests: XCTestCase {
    func testDefaultLegacyWorkspacePathAndWorkingDirectoryAreInjectedAndExecuted() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(id: "inspect-defaults", command: "engineering.inspect_project")
        ])
        let answer = "Inspected facts: the legacy workspace contains Package.swift. Engineering inference: it is a Swift package. Limitations: source-only inspection."

        let (task, events, _) = try await runTask(
            input: "读取当前 Legacy 项目，不要修改",
            fixture: fixture,
            outputs: [initial, finalOutput(answer)]
        )

        XCTAssertEqual(task.state, .completed)
        let called = try XCTUnwrap(events.first { $0.type == .toolCalled })
        XCTAssertEqual(called.payload["workspace_identity"], "legacy")
        XCTAssertEqual(called.payload["target_path"], ".")
        XCTAssertEqual(called.payload["arguments"], "workspace=legacy path=.")
        XCTAssertEqual(called.payload["runtime_defaulted_arguments"], "path | workingDirectory | workspace")
    }

    func testListDirectoryDefaultsRelativePathAndExecutes() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(id: "list-default", command: "engineering.list_directory", arguments: ["workspace=legacy"])
        ])
        let answer = "Inspected facts: the legacy workspace listing contains Package.swift and Sources. Engineering inference: it has a conventional Swift layout. Limitations: read-only listing only."

        let (task, events, _) = try await runTask(input: "检查 Legacy 项目结构", fixture: fixture, outputs: [initial, finalOutput(answer)])

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(events.contains {
            $0.type == .toolCalled && $0.payload["arguments"] == "workspace=legacy path=."
        })
    }

    func testSearchMissingQueryReportsExactFieldAndDoesNotExecute() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let invalid = planOutput([
            toolStep(id: "search-missing", command: "engineering.search_code", arguments: ["workspace=legacy"])
        ])

        let (task, events, _) = try await runTask(input: "搜索 Legacy 代码", fixture: fixture, outputs: [invalid, invalid])

        XCTAssertEqual(task.state, .blocked)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains {
            $0.payload["rejected_tool_call_details"]?.contains("engineering.search_code is missing required argument query") == true
                && $0.payload["rejected_fields"] == "query"
        })
    }

    func testReadFileMissingPathReportsExactField() throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let output = planOutput([
            toolStep(id: "read-missing", command: "engineering.read_file", arguments: ["workspace=legacy"])
        ])

        let readiness = ReadOnlyPlanReadinessValidator().validate(output, workspace: fixture.workspace, missionTarget: .legacy)

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.rejectedToolCalls.first?.invalidFields, ["path"])
        XCTAssertEqual(readiness.rejectedToolCalls.first?.detail, "engineering.read_file is missing required argument path.")
    }

    func testAliasArgumentsNormalizeIntoCanonicalExecutorArguments() throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let output = planOutput([
            toolStep(
                id: "alias",
                command: "engineering.inspect_project",
                arguments: ["target=legacy", "relative_path=."]
            )
        ])

        let readiness = ReadOnlyPlanReadinessValidator().validate(output, workspace: fixture.workspace, missionTarget: .legacy)

        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(readiness.executableSteps.first?.toolCall.arguments, ["workspace=legacy", "path=."])
        XCTAssertEqual(readiness.executableSteps.first?.toolCall.workingDirectory, fixture.legacy.path)
    }

    func testDotSlashPathNormalizesWithoutChangingCanonicalTarget() throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let output = planOutput([
            toolStep(
                id: "dot-slash-auth",
                command: "engineering.read_file",
                arguments: ["workspace=legacy", "path=./server/src/index.ts"]
            )
        ])

        let readiness = ReadOnlyPlanReadinessValidator().validate(
            output,
            workspace: fixture.workspace,
            missionTarget: .legacy
        )

        XCTAssertTrue(readiness.isReady)
        let executable = try XCTUnwrap(readiness.executableSteps.first)
        XCTAssertEqual(executable.relativeTargetPath, "server/src/index.ts")
        XCTAssertEqual(executable.toolCall.arguments, ["workspace=legacy", "path=server/src/index.ts"])
        XCTAssertEqual(executable.authorityAudit.modelPath, "./server/src/index.ts")
        XCTAssertEqual(executable.authorityAudit.normalizedRelativePath, "server/src/index.ts")
    }

    func testSearchWithoutPathReceivesTrustedCanonicalRootDefaultOnce() throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let output = planOutput([
            toolStep(
                id: "search-root-default",
                command: "engineering.search_files",
                arguments: ["query=order"]
            )
        ])

        let readiness = ReadOnlyPlanReadinessValidator().validate(
            output,
            workspace: fixture.workspace,
            missionTarget: .legacy
        )

        XCTAssertTrue(readiness.isReady)
        let executable = try XCTUnwrap(readiness.executableSteps.first)
        XCTAssertEqual(executable.relativeTargetPath, ".")
        XCTAssertEqual(executable.toolCall.arguments, ["workspace=legacy", "path=.", "query=order"])
        XCTAssertEqual(executable.runtimeDefaultedArguments, ["path", "workingDirectory", "workspace"])
        XCTAssertEqual(executable.authorityAudit.trustedRoot, fixture.legacy.path)
    }

    func testSearchExtractionPreservesExactDiscoveredParentPath() {
        let facts = ReadOnlySafeFactExtractor.extract(
            toolName: "engineering.search_files",
            targetPath: ".",
            output: "src/orders.ts:0: file path match"
        )

        XCTAssertEqual(facts.discoveredPaths, ["src/orders.ts"])
        XCTAssertFalse(facts.discoveredPaths.contains("orders.ts"))
    }

    func testSelectedProjectNameAliasAndLiteralNullWorkingDirectoryUseTrustedLegacyRoot() throws {
        var fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        fixture.workspace.name = "synthetic-legacy"
        fixture.workspace.displayName = "Pet Gifts"
        let output = planOutput([
            toolStep(
                id: "project-name-alias",
                command: "engineering.inspect_project",
                arguments: ["workspace=synthetic-legacy", "path=.", "workingDirectory=null"]
            )
        ])

        let readiness = ReadOnlyPlanReadinessValidator().validate(
            output,
            workspace: fixture.workspace,
            missionTarget: .legacy
        )

        XCTAssertTrue(readiness.isReady)
        let executable = try XCTUnwrap(readiness.executableSteps.first)
        XCTAssertEqual(executable.workspaceIdentity, "legacy")
        XCTAssertEqual(executable.toolCall.workingDirectory, fixture.legacy.path)
        XCTAssertEqual(executable.toolCall.arguments, ["workspace=legacy", "path=."])
        XCTAssertEqual(executable.authorityAudit.modelWorkspaceLabel, "synthetic-legacy")
        XCTAssertEqual(executable.authorityAudit.normalizedWorkspaceIdentity, "legacy")
        XCTAssertEqual(executable.authorityAudit.trustedRoot, fixture.legacy.path)
        XCTAssertEqual(executable.authorityAudit.rawModelWorkingDirectory, "null")
        XCTAssertEqual(executable.authorityAudit.normalizedRelativePath, ".")
        XCTAssertEqual(executable.authorityAudit.rejectedReason, "")
    }

    func testSelectedProjectNameWorkingDirectoryHintResolvesAsIdentityNotFilesystemPath() throws {
        var fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        fixture.workspace.name = "synthetic-legacy"
        let output = planOutput([
            toolStep(
                id: "project-name-working-directory",
                command: "engineering.inspect_project",
                arguments: ["path=.", "workingDirectory=synthetic-legacy"]
            )
        ])

        let readiness = ReadOnlyPlanReadinessValidator().validate(
            output,
            workspace: fixture.workspace,
            missionTarget: .legacy
        )

        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(readiness.executableSteps.first?.toolCall.workingDirectory, fixture.legacy.path)
        XCTAssertEqual(readiness.executableSteps.first?.workspaceIdentity, "legacy")
        XCTAssertEqual(readiness.executableSteps.first?.authorityAudit.rawModelWorkingDirectory, "synthetic-legacy")
        XCTAssertFalse(readiness.auditPayload["workspace_authority"]?.contains("/FDE/synthetic-legacy") == true)
    }

    func testLegacyOnlyMissionRejectsAgentRootAsWorkspaceScopeMismatch() throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let output = planOutput([
            toolStep(
                id: "agent-root-mismatch",
                command: "engineering.inspect_project",
                arguments: ["workspace=legacy", "path=."],
                workingDirectory: fixture.agent.path
            )
        ])

        let readiness = ReadOnlyPlanReadinessValidator().validate(
            output,
            workspace: fixture.workspace,
            missionTarget: .legacy
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.blockerReason, .workspaceScopeMismatch)
        let rejection = try XCTUnwrap(readiness.rejectedToolCalls.first)
        XCTAssertEqual(rejection.invalidFields, ["workingDirectory"])
        XCTAssertEqual(rejection.authorityAudit?.trustedRoot, fixture.legacy.path)
        XCTAssertEqual(rejection.authorityAudit?.rejectedValue, fixture.agent.path)
        XCTAssertEqual(rejection.authorityAudit?.rejectedReason, PlanReadinessBlocker.workspaceScopeMismatch.rawValue)
    }

    func testLegacyOnlyContextContainsNoAgentCodebaseSnapshotOrRoot() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let context = await InstructionContextCompiler(workspaceRootURL: fixture.legacy).compile(
            workspace: fixture.workspace,
            taskInput: "只检查当前 Legacy 项目，不要检查 Agent",
            missionWorkspaceScope: .legacyOnly,
            recentTasks: [],
            graph: ([], [])
        )

        XCTAssertEqual(context.missionWorkspaceScope, .legacyOnly)
        let bundle = try XCTUnwrap(context.contextBundle)
        XCTAssertEqual(bundle.missionWorkspaceScope, .legacyOnly)
        XCTAssertEqual(bundle.codebases.map(\.role), ["legacy_software"])
        XCTAssertEqual(bundle.codebases.first?.rootPath, fixture.legacy.path)
        XCTAssertEqual(bundle.systemState.currentWorkingDirectory, fixture.legacy.path)
        XCTAssertNil(bundle.workspace.agentRootPath)
        let encoded = try JSONCoding.encode(bundle)
        XCTAssertFalse(encoded.contains(fixture.agent.path))
        XCTAssertFalse(encoded.contains("Agent.swift"))
    }

    func testMissionWorkspaceScopeHonorsNegativeAndExplicitComparisonLanguage() {
        XCTAssertEqual(
            MissionWorkspaceScope(request: "只检查 Legacy，不要分析 Agent"),
            .legacyOnly
        )
        XCTAssertEqual(
            MissionWorkspaceScope(request: "只检查 Agent，不要分析 Legacy"),
            .agentOnly
        )
        XCTAssertEqual(
            MissionWorkspaceScope(request: "对比 Legacy 和 Agent"),
            .legacyAndAgentComparison
        )
        XCTAssertEqual(
            MissionWorkspaceScope(request: "检查它们如何连接"),
            .legacyAndAgentComparison
        )
        XCTAssertEqual(
            MissionWorkspaceScope(request: "比较两个项目，但不要分析 Agent"),
            .legacyOnly
        )
    }

    func testExactNativeChineseOrderAssessmentSelectsLegacyOnlyBroadScope() {
        let request = """
        请评估客户支持 AI Agent 的订单查询能力。

        请只读检查订单数据边界、API、身份验证、记录级授权、权限模型、审计日志、修改路径和敏感字段。

        本次只进行分析，不修改任何文件。
        """

        XCTAssertEqual(MissionWorkspaceScope(request: request), .legacyOnly)
        XCTAssertEqual(ReadOnlyMissionTarget(request: request), .legacy)
        XCTAssertEqual(
            ReadOnlyInspectionLimits.conservative.budget(for: request, workspaceScope: .legacyOnly).kind,
            .broadStaticAssessment
        )
    }

    func testAgentOnlyContextContainsOnlyAgentSnapshot() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let context = await InstructionContextCompiler(workspaceRootURL: fixture.agent).compile(
            workspace: fixture.workspace,
            taskInput: "只检查 Agent，不要分析 Legacy",
            missionWorkspaceScope: .agentOnly,
            recentTasks: [],
            graph: ([], [])
        )

        let bundle = try XCTUnwrap(context.contextBundle)
        XCTAssertEqual(bundle.codebases.map(\.role), ["ai_agent"])
        XCTAssertEqual(bundle.codebases.first?.rootPath, fixture.agent.path)
        XCTAssertEqual(bundle.workspace.rootPath, fixture.agent.path)
        XCTAssertEqual(bundle.workspace.agentRootPath, fixture.agent.path)
        let encoded = try JSONCoding.encode(bundle)
        XCTAssertFalse(encoded.contains(fixture.legacy.path))
        XCTAssertFalse(encoded.contains("DataLoader.swift"))
    }

    func testStructuredOutputDecodesObjectAndWrappedObjectArguments() throws {
        let json = """
        {"plan":[],"actions":[],"tool_calls":[
          {"id":"direct","type":"api","command":"engineering.inspect_project","arguments":{"target":"legacy","relative_path":"."},"workingDirectory":null,"requiresApproval":false},
          {"id":"wrapped","type":"api","command":"engineering.list_directory","arguments":{"arguments":{"workspace":"legacy","path":"."}},"workingDirectory":null,"requiresApproval":false}
        ],"risks":[],"confidence":0.9}
        """

        try StructuredAgentOutputSchema.validateJSONText(json)
        let decoded = try JSONCoding.decode(StructuredAgentOutput.self, from: json)

        XCTAssertEqual(Set(decoded.toolCalls[0].arguments), Set(["target=legacy", "relative_path=."]))
        XCTAssertEqual(Set(decoded.toolCalls[1].arguments), Set(["workspace=legacy", "path=."]))
    }

    func testLegacyOnlyMissionRejectsAgentWorkspaceCall() throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let output = planOutput([
            toolStep(id: "wrong-scope", command: "engineering.inspect_project", arguments: ["workspace=agent"])
        ])

        let readiness = ReadOnlyPlanReadinessValidator().validate(output, workspace: fixture.workspace, missionTarget: .legacy)

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.blockerReason, .workspaceScopeMismatch)
        XCTAssertEqual(readiness.rejectedToolCalls.first?.invalidFields, ["workspace"])
    }

    func testLegacyOnlyFinalAnswerRejectsAgentProjectInventory() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "legacy-only", command: "engineering.inspect_project")])
        let crossScopedAnswer = "Inspected facts: Package.swift exists. Agent project inventory: Agent.swift. Engineering inference: Swift sources exist. Limitations: source-only inspection."

        let (task, events, _) = try await runTask(
            input: "只检查当前 Legacy 项目结构",
            fixture: fixture,
            outputs: [initial, finalOutput(crossScopedAnswer), finalOutput(crossScopedAnswer)]
        )

        XCTAssertEqual(task.state, .completed)
        let completed = try XCTUnwrap(events.last { $0.type == .taskCompleted })
        XCTAssertFalse(completed.payload["detail"]?.contains("Agent.swift") == true)
        XCTAssertTrue(events.contains {
            $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_FALLBACK"
                && $0.payload["answer_repair_attempted"] == "true"
        })
    }

    func testProviderFailureAndInvalidToolArgumentsHaveDistinctDiagnostics() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: DiagnosticFailingRouter(error: .providerRequestFailed("temporary transport failure")),
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired
        )

        let task = try await kernel.submitTask(input: "检查 Legacy 项目", workspace: fixture.workspace)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)

        XCTAssertEqual(task.state, .blocked)
        XCTAssertTrue(events.contains {
            $0.payload["blocker_reason"] == "planner_provider_request_failed"
                && $0.payload["provider_diagnostic"] == "provider_request_failed"
        })
        XCTAssertFalse(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.missingRequiredArguments.rawValue })
    }

    func testPlannerTimeoutRetriesOnceThenBlocksWithMeasurementsAndLegacyOnlyContext() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let failure = ModelProviderFailure(
            routingError: .providerRequestFailed("The request timed out."),
            provider: .openAI,
            model: "planner-test-model",
            failurePhase: "timeout",
            httpStatus: nil,
            safeErrorCode: "url_error_timed_out",
            safeErrorType: "timeout",
            durationMilliseconds: 20_000,
            requestPayloadBytes: 8_192,
            responsePayloadBytes: 0,
            responseDecodeFailed: false,
            responseSchemaValidationFailed: false,
            retryable: true
        )
        let router = PlannerTimeoutRouter(failure: failure)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired
        )

        let task = try await kernel.submitTask(
            input: "只检查当前 Legacy 项目结构，不要检查 Agent",
            workspace: fixture.workspace
        )
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
        let plannerCalls = await router.callCount()

        XCTAssertEqual(task.state, .blocked)
        XCTAssertEqual(plannerCalls, 2)
        XCTAssertEqual(events.filter { $0.payload["lifecycle_event"] == "PROVIDER_RETRY_REQUESTED" }.count, 1)
        let blocked = try XCTUnwrap(events.last { $0.payload["lifecycle_event"] == "PLANNER_PROVIDER_FAILED" })
        XCTAssertEqual(blocked.payload["blocker_reason"], PlanReadinessBlocker.plannerTimeout.rawValue)
        XCTAssertEqual(blocked.payload["provider_attempts"], "2")
        XCTAssertEqual(blocked.payload["retry_later_allowed"], "true")
        XCTAssertEqual(blocked.payload["successful_read_evidence"], "false")
        XCTAssertEqual(blocked.payload["planner_codebase_count"], "1")
        XCTAssertEqual(blocked.payload["mission_workspace_scope"], MissionWorkspaceScope.legacyOnly.rawValue)
        XCTAssertGreaterThan(Int(blocked.payload["planner_context_bytes"] ?? "0") ?? 0, 0)
        XCTAssertGreaterThan(Int(blocked.payload["planner_prompt_bytes"] ?? "0") ?? 0, 0)
    }

    func testBlockedReadOnlyMissionRecoversOnSameTaskIDAndPreservesEventHistory() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let invalid = planOutput([
            toolStep(
                id: "outside-before-recovery",
                command: "engineering.inspect_project",
                arguments: ["workspace=legacy", "path=."],
                workingDirectory: fixture.agent.path
            )
        ])
        let recoveredPlan = planOutput([
            toolStep(
                id: "legacy-after-recovery",
                command: "engineering.inspect_project",
                arguments: ["workspace=legacy", "path=.", "workingDirectory=null"]
            )
        ])
        let final = finalOutput(
            "Inspected facts: the selected Legacy workspace contains Package.swift. Engineering inference: it is a Swift package. Limitations: read-only source inspection only."
        )
        let router = ScriptedReadOnlyRouter(outputs: [invalid, invalid, recoveredPlan, final])
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired
        )

        let blocked = try await kernel.submitTask(
            input: "只检查当前 Legacy 项目，不要检查 Agent",
            workspace: fixture.workspace
        )
        XCTAssertEqual(blocked.state, .blocked)

        let recoveredTask = try await kernel.recoverTask(
            taskID: blocked.id,
            instruction: "使用当前 Legacy 根目录重试同一个任务",
            workspace: fixture.workspace
        )
        let recovered = try XCTUnwrap(recoveredTask)
        let tasks = try await persistence.loadTasks(workspaceID: fixture.workspace.id)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: blocked.id)

        XCTAssertEqual(recovered.id, blocked.id)
        XCTAssertEqual(recovered.state, .completed)
        XCTAssertEqual(tasks.filter { $0.id == blocked.id }.count, 1)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(events.filter { $0.type == .taskCreated }.count, 1)
        let compiledContexts = events.filter { $0.type == .contextCompiled }
        XCTAssertEqual(compiledContexts.count, 2)
        XCTAssertTrue(compiledContexts.allSatisfy {
            $0.payload["codebase_count"] == "1"
                && $0.payload["codebase_roles"] == "legacy_software"
                && $0.payload["agent_project_root"] == ""
        })
        XCTAssertTrue(events.contains {
            $0.type == .recoveryAttempted
                && $0.payload["same_task_id_preserved"] == "true"
                && $0.payload["prior_evidence_available"] == "false"
        })
        XCTAssertTrue(events.contains {
            $0.type == .toolCalled
                && $0.payload["trusted_workspace_root"] == fixture.legacy.path
                && $0.payload["workspace_identity"] == "legacy"
        })
        XCTAssertTrue(events.contains { $0.type == .taskCompleted })
    }

    func testRepairAndObservationProviderFailuresRecordDistinctSafeStages() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let invalid = planOutput([
            toolStep(id: "repair-provider-stage", command: "engineering.search_code", arguments: [])
        ])
        let (_, repairEvents, _) = try await runTask(
            input: "实际检查 Legacy manifest，不要修改",
            fixture: fixture,
            outputs: [invalid]
        )
        XCTAssertTrue(repairEvents.contains {
            $0.payload["blocker_reason"] == PlanReadinessBlocker.repairProviderUnavailable.rawValue
                && $0.payload["provider_stage"] == "repair"
                && $0.payload["provider_diagnostic"] == "provider_unavailable"
        })

        let initial = planOutput([toolStep(id: "inspect-provider-stage", command: "engineering.inspect_project")])
        let (_, observationEvents, _) = try await runTask(
            input: "实际检查 Legacy manifest，不要修改",
            fixture: fixture,
            outputs: [initial]
        )
        XCTAssertTrue(observationEvents.contains {
            $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_FALLBACK"
                && $0.payload["provider_stage"] == "final_grounded_answer"
                && $0.payload["provider_diagnostic"] == "provider_unavailable"
        })
        XCTAssertTrue(observationEvents.contains {
            $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
        })
        XCTAssertFalse(observationEvents.contains {
            $0.payload["blocker_reason"] == PlanReadinessBlocker.observationProviderUnavailable.rawValue
        })
    }

    func testTransientPostToolProviderFailureRetriesOnceAndCompletesGroundedAnswer() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let initial = planOutput([toolStep(id: "retry-inspect", command: "engineering.inspect_project")])
        let final = finalOutput(
            "Inspected facts: the legacy workspace contains Package.swift. Engineering inference: this is a Swift package. Limitations: static read-only inspection only."
        )
        let failure = ModelProviderFailure(
            routingError: .providerRequestFailed("connection lost"),
            provider: .openAI,
            model: "gpt-4.1-mini",
            failurePhase: "transport",
            httpStatus: nil,
            safeErrorCode: "url_error_network_connection_lost",
            safeErrorType: "transport",
            durationMilliseconds: 6_920,
            requestPayloadBytes: 12_345,
            responsePayloadBytes: 0,
            responseDecodeFailed: false,
            responseSchemaValidationFailed: false,
            retryable: true
        )
        let router = RetryingObservationRouter(initial: initial, final: final, firstFailure: failure)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired
        )

        let task = try await kernel.submitTask(input: "检查当前 Legacy 项目，不要修改", workspace: fixture.workspace)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
        let decisionCount = await router.decisionCount()

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(decisionCount, 3, "A language-contract repair is attempted before deterministic fallback")
        let retry = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "PROVIDER_RETRY_REQUESTED" })
        XCTAssertEqual(retry.payload["provider_stage"], "observation_next_action")
        XCTAssertEqual(retry.payload["provider_error_code"], "url_error_network_connection_lost")
        XCTAssertEqual(retry.payload["provider_duration_ms"], "6920")
        XCTAssertEqual(retry.payload["provider_request_bytes"], "12345")
        XCTAssertEqual(retry.payload["provider_response_bytes"], "0")
        XCTAssertEqual(retry.payload["retryable"], "true")
    }

    func testFinalizationProviderFailuresUseDeterministicGroundedFallback() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let cases: [(String, Int?, Bool, Bool)] = [
            ("http", 503, false, false),
            ("response_decode", 200, true, false),
            ("response_schema_validation", 200, false, true)
        ]

        for (phase, status, decodeFailed, schemaFailed) in cases {
            let persistence = InMemoryPersistenceStore()
            try await persistence.initialize()
            try await persistence.saveWorkspace(fixture.workspace)
            let initial = planOutput([
                toolStep(id: "inspect-before-finalization-\(phase)", command: "engineering.inspect_project")
            ])
            let failure = ModelProviderFailure(
                routingError: phase == "http"
                    ? .providerRequestFailed("service unavailable")
                    : .providerOutputInvalid("invalid response"),
                provider: .openAI,
                model: "gpt-4.1-mini",
                failurePhase: phase,
                httpStatus: status,
                safeErrorCode: phase == "http" ? "http_503" : "\(phase)_failed",
                safeErrorType: phase,
                durationMilliseconds: 321,
                requestPayloadBytes: 4_096,
                responsePayloadBytes: phase == "http" ? 128 : 512,
                responseDecodeFailed: decodeFailed,
                responseSchemaValidationFailed: schemaFailed,
                retryable: false
            )
            let router = FailingFinalizationRouter(
                initial: initial,
                action: nextToolAction(
                    id: "read-manifest-before-failure-\(phase)",
                    command: "engineering.read_file",
                    arguments: ["path=Package.swift"]
                ),
                failure: failure
            )
            let kernel = RuntimeKernel(
                persistence: persistence,
                eventBus: RuntimeEventBus(),
                modelRouter: router,
                toolExecutor: WorkspaceEngineeringToolExecutor(),
                completionPolicy: .evidenceRequired
            )

            let task = try await kernel.submitTask(
                input: "读取 Package.swift 并检查 dependencies，不要修改",
                workspace: fixture.workspace
            )
            let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
            let fallback = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_FALLBACK" })
            let partial = try XCTUnwrap(events.last { $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" })

            XCTAssertEqual(task.state, .waiting)
            XCTAssertTrue(fallback.payload["provider_stage"]?.contains("final_grounded_answer") == true)
            XCTAssertEqual(fallback.payload["provider_failure_phase"], phase)
            XCTAssertEqual(fallback.payload["model"], "gpt-4.1-mini")
            XCTAssertEqual(fallback.payload["http_status"], status.map(String.init) ?? "")
            XCTAssertEqual(fallback.payload["response_decode_failed"], decodeFailed ? "true" : "false")
            XCTAssertEqual(fallback.payload["response_schema_validation_failed"], schemaFailed ? "true" : "false")
            XCTAssertEqual(fallback.payload["fallback_grounded_from_recorded_evidence"], "true")
            XCTAssertEqual(fallback.payload["budget_stop_decision"], ReadOnlyBudgetStopDecision.partialWithCurrentEvidence.rawValue)
            XCTAssertEqual(fallback.payload["grounded_answer"], "true")
            XCTAssertFalse(fallback.payload["user_visible_message"]?.isEmpty ?? true)
            XCTAssertEqual(fallback.payload["user_visible_message"], fallback.payload["final_answer"])
            XCTAssertTrue(partial.payload["detail"]?.contains("Package.swift") == true)
            XCTAssertFalse(events.contains { $0.type == .taskCompleted })
            XCTAssertFalse(events.contains { $0.payload["lifecycle_event"] == "PLAN_BLOCKED" })
        }
    }

    func testRealStyleReasoningStepOrphanToolReferenceIsSafelyNormalized() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let inspect = ToolCall(
            id: "inspect-root",
            type: .api,
            command: "engineering.inspect_project",
            arguments: ["workspace=legacy", "path=."],
            workingDirectory: nil,
            requiresApproval: false
        )
        let orphan = ToolCall(
            id: "aggregate-findings",
            type: .api,
            command: "engineering.inspect_project",
            arguments: ["workspace=legacy", "path=."],
            workingDirectory: nil,
            requiresApproval: false
        )
        let output = StructuredAgentOutput(
            plan: [
                PlanStep(id: "step-1", title: "Inspect", intent: "Inspect project.", kind: .tool, toolCallID: inspect.id, requiresApproval: false),
                PlanStep(id: "step-8", title: "Aggregate", intent: "Analyze collected results.", kind: .reasoning, toolCallID: orphan.id, requiresApproval: false)
            ],
            actions: [],
            toolCalls: [inspect, orphan],
            risks: [],
            confidence: 0.9
        )

        let readiness = ReadOnlyPlanReadinessValidator().validate(output, workspace: fixture.workspace, missionTarget: .legacy)

        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(readiness.executableSteps.count, 1)
        XCTAssertEqual(readiness.normalizedPlan.last?.kind, .reasoning)
        XCTAssertNil(readiness.normalizedPlan.last?.toolCallID)
        XCTAssertEqual(readiness.stepNormalizations.first?.stepID, "step-8")
        XCTAssertEqual(readiness.stepNormalizations.first?.removedToolCallID, "aggregate-findings")
    }

    func testAmbiguousSharedNonToolReferenceRemainsPreciselyRejected() throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let call = ToolCall(
            id: "shared-call",
            type: .api,
            command: "engineering.inspect_project",
            arguments: ["workspace=legacy", "path=."],
            workingDirectory: nil,
            requiresApproval: false
        )
        let output = StructuredAgentOutput(
            plan: [
                PlanStep(id: "tool-step", title: "Inspect", intent: "Inspect.", kind: .tool, toolCallID: call.id, requiresApproval: false),
                PlanStep(id: "reason-step", title: "Analyze", intent: "Analyze.", kind: .reasoning, toolCallID: call.id, requiresApproval: false)
            ],
            actions: [],
            toolCalls: [call],
            risks: [],
            confidence: 0.9
        )

        let readiness = ReadOnlyPlanReadinessValidator().validate(output, workspace: fixture.workspace, missionTarget: .legacy)
        let rejection = try XCTUnwrap(readiness.rejectedToolCalls.first { $0.reason == .invalidPlanStep })

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(rejection.stepID, "reason-step")
        XCTAssertEqual(rejection.stepKind, .reasoning)
        XCTAssertEqual(rejection.actualFields, ["kind=reasoning", "toolCallID=shared-call"])
        XCTAssertEqual(rejection.expectedFields, ["kind=reasoning", "toolCallID=null"])
        XCTAssertTrue(rejection.originalStepJSON?.contains("reason-step") == true)
    }

    func testRealNodeFixtureInspectionExecutesAndProducesGroundedLegacyOnlyAnswer() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let paths = [
            "package.json", "server/package.json", "vite.config.ts", "src/App.tsx",
            "server/src/index.ts", "server/prisma/schema.prisma"
        ]
        var outputs = [planOutput([toolStep(id: "inspect-node", command: "engineering.inspect_project")])]
        outputs += paths.enumerated().map { index, path in
            planOutput([toolStep(id: "read-node-\(index)", command: "engineering.read_file", arguments: ["path=\(path)"])])
        }
        let answer = """
        1. Inspected workspace: Legacy only.
        2. Files/manifests read: package.json, server/package.json, vite.config.ts, src/App.tsx, server/src/index.ts, server/prisma/schema.prisma.
        3. Project structure: Vite React frontend, Express server, and Prisma schema.
        4. Main languages: TypeScript, TSX, and Prisma schema syntax.
        5. Frameworks: React, Vite, Express, and Prisma.
        6. Important dependencies: react, vite, express, and @prisma/client.
        7. Confirmed facts: those manifests and entry points contain the named dependencies and imports.
        8. Inferences: the repository is a frontend/server monorepo-style application.
        9. Limitations: read-only static source inspection; no build, test, CPU, memory, or runtime measurement.
        10. Recommended next inspection: inspect frontend data access and server route/database call paths.
        """
        outputs.append(finalOutput(answer))

        let (task, events, _) = try await runTask(
            input: "读取当前 Legacy 项目，检查项目结构、主要语言、框架和依赖，不要修改任何文件。",
            fixture: fixture,
            outputs: outputs
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.count, 7)
        XCTAssertTrue(events.filter { $0.type == .toolCalled }.allSatisfy { $0.payload["workspace_identity"] == "legacy" })
        let observed = events.compactMap { $0.payload["stdout"] }.joined(separator: "\n")
        XCTAssertTrue(observed.contains("\"react\""))
        XCTAssertTrue(observed.contains("\"express\""))
        XCTAssertTrue(observed.contains("provider = \"postgresql\""))
        let final = try XCTUnwrap(events.first { $0.type == .taskCompleted }?.payload["detail"])
        XCTAssertTrue(final.contains("server/prisma/schema.prisma"))
        XCTAssertFalse(final.contains("Agent workspace"))
    }

    func testAIAssessmentMissionEmitsAllLiveStatesAndGroundedReport() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let paths = [
            "package.json", "server/package.json", "vite.config.ts", "src/App.tsx",
            "server/src/index.ts", "server/prisma/schema.prisma"
        ]
        var outputs = [planOutput([toolStep(id: "assessment-inspect", command: "engineering.inspect_project")])]
        outputs += paths.enumerated().map { index, path in
            planOutput([
                toolStep(
                    id: "assessment-read-\(index)",
                    command: "engineering.read_file",
                    arguments: ["path=\(path)"]
                )
            ])
        }
        outputs.append(finalOutput(
            "Static Legacy evidence was read from package.json, server/package.json, vite.config.ts, src/App.tsx, server/src/index.ts, and server/prisma/schema.prisma. Runtime behavior was not verified."
        ))

        let (task, events, _) = try await runTask(
            input: "Assess whether this Legacy system can support a read-only customer support AI agent. Do not modify files.",
            fixture: fixture,
            outputs: outputs
        )

        XCTAssertEqual(task.state, .completed)
        let missionStates: [String] = events.compactMap { event -> String? in
            guard event.payload["lifecycle_event"] == "AI_ASSESSMENT_ACTIVITY" else { return nil }
            return event.payload["ai_assessment_mission_state"]
        }
        XCTAssertEqual(missionStates, AIAssessmentMissionState.allCases.map(\.rawValue))
        let completed = try XCTUnwrap(events.first { $0.type == .taskCompleted })
        XCTAssertEqual(
            completed.payload["ai_assessment_mission_state"],
            AIAssessmentMissionState.finalizingGroundedAssessment.rawValue
        )
        let detail = try XCTUnwrap(completed.payload["detail"])
        XCTAssertTrue(detail.contains("Proposed Operational Workflow"))
        XCTAssertTrue(detail.contains("Agent-side Black Boxes"))
        XCTAssertTrue(detail.contains("Evidence Provenance"))
    }

    func testPersistedFailureShapedPlanRepairsIntoExecutableDefaultedCall() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let original = planOutput([
            toolStep(id: "toolCall1", command: "engineering.search_files", arguments: ["workspace=legacy"]),
            toolStep(id: "toolCall2", command: "engineering.inspect_project", arguments: [])
        ])
        let repaired = planOutput([
            toolStep(id: "repaired-inspect", command: "engineering.inspect_project", arguments: [])
        ])
        let readSource = planOutput([
            toolStep(
                id: "repaired-read-source",
                command: "engineering.read_file",
                arguments: ["path=Sources/App/DataLoader.swift"]
            )
        ])
        let answer = "Static inspected fact: the Legacy workspace contains Package.swift and Sources/App/DataLoader.swift. Possible risk inference: synchronous file loading may merit review. Limitations: CPU, memory, profiler, and runtime behavior were not measured."

        let (task, events, _) = try await runTask(
            input: "对当前 Legacy 项目做一次只读的静态性能风险分析。不要修改代码，也不要声称测量了 CPU、内存或运行时间。",
            fixture: fixture,
            outputs: [original, repaired, readSource, finalOutput(answer)]
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(events.contains { $0.payload["lifecycle_event"] == "PLAN_REPAIRED" && $0.payload["is_ready"] == "true" })
        XCTAssertTrue(events.contains { $0.type == .toolCalled && $0.payload["command"] == "engineering.inspect_project" })
        XCTAssertFalse(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.missingRequiredArguments.rawValue && $0.type == .stateUpdated })
    }

    func testInspectionIntentRoutesPerformanceAnalysisToReadOnlyMission() {
        let intent = MissionIntentParser().parse("给这个项目做一个性能分析")

        XCTAssertEqual(intent.intentType, .inspectWorkspace)
        XCTAssertTrue(intent.constraints.contains(.readOnly))
        XCTAssertEqual(MissionExecutionSemantic(intent: intent), .readOnlyWorkspaceInspection)
        XCTAssertEqual(RuntimeCompletionContract(input: intent.originalText, intent: intent).kind, .readOnlyInspection)
    }

    func testArchitectureInspectionIntentIsReadOnly() {
        let intent = MissionIntentParser().parse("给这个项目做一个架构检查")

        XCTAssertEqual(intent.intentType, .architectureAnalysis)
        XCTAssertTrue(intent.constraints.contains(.readOnly))
        XCTAssertEqual(MissionExecutionSemantic(intent: intent), .readOnlyWorkspaceInspection)
    }

    func testRealCreationIntentRemainsExecutableModification() {
        let intent = MissionIntentParser().parse("做一个新页面")

        XCTAssertEqual(intent.intentType, .createFeature)
        XCTAssertEqual(MissionExecutionSemantic(intent: intent), .engineeringModification)
    }

    func testConnectorCreationIntentRemainsExecutableModification() {
        let intent = MissionIntentParser().parse("创建一个 connector")

        XCTAssertEqual(intent.intentType, .createFeature)
        XCTAssertEqual(MissionExecutionSemantic(intent: intent), .engineeringModification)
    }

    func testValidInspectionPlanRunsBothLinkedToolsAndRecordsEvidence() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let outputs = [
            planOutput([
                toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path),
                toolStep(id: "manifest", command: "engineering.read_file", arguments: ["path=Package.swift"], workingDirectory: fixture.legacy.path)
            ]),
            planOutput([toolStep(id: "manifest-next", command: "engineering.read_file", arguments: ["path=Package.swift"], workingDirectory: fixture.legacy.path)]),
            finalOutput("Inspected facts: the workspace contains Package.swift. Engineering inference: the Swift package layout is analyzable. Limitations: no build or runtime measurement was performed.")
        ]
        let (task, events, _) = try await runTask(
            input: "检查这个 Swift 项目的架构和 manifest",
            fixture: fixture,
            outputs: outputs
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.count, 2)
        XCTAssertEqual(events.filter { $0.payload["lifecycle_event"] == "TOOL_RESULT" }.count, 2)
        XCTAssertEqual(events.filter { $0.payload["lifecycle_event"] == "OBSERVATION_RECORDED" }.count, 2)
        XCTAssertTrue(events.contains { $0.payload["lifecycle_event"] == "PLAN_READINESS_CHECKED" && $0.payload["is_ready"] == "true" })
    }

    func testZeroToolPlanGetsOneRepairAndDoesNotEnterRunningUntilReady() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let invalid = StructuredAgentOutput(
            plan: [PlanStep(id: "reason", title: "Inspect later", intent: "Describe inspection.", kind: .reasoning, toolCallID: nil, requiresApproval: false)],
            actions: [],
            toolCalls: [],
            risks: [],
            confidence: 0.8
        )
        let repaired = planOutput([
            toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path)
        ])
        let (task, events, _) = try await runTask(
            input: "检查这个项目",
            fixture: fixture,
            outputs: [invalid, repaired, finalOutput("Inspected facts: the workspace is a Swift package containing Sources/App/DataLoader.swift. Engineering inference: source review can continue. Limitations: no commands ran.")]
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(events.filter { $0.payload["lifecycle_event"] == "PLAN_REPAIR_REQUESTED" }.count, 1)
        XCTAssertTrue(events.contains { $0.payload["lifecycle_event"] == "PLAN_REPAIRED" && $0.payload["is_ready"] == "true" })
        let ready = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "PLAN_REPAIRED" })
        let called = try XCTUnwrap(events.first { $0.type == .toolCalled })
        XCTAssertLessThan(ready.sequence, called.sequence)
    }

    func testExecutableStepWithNilToolReferenceBlocksWithoutSilentSkip() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let invalid = planWithSingleStep(
            PlanStep(id: "broken", title: "Broken", intent: "Inspect.", kind: .tool, toolCallID: nil, requiresApproval: false),
            calls: []
        )
        let (task, events, _) = try await runTask(input: "检查这个项目", fixture: fixture, outputs: [invalid, invalid])

        XCTAssertEqual(task.state, .blocked)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.noExecutableToolStep.rawValue })
    }

    func testMissingToolCallReferenceIsRejectedWithoutExecution() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let invalid = planWithSingleStep(
            PlanStep(id: "broken", title: "Broken", intent: "Inspect.", kind: .tool, toolCallID: "missing", requiresApproval: false),
            calls: []
        )
        let (task, events, _) = try await runTask(input: "检查这个项目", fixture: fixture, outputs: [invalid, invalid])

        XCTAssertEqual(task.state, .blocked)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.invalidToolCallReference.rawValue })
    }

    func testUnknownToolReferenceIsRejectedBeforeRunning() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let unknown = planOutput([
            toolStep(id: "unknown", command: "engineering.unknown", workingDirectory: fixture.legacy.path)
        ])
        let (task, events, _) = try await runTask(input: "检查这个项目", fixture: fixture, outputs: [unknown, unknown])

        XCTAssertEqual(task.state, .blocked)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.toolNotAllowed.rawValue })
    }

    func testReadinessRejectsDuplicateIDsMissingArgumentsAndApprovalRequirements() throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let duplicateA = ToolCall(id: "duplicate", type: .api, command: "engineering.inspect_project", arguments: [], workingDirectory: fixture.legacy.path, requiresApproval: false)
        let duplicateB = ToolCall(id: "duplicate", type: .api, command: "engineering.list_directory", arguments: [], workingDirectory: fixture.legacy.path, requiresApproval: false)
        let missingArguments = ToolCall(id: "missing", type: .api, command: "engineering.read_file", arguments: [], workingDirectory: fixture.legacy.path, requiresApproval: false)
        let approval = ToolCall(id: "approval", type: .api, command: "engineering.inspect_project", arguments: [], workingDirectory: fixture.legacy.path, requiresApproval: true)
        let output = StructuredAgentOutput(
            plan: [
                PlanStep(id: "duplicate-step", title: "duplicate", intent: "inspect", kind: .tool, toolCallID: "duplicate", requiresApproval: false),
                PlanStep(id: "missing-step", title: "missing", intent: "read", kind: .tool, toolCallID: "missing", requiresApproval: false),
                PlanStep(id: "approval-step", title: "approval", intent: "inspect", kind: .tool, toolCallID: "approval", requiresApproval: true)
            ],
            actions: [],
            toolCalls: [duplicateA, duplicateB, missingArguments, approval],
            risks: [],
            confidence: 0.7
        )

        let readiness = ReadOnlyPlanReadinessValidator().validate(output, workspace: fixture.workspace)

        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(readiness.rejectedToolCalls.contains { $0.reason == .duplicateToolCallID })
        XCTAssertTrue(readiness.rejectedToolCalls.contains { $0.reason == .missingRequiredArguments })
        XCTAssertTrue(readiness.rejectedToolCalls.contains { $0.reason == .approvalRequired })
    }

    func testMutationAttemptIsRejectedAndDoesNotWrite() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let target = fixture.legacy.appendingPathComponent("Sources/App/Main.swift")
        let original = try String(contentsOf: target, encoding: .utf8)
        let mutation = planOutput([
            toolStep(
                id: "edit",
                command: "engineering.edit_file",
                arguments: ["path=Sources/App/Main.swift", "new_contents=changed"],
                workingDirectory: fixture.legacy.path
            )
        ])
        let (task, events, _) = try await runTask(input: "检查这个项目，不要修改", fixture: fixture, outputs: [mutation, mutation])

        XCTAssertEqual(task.state, .blocked)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), original)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.mutationProhibited.rawValue })
    }

    func testRealFilesystemInspectionContainsFixtureEvidence() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path),
            toolStep(id: "list", command: "engineering.list_directory", arguments: ["path=Sources/App"], workingDirectory: fixture.legacy.path)
        ])
        let final = finalOutput("Inspected facts: the workspace contains Package.swift and Sources/App/DataLoader.swift. Engineering inference: it is a Swift package. Limitations: source-only inspection.")
        let (task, events, _) = try await runTask(input: "检查 Swift 项目", fixture: fixture, outputs: [initial, final, final])

        XCTAssertEqual(task.state, .completed)
        let outputs = events.compactMap { $0.payload["stdout"] }.joined(separator: "\n")
        XCTAssertTrue(outputs.contains("Package.swift"))
        XCTAssertTrue(outputs.contains("DataLoader.swift"))
        XCTAssertTrue(events.filter { $0.payload["lifecycle_event"] == "TOOL_RESULT" }.allSatisfy { $0.payload["workspace_identity"] == "legacy" })
    }

    func testObservationLoopChoosesSearchThenReadThenGroundedFinalAnswer() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path)
        ])
        let search = planOutput([
            toolStep(
                id: "search-risk",
                command: "engineering.search_code",
                arguments: ["query=Data(contentsOf", "extensions=swift"],
                workingDirectory: fixture.legacy.path
            )
        ])
        let read = planOutput([
            toolStep(
                id: "read-loader",
                command: "engineering.read_file",
                arguments: ["path=Sources/App/DataLoader.swift"],
                workingDirectory: fixture.legacy.path
            )
        ])
        let answer = """
        Inspected facts: Sources/App/DataLoader.swift calls Data(contentsOf:) synchronously in load().
        Engineering inference: this is a possible static performance risk if load() runs on a latency-sensitive path.
        Unverified hypothesis: impact depends on file size and call context.
        Limitations: CPU, memory, profiler traces, and benchmarks were not measured.
        Recommended next verification: profile the call path in a later execution-enabled phase.
        """
        let (task, events, router) = try await runTask(
            input: "检查这个 Swift 项目可能存在的性能问题",
            fixture: fixture,
            outputs: [initial, search, read, finalOutput(answer)]
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.compactMap { $0.payload["command"] }, [
            "engineering.inspect_project", "engineering.search_code", "engineering.read_file"
        ])
        XCTAssertTrue(events.contains { $0.type == .taskCompleted && $0.payload["detail"]?.contains("DataLoader.swift") == true })
        let decisionCount = await router.decisionCount()
        XCTAssertEqual(decisionCount, 4, "Language/answer-contract repair is one bounded provider call")
    }

    func testEmptyWorkspaceIsProvenAndBlockedTruthfully() async throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path)
        ])
        let (task, events, router) = try await runTask(input: "检查这个项目", fixture: fixture, outputs: [initial])

        XCTAssertEqual(task.state, .blocked)
        XCTAssertTrue(events.contains { $0.payload["lifecycle_event"] == "TOOL_RESULT" && $0.payload["stdout"]?.contains("Files: 0") == true })
        XCTAssertTrue(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.workspaceEmpty.rawValue })
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
        let decisionCount = await router.decisionCount()
        XCTAssertEqual(decisionCount, 0)
    }

    func testNonemptyWorkspaceWithoutSourceFilesBlocksWithoutClaimingScanComplete() async throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write(fixture.legacy.appendingPathComponent("README.md"), "# Documentation-only workspace\n")
        let initial = planOutput([
            toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path)
        ])
        let (task, events, router) = try await runTask(input: "检查这个项目", fixture: fixture, outputs: [initial])

        XCTAssertEqual(task.state, .blocked)
        XCTAssertTrue(events.contains { $0.payload["lifecycle_event"] == "TOOL_RESULT" && $0.payload["stdout"]?.contains("Source files: 0") == true })
        XCTAssertTrue(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.noSourceFiles.rawValue })
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
        let decisionCount = await router.decisionCount()
        XCTAssertEqual(decisionCount, 0)
    }

    func testOutOfScopeAbsolutePathIsRejectedWithoutExternalRead() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let outsideFile = fixture.container.appendingPathComponent("outside-secret.swift")
        try "outside".write(to: outsideFile, atomically: true, encoding: .utf8)
        let outside = planOutput([
            toolStep(
                id: "outside",
                command: "engineering.read_file",
                arguments: ["path=\(outsideFile.path)"],
                workingDirectory: fixture.legacy.path
            )
        ])
        let (task, events, _) = try await runTask(input: "读取 Swift 文件", fixture: fixture, outputs: [outside, outside])

        XCTAssertEqual(task.state, .blocked)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.pathOutsideWorkspace.rawValue })
        XCTAssertFalse(events.compactMap { $0.payload["stdout"] }.joined().contains("outside"))
    }

    func testStaticPerformanceReportUsesEvidenceAndDisclaimsMeasurements() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path)
        ])
        let read = planOutput([
            toolStep(id: "read", command: "engineering.read_file", arguments: ["path=Sources/App/DataLoader.swift"], workingDirectory: fixture.legacy.path)
        ])
        let answer = "Static finding: Sources/App/DataLoader.swift contains synchronous Data(contentsOf:), a possible hotspot. This is a suspected risk, not a measured bottleneck. Limitations: CPU, memory, profiler, and benchmark behavior were not measured."
        let (task, events, _) = try await runTask(
            input: "对项目进行性能扫描",
            fixture: fixture,
            outputs: [initial, read, finalOutput(answer)]
        )

        XCTAssertEqual(task.state, .completed)
        let final = try XCTUnwrap(events.first { $0.type == .taskCompleted }?.payload["detail"])
        XCTAssertTrue(final.contains("静态"))
        XCTAssertTrue(final.contains("DataLoader.swift"))
        XCTAssertTrue(final.contains("未执行"))
    }

    func testReadOnlyCompletionRequiresToolEvidenceAndGroundedAnswer() {
        let input = "Inspect Sources/App/DataLoader.swift read-only"
        let contract = RuntimeCompletionContract(input: input, intent: MissionIntentParser().parse(input))
        let result = event(
            type: .stepExecuted,
            sequence: 1,
            payload: [
                "tool_call_id": "read",
                "command": "engineering.read_file",
                "workspace_identity": "legacy",
                "target_path": "Sources/App/DataLoader.swift",
                "exit_code": "0",
                "success": "true"
            ]
        )
        let final = event(
            type: .stateUpdated,
            sequence: 2,
            payload: [
                "lifecycle_event": "INSPECTION_COMPLETED",
                "grounded_answer": "true",
                "final_answer": "Sources/App/DataLoader.swift was inspected."
            ]
        )

        XCTAssertFalse(contract.evaluate(events: []).allowed)
        XCTAssertFalse(contract.evaluate(events: [result]).allowed)
        XCTAssertTrue(contract.evaluate(events: [result, final]).allowed)
    }

    func testIterationReserveFinalizesPartialWithoutRequestingAnotherTool() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let partial = "Partial Legacy workspace report: the project root was inspected, but Package.swift was not read, so manifest and dependency analysis remains incomplete. Continue this same task to read Package.swift."
        let outputs = [
            planOutput([toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path)]),
            finalOutput(partial)
        ]
        var limits = ReadOnlyInspectionLimits.conservative
        limits.maximumModelDecisionIterations = 1
        let (task, events, _) = try await runTask(
            input: "检查 Legacy 项目 manifest 和 dependencies",
            fixture: fixture,
            outputs: outputs,
            limits: limits
        )

        XCTAssertEqual(task.state, .waiting)
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.count, 1)
        XCTAssertTrue(events.contains {
            $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_STARTED"
                && $0.payload["budget_stop_decision"] == ReadOnlyBudgetStopDecision.partialWithCurrentEvidence.rawValue
                && $0.payload["budget_stop_trigger"] == ReadOnlyFinalizationTrigger.iterationReserve.rawValue
                && $0.payload["finalization_terminal_operation"] == "true"
        })
        let partialEvent = try XCTUnwrap(events.last { $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" })
        XCTAssertEqual(partialEvent.payload["blocker_reason"], PlanReadinessBlocker.iterationLimitReached.rawValue)
        XCTAssertTrue(partialEvent.payload["user_visible_message"]?.contains("Package.swift") == true)
        XCTAssertEqual(
            AgentResponseComposer.message(for: partialEvent).content,
            partialEvent.payload["user_visible_message"]
        )
        XCTAssertFalse(events.contains { $0.payload["lifecycle_event"] == "PLAN_BLOCKED" })
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
    }

    func testToolCallLimitFinalizesGroundedPartialInsteadOfBareBlock() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "tool-limit-root", command: "engineering.inspect_project")])
        let partial = "Partial Legacy workspace report: the project root was inspected, but the backend manifest and database schema were not read. Continue this same task for those files."
        var limits = ReadOnlyInspectionLimits.conservative
        limits.maximumToolCalls = 1

        let (task, events) = try await runNativeTask(
            input: "Inspect Legacy backend dependencies and database schema",
            fixture: fixture,
            initial: initial,
            actions: [nextFinalAction(partial)],
            limits: limits
        )

        XCTAssertEqual(task.state, .waiting)
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.count, 1)
        let finalization = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_STARTED" })
        XCTAssertEqual(finalization.payload["budget_stop_trigger"], ReadOnlyFinalizationTrigger.toolCallLimit.rawValue)
        XCTAssertEqual(finalization.payload["budget_stop_decision"], ReadOnlyBudgetStopDecision.partialWithCurrentEvidence.rawValue)
        XCTAssertTrue(events.contains { $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" })
        XCTAssertFalse(events.contains { $0.payload["lifecycle_event"] == "PLAN_BLOCKED" })
    }

    func testFileReadLimitFinalizesGroundedPartialInsteadOfBareBlock() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(id: "file-limit-root", command: "engineering.list_directory", arguments: ["path=."])
        ])
        let partial = "Partial Legacy workspace report: package.json was read, but the requested frontend configuration, backend manifest, backend entry point, and database schema remain uninspected. Continue this same task for those targets."
        var limits = ReadOnlyInspectionLimits.conservative
        limits.maximumFilesRead = 1

        let (task, events) = try await runNativeTask(
            input: "Inspect Legacy frontend configuration, backend dependencies, entry point, and database schema",
            fixture: fixture,
            initial: initial,
            actions: [
                nextToolAction(id: "file-limit-package", command: "engineering.read_file", arguments: ["path=package.json"]),
                nextFinalAction(partial)
            ],
            limits: limits
        )

        XCTAssertEqual(task.state, .waiting)
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.count, 2)
        let finalization = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_STARTED" })
        XCTAssertEqual(finalization.payload["budget_stop_trigger"], ReadOnlyFinalizationTrigger.fileReadLimit.rawValue)
        XCTAssertTrue(events.contains { $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" })
        XCTAssertFalse(events.contains { $0.payload["lifecycle_event"] == "PLAN_BLOCKED" })
    }

    func testCancellationStopsAdditionalToolCallsAndNeverCompletes() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fixture.workspace
        try await persistence.saveWorkspace(workspace)
        let router = ScriptedReadOnlyRouter(outputs: [
            planOutput([toolStep(id: "inspect", command: "engineering.inspect_project", workingDirectory: fixture.legacy.path)])
        ])
        let executor = DelayedReadOnlyToolExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: executor,
            completionPolicy: .evidenceRequired
        )
        let operation = Task { try await kernel.submitTask(input: "检查项目", workspace: workspace) }
        try await Task.sleep(for: .milliseconds(40))
        operation.cancel()
        let task = try await operation.value
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)

        let callCount = await executor.callCount()
        XCTAssertLessThanOrEqual(callCount, 1)
        XCTAssertNotEqual(task.state, .completed)
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
    }

    func testNativeObservationDecisionExecutesExactlyOneNextTool() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "inspect-native", command: "engineering.inspect_project")])
        let answer = "Inspected facts: the legacy workspace and Sources directory contain Package.swift and App. Engineering inference: this is a Swift package layout. Limitations: read-only inspection only."
        let (task, events) = try await runNativeTask(
            input: "检查当前 Legacy 项目结构",
            fixture: fixture,
            initial: initial,
            actions: [
                nextToolAction(id: "list-native", command: "engineering.list_directory", arguments: ["path=Sources"]),
                nextFinalAction(answer)
            ]
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.map { $0.payload["command"] ?? "" }, [
            "engineering.inspect_project", "engineering.list_directory"
        ])
        XCTAssertTrue(events.contains { $0.payload["lifecycle_event"] == "NEXT_ACTION_DECODED" && $0.payload["next_action_valid"] == "true" })
    }

    func testOneToolReasoningAndFinalizationTitleNormalizeAsMetadata() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "inspect-metadata", command: "engineering.inspect_project")])
        let next = toolStep(id: "list-metadata", command: "engineering.list_directory", arguments: ["path=Sources"])
        let legacyVariant = StructuredAgentOutput(
            plan: [
                next.0,
                PlanStep(id: "reasoning-metadata", title: "Reason", intent: "Inspect the observed Sources directory next.", kind: .reasoning, toolCallID: next.1.id, requiresApproval: false),
                PlanStep(id: "final-title", title: "Final report", intent: "Summarize the evidence later.", kind: .finalization, toolCallID: nil, requiresApproval: false)
            ],
            actions: [],
            toolCalls: [next.1],
            risks: [],
            confidence: 0.9
        )
        let answer = "Inspected facts: the Legacy Sources directory contains App. Engineering inference: source review can continue. Limitations: no files changed."
        let (task, events, _) = try await runTask(
            input: "检查当前 Legacy 项目结构",
            fixture: fixture,
            outputs: [initial, legacyVariant, finalOutput(answer)]
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(events.filter { $0.type == .toolCalled && $0.payload["command"] == "engineering.list_directory" }.count, 1)
        let decoded = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "NEXT_ACTION_DECODED" })
        XCTAssertEqual(decoded.payload["decoded_tool_call_count"], "1")
        XCTAssertEqual(decoded.payload["final_answer_present"], "false")
        XCTAssertTrue(decoded.payload["normalization_notes"]?.contains("metadata") == true)
    }

    func testPluralWrapperWithOneToolCallDecodesToSingularContract() throws {
        let json = #"{"decision":"tool","tool_calls":[{"id":"next-list","type":"api","command":"engineering.list_directory","arguments":["workspace=legacy","path=."],"workingDirectory":null,"requiresApproval":false}],"final_answer":null,"clarification":null,"blocker_reason":null,"reasoning_summary":"Continue inspecting."}"#

        let action = try ReadOnlyNextActionSchema.decodeJSONText(json)

        XCTAssertEqual(action.decision, .tool)
        XCTAssertEqual(action.toolCalls.count, 1)
        XCTAssertEqual(action.toolCalls.first?.id, "next-list")
        XCTAssertTrue(action.audit.normalizationNotes.contains { $0.contains("plural tool_calls") })
    }

    func testTwoNextToolCallsGetOneRepairAndOnlyRepairedCallExecutes() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "inspect-multiple", command: "engineering.inspect_project")])
        let multiple = ReadOnlyNextAction(
            decision: .tool,
            toolCalls: [
                nextToolCall(id: "next-list-a", command: "engineering.list_directory", arguments: ["path=Sources"]),
                nextToolCall(id: "next-search-b", command: "engineering.search_files", arguments: ["query=Package.swift"])
            ]
        )
        let answer = "Inspected facts: the Legacy Sources directory contains App. Engineering inference: it has a conventional layout. Limitations: read-only inspection only."
        let (task, events) = try await runNativeTask(
            input: "检查当前 Legacy 项目结构",
            fixture: fixture,
            initial: initial,
            actions: [multiple, nextToolAction(id: "repaired-list", command: "engineering.list_directory", arguments: ["path=Sources"]), nextFinalAction(answer)]
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(events.filter { $0.payload["lifecycle_event"] == "NEXT_ACTION_REPAIR_REQUESTED" }.count, 2)
        XCTAssertEqual(events.filter {
            $0.payload["lifecycle_event"] == "NEXT_ACTION_REPAIR_REQUESTED"
                && $0.payload["rejection_reason"] == PlanReadinessBlocker.multipleNextActions.rawValue
        }.count, 1)
        XCTAssertTrue(events.contains { $0.payload["rejection_reason"] == PlanReadinessBlocker.multipleNextActions.rawValue })
        XCTAssertFalse(events.contains { $0.type == .toolCalled && $0.payload["tool_call_id"] == "next-search-b" })
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.count, 2)
    }

    func testFullPlanAtObservationIsRepairedWithoutRestartingMission() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "inspect-full-plan", command: "engineering.inspect_project")])
        let fullPlan = ReadOnlyNextAction(legacyOutput: planOutput([
            toolStep(id: "full-list", command: "engineering.list_directory", arguments: ["path=Sources"]),
            toolStep(id: "full-search", command: "engineering.search_files", arguments: ["query=Package.swift"])
        ]))
        let answer = "Inspected facts: Sources contains App. Engineering inference: the project has analyzable Swift sources. Limitations: no modification or build was performed."
        let (task, events) = try await runNativeTask(
            input: "检查当前 Legacy 项目结构",
            fixture: fixture,
            initial: initial,
            actions: [fullPlan, nextToolAction(id: "one-list", command: "engineering.list_directory", arguments: ["path=Sources"]), nextFinalAction(answer)]
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(events.contains {
            $0.payload["returned_complete_plan"] == "true"
                && $0.payload["rejection_reason"] == PlanReadinessBlocker.invalidNextAction.rawValue
        })
        XCTAssertEqual(events.filter { $0.type == .toolCalled && $0.payload["command"] == "engineering.inspect_project" }.count, 1)
        XCTAssertEqual(Set(events.compactMap(\.taskID)), Set([task.id]))
    }

    func testPrematureManifestFinalizationRepairsToReadThenCompletesGrounded() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "inspect-manifest", command: "engineering.inspect_project")])
        let premature = nextFinalAction("Inspected workspace metadata says this is a Swift package with dependencies. Limitations: metadata only.")
        let grounded = "Inspected workspace: Legacy. Files/manifests read: Package.swift. Project structure: Sources/App. Main language: Swift. Frameworks and important dependencies: Swift Package Manager and Foundation. Confirmed facts: Package.swift was read. Inferences: it is a Swift package. Limitations: static read-only inspection."
        let (task, events) = try await runNativeTask(
            input: "检查项目结构、框架和依赖，列出实际读取的 manifest 和关键文件",
            fixture: fixture,
            initial: initial,
            actions: [
                premature,
                nextToolAction(id: "read-package", command: "engineering.read_file", arguments: ["path=Package.swift"]),
                nextFinalAction(grounded)
            ]
        )

        XCTAssertEqual(task.state, .waiting)
        XCTAssertTrue(events.contains { $0.payload["rejection_reason"] == PlanReadinessBlocker.insufficientEvidenceToFinalize.rawValue })
        XCTAssertEqual(events.filter { $0.type == .toolCalled && $0.payload["command"] == "engineering.read_file" }.count, 1)
        XCTAssertTrue(events.last { $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" }?.payload["detail"]?.contains("Package.swift") == true)
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
    }

    func testRepairCannotReplayCompletedInspectProject() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "inspect-once", command: "engineering.inspect_project")])
        let multiple = ReadOnlyNextAction(
            decision: .tool,
            toolCalls: [
                nextToolCall(id: "ambiguous-a", command: "engineering.list_directory"),
                nextToolCall(id: "ambiguous-b", command: "engineering.search_files", arguments: ["query=Package.swift"])
            ]
        )
        let (task, events) = try await runNativeTask(
            input: "检查当前 Legacy 项目结构",
            fixture: fixture,
            initial: initial,
            actions: [multiple, nextToolAction(id: "inspect-again", command: "engineering.inspect_project")]
        )

        XCTAssertEqual(task.state, .blocked)
        XCTAssertEqual(events.filter { $0.type == .toolCalled && $0.payload["command"] == "engineering.inspect_project" }.count, 1)
        XCTAssertTrue(events.contains { $0.payload["blocker_reason"] == PlanReadinessBlocker.nextActionInvalidTool.rawValue })
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
    }

    func testLegacyOnlyInvalidAgentNextActionRepairsWithinLegacyScope() async throws {
        let fixture = try makeSwiftFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "inspect-scope", command: "engineering.inspect_project")])
        let answer = "Inspected facts: the Legacy Sources directory contains App. Engineering inference: Legacy source review can continue. Limitations: this was a Legacy-only read."
        let (task, events) = try await runNativeTask(
            input: "只检查当前 Legacy 项目，不要分析 Agent",
            fixture: fixture,
            initial: initial,
            actions: [
                nextToolAction(id: "wrong-agent", command: "engineering.list_directory", arguments: ["workspace=agent", "path=."]),
                nextToolAction(id: "legacy-list", command: "engineering.list_directory", arguments: ["workspace=legacy", "path=Sources"]),
                nextFinalAction(answer)
            ]
        )

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(events.contains { $0.payload["rejection_reason"] == PlanReadinessBlocker.nextActionInvalidTool.rawValue })
        XCTAssertTrue(events.filter { $0.type == .toolCalled }.allSatisfy { $0.payload["workspace_identity"] == "legacy" })
    }

    func testMissionBudgetSelectionUsesSimpleProjectAndBroadDepths() {
        let limits = ReadOnlyInspectionLimits.conservative

        let simple = limits.budget(for: "Explain Sources/App/Main.swift in the Legacy codebase", workspaceScope: .legacyOnly)
        let project = limits.budget(for: "Inspect the Legacy project structure", workspaceScope: .legacyOnly)
        let broad = limits.budget(
            for: "Assess Legacy architecture, dependencies, and database configuration",
            workspaceScope: .legacyOnly
        )

        XCTAssertEqual(simple.kind, .simpleFileInspection)
        XCTAssertEqual(project.kind, .projectInspection)
        XCTAssertEqual(broad.kind, .broadStaticAssessment)
        XCTAssertLessThan(simple.hardLimit, project.hardLimit)
        XCTAssertLessThan(project.hardLimit, broad.hardLimit)
        XCTAssertLessThan(simple.softLimit, simple.hardLimit)
        XCTAssertGreaterThanOrEqual(simple.hardLimit - simple.softLimit, simple.finalizationReserve)
        let simpleOperations = limits.operationBudget(for: simple.kind)
        let projectOperations = limits.operationBudget(for: project.kind)
        let broadOperations = limits.operationBudget(for: broad.kind)
        XCTAssertLessThan(simpleOperations.maximumModelDecisionIterations, projectOperations.maximumModelDecisionIterations)
        XCTAssertLessThan(projectOperations.maximumModelDecisionIterations, broadOperations.maximumModelDecisionIterations)
        XCTAssertLessThan(simpleOperations.maximumToolCalls, broadOperations.maximumToolCalls)
        XCTAssertEqual(broadOperations.auditPayload["selected_file_read_budget"], "8")
    }

    func testSoftDeadlineAfterThreeEvidenceItemsFinalizesPartialWithoutAnotherTool() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "budget-inspect", command: "engineering.inspect_project")])
        let partialAnswer = "Partial Legacy workspace report: inspected the project root, package.json, and server directory. Confirmed findings are limited to those recorded results. server/package.json, server/prisma/schema.prisma, and server/src/index.ts were not inspected, so backend dependency and database conclusions are incomplete. Continue the same task to read them."
        var limits = ReadOnlyInspectionLimits.conservative
        limits.budgetOverride = ReadOnlyMissionBudget(
            kind: .broadStaticAssessment,
            softLimit: 0.45,
            hardLimit: 0.80,
            providerCallReserve: 0.08,
            finalizationReserve: 0.35
        )
        let executor = SequencedDelayedReadOnlyExecutor(delays: [.zero, .zero, .milliseconds(360)])

        let (task, events, router) = try await runCapturingNativeTask(
            input: "Inspect the Legacy frontend and backend manifests, dependencies, database schema, and backend entry point",
            fixture: fixture,
            initial: initial,
            actions: [
                nextToolAction(id: "budget-package", command: "engineering.read_file", arguments: ["path=package.json"]),
                nextToolAction(id: "budget-server", command: "engineering.list_directory", arguments: ["path=server"]),
                nextFinalAction(partialAnswer)
            ],
            executor: executor,
            limits: limits
        )

        XCTAssertEqual(task.state, .waiting)
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.compactMap { $0.payload["command"] }, [
            "engineering.inspect_project", "engineering.read_file", "engineering.list_directory"
        ])
        let partial = try XCTUnwrap(events.last { $0.payload["lifecycle_event"] == "INSPECTION_PARTIALLY_FINALIZED" })
        XCTAssertEqual(partial.payload["partial_completion_state"], "BLOCKED_WITH_PARTIAL_RESULT")
        XCTAssertEqual(partial.payload["requested_scope_complete"], "false")
        XCTAssertEqual(partial.payload["grounded_answer"], "true")
        XCTAssertEqual(partial.payload["same_task_resumable"], "true")
        XCTAssertTrue(partial.payload["unsatisfied_evidence_requirements"]?.contains("backend_manifest") == true)
        XCTAssertTrue(partial.payload["unsatisfied_evidence_requirements"]?.contains("database_schema_or_config") == true)
        XCTAssertTrue(partial.payload["final_answer"]?.contains("server/package.json") == true)
        XCTAssertNotNil(Int(partial.payload["elapsed_ms"] ?? ""))
        XCTAssertNotNil(Int(partial.payload["planning_ms"] ?? ""))
        XCTAssertNotNil(Int(partial.payload["observation_provider_ms"] ?? ""))
        XCTAssertNotNil(Int(partial.payload["tool_execution_ms"] ?? ""))
        XCTAssertNotNil(Int(partial.payload["finalization_ms"] ?? ""))
        XCTAssertEqual(partial.payload["soft_limit_ms"], "450")
        XCTAssertEqual(partial.payload["hard_limit_ms"], "800")
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
        let prompts = await router.observationPrompts()
        XCTAssertTrue(prompts.last?.contains("finalization_required: true") == true)
        XCTAssertTrue(prompts.last?.contains("remaining_duration_ms") == true)
        XCTAssertTrue(prompts.last?.contains("remaining_tool_calls") == true)
        XCTAssertTrue(prompts.last?.contains("unsatisfied:") == true)
    }

    func testAllEvidenceRequirementsCompleteNormallyBeforeDeadline() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "complete-inspect", command: "engineering.inspect_project")])
        let answer = "Inspected Legacy workspace files: package.json, server/package.json, server/prisma/schema.prisma, and server/src/index.ts. Confirmed facts: the recorded manifests contain frontend and backend dependencies, the recorded Prisma schema declares a database provider, and the recorded backend entry point imports Express. Limitations: static read-only inspection only."

        let (task, events, router) = try await runCapturingNativeTask(
            input: "Inspect the Legacy frontend and backend manifests, dependencies, database schema, and backend entry point",
            fixture: fixture,
            initial: initial,
            actions: [
                nextToolAction(id: "complete-root-manifest", command: "engineering.read_file", arguments: ["path=package.json"]),
                nextToolAction(id: "complete-backend-manifest", command: "engineering.read_file", arguments: ["path=server/package.json"]),
                nextToolAction(id: "complete-schema", command: "engineering.read_file", arguments: ["path=server/prisma/schema.prisma"]),
                nextToolAction(id: "complete-entry", command: "engineering.read_file", arguments: ["path=server/src/index.ts"]),
                nextFinalAction(answer)
            ],
            executor: WorkspaceEngineeringToolExecutor(),
            limits: .conservative
        )

        XCTAssertEqual(task.state, .completed)
        let completed = try XCTUnwrap(events.last { $0.type == .taskCompleted })
        XCTAssertEqual(completed.payload["evidence_requirements_unsatisfied_count"], "0")
        XCTAssertEqual(completed.payload["selected_iteration_budget"], "10")
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.count, 5)
        let finalization = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_STARTED" })
        XCTAssertEqual(finalization.payload["budget_stop_trigger"], ReadOnlyFinalizationTrigger.evidenceSatisfied.rawValue)
        XCTAssertEqual(finalization.payload["budget_stop_decision"], ReadOnlyBudgetStopDecision.completeWithCurrentEvidence.rawValue)
        let prompts = await router.observationPrompts()
        XCTAssertTrue(prompts.last?.contains("finalization_required: true") == true)
        XCTAssertFalse(events.contains { $0.payload["partial_result"] == "true" })
    }

    func testHardDeadlineCancelsPendingToolAndPreservesPriorEvidence() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "hard-inspect", command: "engineering.inspect_project")])
        var limits = ReadOnlyInspectionLimits.conservative
        limits.budgetOverride = ReadOnlyMissionBudget(
            kind: .projectInspection,
            softLimit: 0.22,
            hardLimit: 0.30,
            providerCallReserve: 0.03,
            finalizationReserve: 0.08
        )
        let executor = SequencedDelayedReadOnlyExecutor(delays: [.zero, .milliseconds(500)])

        let (task, events, _) = try await runCapturingNativeTask(
            input: "Inspect Legacy backend dependencies and database schema",
            fixture: fixture,
            initial: initial,
            actions: [nextToolAction(id: "hard-server", command: "engineering.list_directory", arguments: ["path=server"])],
            executor: executor,
            limits: limits
        )

        XCTAssertEqual(task.state, .blocked)
        XCTAssertEqual(events.filter { $0.payload["lifecycle_event"] == "TOOL_RESULT" }.count, 1)
        let blocked = try XCTUnwrap(events.last { $0.payload["blocker_reason"] == PlanReadinessBlocker.durationLimitReached.rawValue })
        XCTAssertEqual(blocked.payload["pending_tool_cancelled"], "true")
        XCTAssertEqual(blocked.payload["provider_stage"], "tool_execution")
        XCTAssertEqual(blocked.payload["evidence_requirements_satisfied_count"], "1")
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
        XCTAssertFalse(events.contains { $0.payload["partial_result"] == "true" })
    }

    func testPartialDurationTaskResumesSameIDWithoutRepeatingCompletedCommand() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep(id: "resume-inspect", command: "engineering.inspect_project")])
        let recoveryPlan = planOutput([
            toolStep(id: "resume-inspect-duplicate", command: "engineering.inspect_project"),
            toolStep(id: "resume-package", command: "engineering.read_file", arguments: ["path=package.json"])
        ])
        let repairedRecoveryPlan = planOutput([
            toolStep(id: "resume-package-repaired", command: "engineering.read_file", arguments: ["path=package.json"])
        ])
        let partial = finalOutput("Partial Legacy workspace report: the project root was inspected, but package.json was not inspected, so dependency conclusions are incomplete. Continue this same task to read the remaining manifest.")
        let complete = finalOutput("Inspected Legacy workspace and package.json. Confirmed facts: the recorded package.json contains dependencies and devDependencies. Limitations: static read-only inspection only.")
        let router = ScriptedReadOnlyRouter(outputs: [initial, partial, recoveryPlan, repairedRecoveryPlan, complete])
        let executor = SequencedDelayedReadOnlyExecutor(delays: [.milliseconds(300), .zero])
        var limits = ReadOnlyInspectionLimits.conservative
        limits.budgetOverride = ReadOnlyMissionBudget(
            kind: .projectInspection,
            softLimit: 0.38,
            hardLimit: 0.70,
            providerCallReserve: 0.08,
            finalizationReserve: 0.32
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: executor,
            completionPolicy: .evidenceRequired,
            readOnlyInspectionLimits: limits
        )

        let first = try await kernel.submitTask(input: "Inspect Legacy project dependencies", workspace: fixture.workspace)
        XCTAssertEqual(first.state, .waiting)
        let recovered = try await kernel.recoverTask(
            taskID: first.id,
            instruction: "继续读取剩余 manifest",
            workspace: fixture.workspace
        )
        let resumed = try XCTUnwrap(recovered)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: first.id)
        let commands = await executor.commands()

        XCTAssertEqual(resumed.id, first.id)
        XCTAssertEqual(resumed.state, .completed)
        XCTAssertEqual(commands.filter { $0 == "engineering.inspect_project" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "engineering.read_file" }.count, 1)
        XCTAssertTrue(events.contains {
            $0.payload["lifecycle_event"] == "RECOVERY_PLAN_GENERATED"
                && $0.payload["same_task_id_preserved"] == "true"
                && $0.payload["fresh_duration_budget"] == "true"
                && $0.payload["completed_command_signatures_preserved"] == "1"
        })
        XCTAssertTrue(events.contains {
            $0.payload["lifecycle_event"] == "PLAN_REPAIR_REQUESTED"
                && $0.payload["blocker_reason"] == PlanReadinessBlocker.commandAlreadyCompleted.rawValue
        })
        XCTAssertEqual(events.filter { $0.type == .taskCreated }.count, 1)
    }

    func testEvidenceRequirementsReportSatisfiedAndUnsatisfiedTargets() {
        let requirements = ReadOnlyEvidenceRequirements(
            request: "Inspect frontend and backend dependencies, database schema, and backend entry point"
        )
        let workspaceID = UUID()
        let evidence = [
            ReadOnlyInspectionEvidence(
                toolCallID: "inspect",
                toolName: "engineering.inspect_project",
                workspaceID: workspaceID,
                workspaceIdentity: "legacy",
                targetPath: ".",
                output: "package.json\nserver/",
                toolCalledEventID: UUID(),
                toolResultEventID: UUID()
            ),
            ReadOnlyInspectionEvidence(
                toolCallID: "package",
                toolName: "engineering.read_file",
                workspaceID: workspaceID,
                workspaceIdentity: "legacy",
                targetPath: "package.json",
                output: #"{"dependencies":{"react":"19"}}"#,
                toolCalledEventID: UUID(),
                toolResultEventID: UUID()
            )
        ]

        let payload = requirements.auditPayload(evidence: evidence)

        XCTAssertTrue(payload["satisfied_evidence_requirements"]?.contains("project_root_inspection") == true)
        XCTAssertTrue(payload["satisfied_evidence_requirements"]?.contains("frontend_manifest_or_config") == true)
        XCTAssertTrue(payload["unsatisfied_evidence_requirements"]?.contains("backend_manifest") == true)
        XCTAssertTrue(payload["unsatisfied_evidence_requirements"]?.contains("database_schema_or_config") == true)
        XCTAssertTrue(payload["unsatisfied_evidence_requirements"]?.contains("backend_startup_entry") == true)
    }

    func testGroundedReportContractMatchesChineseRequestLanguage() {
        let request = "检查当前项目"
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let evidence = [makeEvidence(
            id: "root",
            tool: "engineering.inspect_project",
            path: ".",
            output: "package.json\nserver/"
        )]

        let english = ReadOnlyFinalAnswerContract.validate(
            answer: "The legacy workspace contains package.json.",
            request: request,
            requirements: requirements,
            evidence: evidence,
            requireComplete: true
        )
        let chinese = ReadOnlyFinalAnswerContract.validate(
            answer: "已确认 legacy workspace 包含 package.json。",
            request: request,
            requirements: requirements,
            evidence: evidence,
            requireComplete: true
        )

        XCTAssertFalse(english.accepted)
        XCTAssertTrue(english.issues.contains { $0.contains("language_mismatch") })
        XCTAssertTrue(chinese.accepted)
    }

    func testFrontendRequirementNeedsExtractedFrameworkFactNotJustManifestRead() {
        let requirements = ReadOnlyEvidenceRequirements(request: "Inspect the frontend framework and dependencies")
        let evidence = [
            makeEvidence(id: "root", tool: "engineering.inspect_project", path: ".", output: "package.json\nsrc/"),
            makeEvidence(
                id: "manifest",
                tool: "engineering.read_file",
                path: "package.json",
                output: #"{"dependencies":{"lodash":"4"}}"#
            )
        ]
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: evidence)
        let frontend = ledger.requirements.first { $0.requirementID == ReadOnlyEvidenceRequirementKind.frontendManifestOrConfig.rawValue }

        XCTAssertEqual(frontend?.status, .partiallySatisfied)
        XCTAssertTrue(ledger.unsatisfied.contains(.frontendManifestOrConfig))
    }

    func testManifestReadExtractsReactViteAndSafeKeys() {
        let output = #"{"name":"pet-gifts","type":"module","scripts":{"dev":"secret command","build":"vite build"},"dependencies":{"react":"19","react-dom":"19"},"devDependencies":{"vite":"7"},"token":"do-not-expose"}"#
        let facts = ReadOnlySafeFactExtractor.extract(
            toolName: "engineering.read_file",
            targetPath: "package.json",
            output: output
        )

        XCTAssertEqual(facts.manifestName, "pet-gifts")
        XCTAssertEqual(facts.moduleType, "module")
        XCTAssertEqual(Set(facts.frontendFrameworks), Set(["React", "Vite"]))
        XCTAssertEqual(Set(facts.dependencyFacts), Set(["react", "react-dom", "vite"]))
        XCTAssertEqual(Set(facts.scriptKeys), Set(["build", "dev"]))
        XCTAssertFalse(facts.safeSummaries.joined().contains("do-not-expose"))
        XCTAssertFalse(facts.safeSummaries.joined().contains("secret command"))
    }

    func testNestedDirectoryEntriesRetainCanonicalParentAndProvenance() {
        let eventID = UUID()
        let facts = ReadOnlySafeFactExtractor.extract(
            toolName: "engineering.list_directory",
            targetPath: "server",
            output: "package.json 1142b\nsrc/\nprisma/schema.prisma 321b\n../escape 1b\n/absolute 1b"
        )
        let evidence = ReadOnlyInspectionEvidence(
            toolCallID: "list-server",
            toolName: "engineering.list_directory",
            workspaceID: UUID(),
            workspaceIdentity: "legacy",
            targetPath: "server",
            output: "unused",
            toolCalledEventID: UUID(),
            toolResultEventID: eventID,
            extractedFacts: facts
        )
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: ReadOnlyEvidenceRequirements(request: "Inspect project structure"),
            evidence: [evidence]
        )

        XCTAssertEqual(facts.structureEntries, [
            "server/package.json", "server/prisma/schema.prisma", "server/src/"
        ])
        XCTAssertEqual(facts.directoryEntries.first { $0.canonicalChildRelativePath == "server/src/" }?.entryType, .directory)
        XCTAssertFalse(facts.structureEntries.contains("package.json"))
        XCTAssertFalse(facts.structureEntries.contains { $0.contains("escape") || $0.contains("absolute") })
        let package = ledger.paths.first { $0.relativePath == "server/package.json" }
        XCTAssertEqual(package?.workspaceIdentity, "legacy")
        XCTAssertEqual(package?.requestedParentRelativePath, "server")
        XCTAssertEqual(package?.entryType, .file)
        XCTAssertEqual(package?.directoryEntrySuccessfulEventIDs, [eventID])
    }

    func testDuplicateBasenamesRemainDistinctCanonicalEvidencePaths() {
        let root = makeEvidence(
            id: "root-list",
            tool: "engineering.list_directory",
            path: ".",
            output: "package.json 10b\ntsconfig.json 20b\nserver/"
        )
        let server = makeEvidence(
            id: "server-list",
            tool: "engineering.list_directory",
            path: "server",
            output: "package.json 30b\ntsconfig.json 40b\nsrc/\nprisma/"
        )
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: ReadOnlyEvidenceRequirements(request: "Inspect project structure"),
            evidence: [root, server]
        )
        let paths = Set(ledger.paths.map(\.relativePath))

        XCTAssertTrue(paths.isSuperset(of: [
            "package.json", "tsconfig.json", "server/package.json", "server/tsconfig.json",
            "server/src/", "server/prisma/"
        ]))
        XCTAssertEqual(ledger.paths.filter { $0.relativePath.hasSuffix("package.json") }.count, 2)
    }

    func testManifestEntryDerivationPreservesExtensionAndGroundingEvent() {
        let resultEventID = UUID()
        let manifest = ReadOnlyInspectionEvidence(
            toolCallID: "backend-manifest",
            toolName: "engineering.read_file",
            workspaceID: UUID(),
            workspaceIdentity: "legacy",
            targetPath: "server/package.json",
            output: #"{"scripts":{"dev":"tsx watch src/index.ts"},"main":"dist/index.js"}"#,
            toolCalledEventID: UUID(),
            toolResultEventID: resultEventID
        )
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: ReadOnlyEvidenceRequirements(request: "Inspect backend entry"),
            evidence: [manifest]
        )

        XCTAssertTrue(manifest.structuredFacts.manifestDerivedPaths.contains("server/src/index.ts"))
        XCTAssertFalse(manifest.structuredFacts.manifestDerivedPaths.contains("server/src/index.js"))
        let entry = ledger.paths.first { $0.relativePath == "server/src/index.ts" }
        XCTAssertEqual(entry?.manifestDerivedBySuccessfulEventIDs, [resultEventID])
        XCTAssertTrue(entry?.successfullyReadByEventIDs.isEmpty == true)
    }

    func testListedManifestIsDiscoveredButDoesNotSatisfyBackendManifest() {
        let listing = makeEvidence(
            id: "server-list",
            tool: "engineering.list_directory",
            path: "server",
            output: "package.json 30b\nsrc/"
        )
        let requirements = ReadOnlyEvidenceRequirements(request: "Inspect backend framework and dependencies")
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: [listing])

        XCTAssertTrue(ledger.discoveredOnlyPaths.contains("server/package.json"))
        XCTAssertFalse(ledger.successfulReadPaths.contains("server/package.json"))
        XCTAssertTrue(ledger.unsatisfied.contains(.backendManifest))
        XCTAssertTrue(listing.structuredFacts.backendFrameworks.isEmpty)
    }

    func testLanguageClassificationSeparatesProgrammingConfigurationAndSchema() {
        let manifest = ReadOnlySafeFactExtractor.extract(
            toolName: "engineering.read_file",
            targetPath: "package.json",
            output: #"{"dependencies":{}}"#
        )
        let source = ReadOnlySafeFactExtractor.extract(
            toolName: "engineering.read_file",
            targetPath: "server/src/index.ts",
            output: "const value: string = 'ok'"
        )
        let schema = ReadOnlySafeFactExtractor.extract(
            toolName: "engineering.read_file",
            targetPath: "server/prisma/schema.prisma",
            output: "model Gift { id Int @id }"
        )

        XCTAssertTrue(manifest.languages.isEmpty)
        XCTAssertEqual(manifest.configurationFormats, ["JSON"])
        XCTAssertEqual(source.languages, ["TypeScript"])
        XCTAssertTrue(source.configurationFormats.isEmpty)
        XCTAssertEqual(schema.schemaLanguages, ["Prisma Schema Language"])
        XCTAssertTrue(schema.languages.isEmpty)
    }

    func testDeterministicReportGroupsCanonicalPathsWithoutFlattenedDuplicates() async {
        let evidence = [
            makeEvidence(
                id: "root-list",
                tool: "engineering.list_directory",
                path: ".",
                output: "package.json 10b\ntsconfig.json 20b\nnode_modules/\nsrc/\nserver/\ndocker-compose.yml 5b"
            ),
            makeEvidence(
                id: "server-list",
                tool: "engineering.list_directory",
                path: "server",
                output: "package.json 30b\ntsconfig.json 40b\nsrc/\nprisma/"
            )
        ]
        let request = "只读取 Legacy 项目并报告项目结构"
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let kernel = RuntimeKernel(
            persistence: InMemoryPersistenceStore(),
            eventBus: RuntimeEventBus(),
            modelRouter: ScriptedReadOnlyRouter(outputs: [])
        )

        let report = await kernel.groundedEvidenceFallback(
            request: request,
            evidence: evidence,
            satisfied: requirements.satisfied(by: evidence),
            unsatisfied: requirements.unsatisfied(by: evidence),
            decision: .completeWithCurrentEvidence
        )

        XCTAssertTrue(report.contains("根目录：`package.json`"))
        XCTAssertTrue(report.contains("- 后端："))
        XCTAssertTrue(report.contains("`server/package.json`"))
        XCTAssertTrue(report.contains("数据层：`server/prisma/`"))
        XCTAssertFalse(report.contains("node_modules"))
        XCTAssertFalse(report.contains("package.json 30b"))
    }

    func testGuessedBackendExtensionIsRejectedAndBackendManifestWinsPriority() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let (task, events) = try await runNativeTask(
            input: "只读检查 Legacy 项目的后端框架、后端入口、数据库和依赖",
            fixture: fixture,
            initial: planOutput([
                toolStep(id: "list-server-grounding", command: "engineering.list_directory", arguments: ["path=server"])
            ]),
            actions: [
                nextToolAction(id: "guessed-js", command: "engineering.read_file", arguments: ["path=server/src/index.js"]),
                nextToolAction(id: "grounded-backend-manifest", command: "engineering.read_file", arguments: ["path=server/package.json"])
            ]
        )

        XCTAssertEqual(task.state, .waiting)
        XCTAssertFalse(events.contains { $0.type == .toolCalled && $0.payload["target_path"] == "server/src/index.js" })
        XCTAssertTrue(events.contains { $0.type == .toolCalled && $0.payload["target_path"] == "server/package.json" })
        let repair = events.first {
            $0.payload["lifecycle_event"] == "NEXT_ACTION_REPAIR_REQUESTED"
                && $0.payload["rejection_reason"] == PlanReadinessBlocker.canonicalSearchPathRequired.rawValue
        }
        XCTAssertTrue(repair?.payload["exact_rejection"]?.contains("server/package.json") == true)
    }

    func testExactListedBackendEntryMayBeReadWithoutPathMutation() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(
                id: "list-backend-source",
                command: "engineering.list_directory",
                arguments: ["path=server/src"]
            )
        ])
        let answer = "Conclusion: `server/src/index.ts` was successfully read and directly shows the Express backend application. Limitations: static read-only inspection only; no build or test was run."

        let (task, events) = try await runNativeTask(
            input: "Inspect the exact Legacy backend entry point",
            fixture: fixture,
            initial: initial,
            actions: [
                nextToolAction(
                    id: "read-exact-backend-entry",
                    command: "engineering.read_file",
                    arguments: ["path=server/src/index.ts"]
                ),
                nextFinalAction(answer)
            ]
        )

        XCTAssertNotEqual(task.state, .failed)
        XCTAssertEqual(
            events.filter { $0.type == .toolCalled }.compactMap { $0.payload["target_path"] },
            ["server/src", "server/src/index.ts"]
        )
        XCTAssertFalse(events.contains {
            $0.type == .toolCalled && $0.payload["target_path"] == "index.ts"
        })
    }

    func testFilenameOnlyReadIsRepairedOnceFromExactCanonicalDiscoveryWithProvenance() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let answer = "Conclusion: `server/src/index.ts` was successfully read and directly shows the Express backend application. Limitations: static read-only inspection only; no build or test was run."

        let (task, events) = try await runNativeTask(
            input: "Inspect the exact Legacy backend entry point",
            fixture: fixture,
            initial: planOutput([
                toolStep(
                    id: "list-backend-source-for-repair",
                    command: "engineering.list_directory",
                    arguments: ["path=server/src"]
                )
            ]),
            actions: [
                nextToolAction(
                    id: "filename-only-entry",
                    command: "engineering.read_file",
                    arguments: ["path=index.ts"]
                ),
                nextFinalAction(answer)
            ]
        )

        XCTAssertEqual(task.state, .waiting)
        XCTAssertFalse(events.contains {
            $0.type == .toolCalled && $0.payload["target_path"] == "index.ts"
        })
        XCTAssertTrue(events.contains {
            $0.type == .toolCalled && $0.payload["target_path"] == "server/src/index.ts"
        })
        let rejected = try XCTUnwrap(events.first {
            $0.payload["rejection_reason"] == PlanReadinessBlocker.canonicalSearchPathRequired.rawValue
        })
        XCTAssertTrue(rejected.payload["exact_rejection"]?.contains("server/src/index.ts") == true)
        let repaired = try XCTUnwrap(events.first {
            $0.payload["canonical_path_repair_source"] == "bounded_deterministic_repair"
        })
        XCTAssertEqual(repaired.payload["canonical_path_repair_count"], "1")
        XCTAssertEqual(repaired.payload["canonical_path_repaired_to"], "server/src/index.ts")
        XCTAssertEqual(repaired.payload["canonical_path_provenance"], "trusted_discovered_metadata")
        XCTAssertFalse(repaired.payload["canonical_path_source_event_ids"]?.isEmpty ?? true)
    }

    func testInitialUngroundedReadRepairsToRootObservationWithoutExecutingRead() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([
            toolStep(id: "initial-guess", command: "engineering.read_file", arguments: ["path=package.json"])
        ])
        let repaired = planOutput([
            toolStep(id: "ground-root", command: "engineering.list_directory", arguments: ["path=."])
        ])
        let answer = "Inspected facts: the Legacy root contains canonical project entries. Limitations: no file contents were read or modified."
        let (task, events, _) = try await runTask(
            input: "Inspect the Legacy project root structure without modifying files",
            fixture: fixture,
            outputs: [initial, repaired, finalOutput(answer)]
        )

        XCTAssertNotEqual(task.state, .failed)
        XCTAssertFalse(events.contains { $0.type == .toolCalled && $0.payload["command"] == "engineering.read_file" })
        XCTAssertTrue(events.contains {
            $0.payload["lifecycle_event"] == "PLAN_REPAIR_REQUESTED"
                && $0.payload["blocker_reason"] == PlanReadinessBlocker.canonicalSearchPathRequired.rawValue
        })
    }

    func testBackendFrameworkRequiresFastifyManifestOrBootstrapFact() {
        let manifest = makeEvidence(
            id: "backend-manifest",
            tool: "engineering.read_file",
            path: "server/package.json",
            output: #"{"dependencies":{"fastify":"5","@fastify/cors":"11"}}"#
        )
        let entry = makeEvidence(
            id: "backend-entry",
            tool: "engineering.read_file",
            path: "server/src/index.ts",
            output: "import Fastify from 'fastify';\nconst app = Fastify();\napp.listen({ port: 3000 });"
        )
        let requirements = ReadOnlyEvidenceRequirements(request: "Inspect the backend framework and backend entry point")
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: [manifest, entry])

        XCTAssertEqual(manifest.structuredFacts.backendFrameworks, ["Fastify"])
        XCTAssertTrue(entry.structuredFacts.serverBootstrap)
        XCTAssertTrue(ledger.satisfied.contains(.backendManifest))
        XCTAssertTrue(ledger.satisfied.contains(.backendEntryPoint))
    }

    func testPrismaORMDoesNotEstablishDatabaseWithoutDatasourceProvider() {
        let manifest = makeEvidence(
            id: "backend-manifest",
            tool: "engineering.read_file",
            path: "server/package.json",
            output: #"{"dependencies":{"@prisma/client":"6"},"devDependencies":{"prisma":"6"}}"#
        )
        let schema = makeEvidence(
            id: "schema",
            tool: "engineering.read_file",
            path: "server/prisma/schema.prisma",
            output: "datasource db {\n provider = \"postgresql\"\n url = env(\"DATABASE_URL\")\n}\ngenerator client {\n provider = \"prisma-client-js\"\n}\nmodel Gift {\n id Int @id\n}\nenum Status {\n ACTIVE\n}"
        )
        let requirements = ReadOnlyEvidenceRequirements(request: "Inspect the database and Prisma schema")

        XCTAssertEqual(manifest.structuredFacts.ormNames, ["Prisma"])
        XCTAssertTrue(ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: [manifest]).unsatisfied.contains(.databaseSchemaOrConfig))
        XCTAssertEqual(schema.structuredFacts.databaseProviders, ["PostgreSQL"])
        XCTAssertEqual(schema.structuredFacts.modelNames, ["Gift"])
        XCTAssertEqual(schema.structuredFacts.enumNames, ["Status"])
        XCTAssertTrue(ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: [manifest, schema]).satisfied.contains(.databaseSchemaOrConfig))
    }

    func testImportantDependenciesRequireActualExtractedNames() {
        let requirements = ReadOnlyEvidenceRequirements(request: "Inspect important dependencies")
        let evidence = [makeEvidence(
            id: "manifest",
            tool: "engineering.read_file",
            path: "package.json",
            output: #"{"dependencies":{"react":"19","zod":"4"},"devDependencies":{"vite":"7"}}"#
        )]
        let entry = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: evidence)
            .requirements.first { $0.requirementID == ReadOnlyEvidenceRequirementKind.importantDependencies.rawValue }

        XCTAssertEqual(entry?.status, .satisfied)
        XCTAssertEqual(Set(entry?.extractedSafeFacts ?? []), Set(["dependency=react", "dependency=vite", "dependency=zod"]))
    }

    func testContradictionGuardRejectsRereadingSuccessfulManifest() {
        let request = "Inspect dependencies and list actually read manifests"
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let evidence = [makeEvidence(
            id: "manifest",
            tool: "engineering.read_file",
            path: "package.json",
            output: #"{"dependencies":{"react":"19"}}"#
        )]
        let validation = ReadOnlyFinalAnswerContract.validate(
            answer: "Confirmed dependency: React from package.json. Next, continue reading package.json as it is unread.",
            request: request,
            requirements: requirements,
            evidence: evidence,
            requireComplete: true
        )

        XCTAssertFalse(validation.accepted)
        XCTAssertTrue(validation.issues.contains("successfully_read_file_recommended_as_unread:package.json"))
    }

    func testCompleteAnswerCannotAdmitMaterialRequirementIsUnresolved() {
        let (request, requirements, evidence) = completeNodeEvidence()
        let answer = """
        已确认前端 React + Vite（package.json），后端 Fastify（server/package.json、server/src/index.ts），数据库 PostgreSQL 和 ORM Prisma（server/prisma/schema.prisma）。重要依赖包括 react、vite、fastify、@prisma/client。实际读取 package.json、server/package.json、server/src/index.ts、server/prisma/schema.prisma。前端框架未确认。
        """
        let validation = ReadOnlyFinalAnswerContract.validate(
            answer: answer,
            request: request,
            requirements: requirements,
            evidence: evidence,
            requireComplete: true
        )

        XCTAssertFalse(validation.accepted)
        XCTAssertTrue(validation.issues.contains("complete_answer_contains_unresolved_material_requirement"))
    }

    func testSuccessfulReadPathIsSharedByLedgerAndFinalAnswerContract() {
        let requirements = ReadOnlyEvidenceRequirements(request: "Inspect backend dependencies and list actually read manifests")
        let evidence = [makeEvidence(
            id: "server-manifest",
            tool: "engineering.read_file",
            path: "server/package.json",
            output: #"{"dependencies":{"fastify":"5"}}"#
        )]
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: evidence, finalAnswer: "Fastify is confirmed from server/package.json.")
        let path = ledger.paths.first { $0.relativePath == "server/package.json" }

        XCTAssertEqual(path?.successfullyReadByEventIDs.count, 1)
        XCTAssertTrue(path?.extractedFactKinds.contains("backend_frameworks") == true)
        XCTAssertEqual(path?.includedInFinalAnswer, true)
        XCTAssertTrue(ledger.auditPayload["successful_inspected_paths"]?.contains("server/package.json") == true)
    }

    func testToolCallWithoutSuccessfulResultCannotEnterEvidenceLedger() {
        let requirements = ReadOnlyEvidenceRequirements(request: "Inspect backend dependencies")
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: [])

        XCTAssertTrue(ledger.successfulReadPaths.isEmpty)
        XCTAssertTrue(ledger.unsatisfied.contains(.backendManifest))
        XCTAssertFalse(ledger.auditPayload["successful_inspected_paths"]?.contains("server/package.json") == true)
    }

    func testSearchDiscoveryIsNotAReadAndCannotConfirmFrontendConfiguration() {
        let requirements = ReadOnlyEvidenceRequirements(request: "Inspect frontend configuration")
        let search = makeEvidence(
            id: "search",
            tool: "engineering.search_files",
            path: ".",
            output: "vite.config.ts:1: import { defineConfig } from 'vite'"
        )
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: [search])

        XCTAssertTrue(ledger.discoveredOnlyPaths.contains("vite.config.ts"))
        XCTAssertFalse(ledger.successfulReadPaths.contains("vite.config.ts"))
        XCTAssertTrue(ledger.unsatisfied.contains(.frontendConfiguration))
    }

    func testDeterministicFallbackUsesChineseAndStartsWithConclusion() async throws {
        let (request, requirements, evidence) = completeNodeEvidence()
        let persistence = InMemoryPersistenceStore()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ScriptedReadOnlyRouter(outputs: [])
        )

        let report = await kernel.groundedEvidenceFallback(
            request: request,
            evidence: evidence,
            satisfied: requirements.satisfied(by: evidence),
            unsatisfied: requirements.unsatisfied(by: evidence),
            decision: .completeWithCurrentEvidence
        )

        XCTAssertTrue(report.hasPrefix("## 结论"))
        XCTAssertTrue(report.contains("React"))
        XCTAssertTrue(report.contains("Fastify"))
        XCTAssertTrue(report.contains("PostgreSQL"))
        XCTAssertTrue(report.contains("server/package.json"))
        XCTAssertFalse(report.contains("likely other dependencies"))
        XCTAssertFalse(report.contains("BLOCKED_WITH_PARTIAL_RESULT"))
    }

    func testNaturalCompleteReportContractAcceptsConfirmedFactsAndPaths() {
        let (request, requirements, evidence) = completeNodeEvidence()
        let answer = """
        ## 结论
        这是一个前后端分离的 TypeScript 项目。前端使用 React + Vite，后端使用 Fastify，ORM 为 Prisma，数据库为 PostgreSQL。
        ## 已确认的技术栈
        React 与 Vite 来自 package.json；Fastify 来自 server/package.json 和 server/src/index.ts；PostgreSQL 与 Prisma 来自 server/prisma/schema.prisma。
        ## 项目结构与主要语言
        根目录包含 package.json 和 server/；主要语言为 TypeScript、JSON、Prisma schema。
        ## 重要依赖
        react、vite、fastify、@prisma/client。
        ## 实际读取的文件
        package.json、server/package.json、server/src/index.ts、server/prisma/schema.prisma。
        ## 推断与限制
        仅做只读静态检查，未执行构建或测试。
        ## 下一步
        当前请求无需重复读取上述文件。
        """
        let validation = ReadOnlyFinalAnswerContract.validate(
            answer: answer,
            request: request,
            requirements: requirements,
            evidence: evidence,
            requireComplete: true
        )

        XCTAssertTrue(validation.accepted, validation.issues.joined(separator: ", "))
    }

    private func completeNodeEvidence() -> (String, ReadOnlyEvidenceRequirements, [ReadOnlyInspectionEvidence]) {
        let request = "只读取当前 Legacy 项目，检查项目结构、主要语言、前端框架、后端框架、数据库和重要依赖。回答必须列出实际读取的 manifest 和关键文件。"
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let evidence = [
            makeEvidence(id: "root", tool: "engineering.inspect_project", path: ".", output: "package.json\nserver/\nsrc/"),
            makeEvidence(id: "frontend", tool: "engineering.read_file", path: "package.json", output: #"{"dependencies":{"react":"19"},"devDependencies":{"vite":"7"}}"#),
            makeEvidence(id: "backend", tool: "engineering.read_file", path: "server/package.json", output: #"{"dependencies":{"fastify":"5","@prisma/client":"6"}}"#),
            makeEvidence(id: "entry", tool: "engineering.read_file", path: "server/src/index.ts", output: "import Fastify from 'fastify';\nconst app = Fastify();\napp.listen({ port: 3000 });"),
            makeEvidence(id: "schema", tool: "engineering.read_file", path: "server/prisma/schema.prisma", output: "datasource db {\n provider = \"postgresql\"\n}\ngenerator client {\n provider = \"prisma-client-js\"\n}")
        ]
        return (request, requirements, evidence)
    }

    private func makeEvidence(id: String, tool: String, path: String, output: String) -> ReadOnlyInspectionEvidence {
        ReadOnlyInspectionEvidence(
            toolCallID: id,
            toolName: tool,
            workspaceID: UUID(),
            workspaceIdentity: "legacy",
            targetPath: path,
            output: output,
            toolCalledEventID: UUID(),
            toolResultEventID: UUID()
        )
    }

    // MARK: - Helpers

    private struct Fixture {
        var container: URL
        var legacy: URL
        var agent: URL
        var workspace: Workspace
    }

    private func makeSwiftFixture() throws -> Fixture {
        let fixture = try makeEmptyFixture()
        try write(fixture.legacy.appendingPathComponent("Package.swift"), "// swift-tools-version: 6.0\nimport PackageDescription\n")
        try write(fixture.legacy.appendingPathComponent("Sources/App/Main.swift"), "@main struct Main { static func main() {} }\n")
        try write(
            fixture.legacy.appendingPathComponent("Sources/App/DataLoader.swift"),
            "import Foundation\nstruct DataLoader { func load(_ url: URL) throws -> Data { try Data(contentsOf: url) } }\n"
        )
        try write(
            fixture.legacy.appendingPathComponent("Sources/App/ViewModel.swift"),
            "struct ViewModel { var values: [Int]; var sortedValues: [Int] { values.sorted() } }\n"
        )
        try write(fixture.legacy.appendingPathComponent("Tests/AppTests/AppTests.swift"), "import XCTest\nfinal class AppTests: XCTestCase {}\n")
        try write(fixture.agent.appendingPathComponent("Agent.swift"), "struct Agent {}\n")
        return fixture
    }

    private func makeNodeFixture() throws -> Fixture {
        let fixture = try makeEmptyFixture()
        try write(fixture.legacy.appendingPathComponent("package.json"), #"{"dependencies":{"react":"19.0.0"},"devDependencies":{"vite":"7.0.0"}}"#)
        try write(fixture.legacy.appendingPathComponent("server/package.json"), #"{"dependencies":{"express":"5.0.0","@prisma/client":"6.0.0"}}"#)
        try write(fixture.legacy.appendingPathComponent("vite.config.ts"), "import { defineConfig } from 'vite';\nexport default defineConfig({});\n")
        try write(fixture.legacy.appendingPathComponent("src/App.tsx"), "import React from 'react';\nexport function App() { return <main>App</main>; }\n")
        try write(fixture.legacy.appendingPathComponent("server/src/index.ts"), "import express from 'express';\nconst app = express();\n")
        try write(fixture.legacy.appendingPathComponent("server/prisma/schema.prisma"), "datasource db {\n  provider = \"postgresql\"\n  url = env(\"DATABASE_URL\")\n}\n")
        try write(fixture.agent.appendingPathComponent("Agent.swift"), "struct AgentOnlyEvidence {}\n")
        return fixture
    }

    private func makeEmptyFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("FDEReadOnly-\(UUID().uuidString)", isDirectory: true)
        let legacy = container.appendingPathComponent("Legacy", isDirectory: true)
        let agent = container.appendingPathComponent("Agent", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let workspace = Workspace(
            id: UUID(),
            name: "Read-only fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacy.path,
            localAgentProjectRoot: agent.path
        )
        return Fixture(container: container, legacy: legacy, agent: agent, workspace: workspace)
    }

    private func write(_ url: URL, _ value: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func toolStep(
        id: String,
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil
    ) -> (PlanStep, ToolCall) {
        let callID = "tool.\(id)"
        return (
            PlanStep(id: "step.\(id)", title: id, intent: "Execute \(command).", kind: .tool, toolCallID: callID, requiresApproval: false),
            ToolCall(id: callID, type: .api, command: command, arguments: arguments, workingDirectory: workingDirectory, requiresApproval: false)
        )
    }

    private func planOutput(_ values: [(PlanStep, ToolCall)]) -> StructuredAgentOutput {
        StructuredAgentOutput(plan: values.map(\.0), actions: [], toolCalls: values.map(\.1), risks: [], confidence: 0.9)
    }

    private func planWithSingleStep(_ step: PlanStep, calls: [ToolCall]) -> StructuredAgentOutput {
        StructuredAgentOutput(plan: [step], actions: [], toolCalls: calls, risks: [], confidence: 0.8)
    }

    private func finalOutput(_ answer: String) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [PlanStep(id: "final.\(UUID().uuidString)", title: "Grounded report", intent: answer, kind: .finalization, toolCallID: nil, requiresApproval: false)],
            actions: [],
            toolCalls: [],
            risks: [],
            confidence: 0.9
        )
    }

    private func nextToolCall(id: String, command: String, arguments: [String] = []) -> ToolCall {
        ToolCall(id: id, type: .api, command: command, arguments: arguments, workingDirectory: nil, requiresApproval: false)
    }

    private func nextToolAction(id: String, command: String, arguments: [String] = []) -> ReadOnlyNextAction {
        ReadOnlyNextAction(
            decision: .tool,
            toolCalls: [nextToolCall(id: id, command: command, arguments: arguments)],
            reasoningSummary: "Gather one additional read-only evidence item."
        )
    }

    private func nextFinalAction(_ answer: String) -> ReadOnlyNextAction {
        ReadOnlyNextAction(decision: .finalize, finalAnswer: answer)
    }

    private func runTask(
        input: String,
        fixture: Fixture,
        outputs: [StructuredAgentOutput],
        limits: ReadOnlyInspectionLimits = .conservative
    ) async throws -> (FDETask, [ExecutionEvent], ScriptedReadOnlyRouter) {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let router = ScriptedReadOnlyRouter(outputs: outputs)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired,
            readOnlyInspectionLimits: limits
        )
        let task = try await kernel.submitTask(input: input, workspace: fixture.workspace)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
        return (task, events, router)
    }

    private func runNativeTask(
        input: String,
        fixture: Fixture,
        initial: StructuredAgentOutput,
        actions: [ReadOnlyNextAction],
        limits: ReadOnlyInspectionLimits = .conservative
    ) async throws -> (FDETask, [ExecutionEvent]) {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let router = ScriptedNativeNextActionRouter(initial: initial, actions: actions)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired,
            readOnlyInspectionLimits: limits
        )
        let task = try await kernel.submitTask(input: input, workspace: fixture.workspace)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
        return (task, events)
    }

    private func runCapturingNativeTask(
        input: String,
        fixture: Fixture,
        initial: StructuredAgentOutput,
        actions: [ReadOnlyNextAction],
        executor: any ToolExecuting,
        limits: ReadOnlyInspectionLimits
    ) async throws -> (FDETask, [ExecutionEvent], CapturingNativeNextActionRouter) {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let router = CapturingNativeNextActionRouter(initial: initial, actions: actions)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: executor,
            completionPolicy: .evidenceRequired,
            readOnlyInspectionLimits: limits
        )
        let task = try await kernel.submitTask(input: input, workspace: fixture.workspace)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
        return (task, events, router)
    }

    private func event(type: EventType, sequence: Int64, payload: [String: String]) -> ExecutionEvent {
        let workspaceID = UUID()
        return ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: UUID(),
            type: type,
            sequence: sequence,
            timestamp: Date(),
            summary: type.rawValue,
            payload: payload
        )
    }
}

private actor ScriptedReadOnlyRouter: ModelRouting {
    private var outputs: [StructuredAgentOutput]
    private var decisions = 0

    init(outputs: [StructuredAgentOutput]) {
        self.outputs = outputs
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try next()
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        decisions += 1
        return try next()
    }

    func decisionCount() -> Int { decisions }

    private func next() throws -> StructuredAgentOutput {
        guard !outputs.isEmpty else {
            throw ModelRoutingError.providerUnavailable("Scripted read-only output exhausted.")
        }
        return outputs.removeFirst()
    }
}

private actor ScriptedNativeNextActionRouter: ModelRouting {
    private let initial: StructuredAgentOutput
    private var actions: [ReadOnlyNextAction]
    private var planReturned = false

    init(initial: StructuredAgentOutput, actions: [ReadOnlyNextAction]) {
        self.initial = initial
        self.actions = actions
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        guard !planReturned else {
            throw ModelRoutingError.providerOutputInvalid("Initial plan requested more than once.")
        }
        planReturned = true
        return initial
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction {
        guard !actions.isEmpty else {
            throw ModelRoutingError.providerOutputInvalid("Scripted next-action output exhausted.")
        }
        return actions.removeFirst()
    }
}

private actor CapturingNativeNextActionRouter: ModelRouting {
    private let initial: StructuredAgentOutput
    private var actions: [ReadOnlyNextAction]
    private var planReturned = false
    private var prompts: [String] = []

    init(initial: StructuredAgentOutput, actions: [ReadOnlyNextAction]) {
        self.initial = initial
        self.actions = actions
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        guard !planReturned else {
            throw ModelRoutingError.providerOutputInvalid("Initial plan requested more than once.")
        }
        planReturned = true
        return initial
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) async throws -> ReadOnlyNextAction {
        prompts.append(prompt.userPrompt)
        guard !actions.isEmpty else {
            throw ModelRoutingError.providerOutputInvalid("Scripted next-action output exhausted.")
        }
        return actions.removeFirst()
    }

    func observationPrompts() -> [String] { prompts }
}

private actor SequencedDelayedReadOnlyExecutor: ToolExecuting {
    private var delays: [Duration]
    private var recordedCommands: [String] = []
    private let delegate = WorkspaceEngineeringToolExecutor()

    init(delays: [Duration]) {
        self.delays = delays
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        recordedCommands.append(call.command)
        let delay = delays.isEmpty ? Duration.zero : delays.removeFirst()
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try await delegate.execute(call)
    }

    func commands() -> [String] { recordedCommands }
}

private actor DelayedReadOnlyToolExecutor: ToolExecuting {
    private var count = 0

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        count += 1
        try await Task.sleep(for: .seconds(2))
        return ToolExecutionResult(callID: call.id, exitCode: 0, standardOutput: "Files: 1\nSources/App.swift", standardError: "", duration: 2)
    }

    func callCount() -> Int { count }
}

private struct DiagnosticFailingRouter: ModelRouting {
    var error: ModelRoutingError

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        throw error
    }
}

private actor RetryingObservationRouter: ModelRouting {
    private let initial: StructuredAgentOutput
    private let final: StructuredAgentOutput
    private let firstFailure: ModelProviderFailure
    private var decisions = 0

    init(initial: StructuredAgentOutput, final: StructuredAgentOutput, firstFailure: ModelProviderFailure) {
        self.initial = initial
        self.final = final
        self.firstFailure = firstFailure
    }

    func generatePlan(for input: String, context: ExecutionContext) -> StructuredAgentOutput {
        initial
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) throws -> StructuredAgentOutput {
        decisions += 1
        if decisions == 1 {
            throw firstFailure
        }
        return final
    }

    func decisionCount() -> Int { decisions }
}

private actor FailingObservationRouter: ModelRouting {
    private let initial: StructuredAgentOutput
    private let failure: ModelProviderFailure

    init(initial: StructuredAgentOutput, failure: ModelProviderFailure) {
        self.initial = initial
        self.failure = failure
    }

    func generatePlan(for input: String, context: ExecutionContext) -> StructuredAgentOutput {
        initial
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) throws -> StructuredAgentOutput {
        throw failure
    }
}

private actor FailingFinalizationRouter: ModelRouting {
    private let initial: StructuredAgentOutput
    private let action: ReadOnlyNextAction
    private let failure: ModelProviderFailure
    private var planReturned = false
    private var actionReturned = false

    init(initial: StructuredAgentOutput, action: ReadOnlyNextAction, failure: ModelProviderFailure) {
        self.initial = initial
        self.action = action
        self.failure = failure
    }

    func generatePlan(for input: String, context: ExecutionContext) throws -> StructuredAgentOutput {
        guard !planReturned else { throw failure }
        planReturned = true
        return initial
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) throws -> ReadOnlyNextAction {
        if !actionReturned {
            actionReturned = true
            return action
        }
        throw failure
    }
}

private actor PlannerTimeoutRouter: ModelRouting {
    private let failure: ModelProviderFailure
    private var calls = 0

    init(failure: ModelProviderFailure) {
        self.failure = failure
    }

    func generatePlan(for input: String, context: ExecutionContext) throws -> StructuredAgentOutput {
        calls += 1
        throw failure
    }

    func callCount() -> Int { calls }
}
