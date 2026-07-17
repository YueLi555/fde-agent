import Foundation

enum MissionExecutionSemantic: String, Codable, Hashable, Sendable {
    case conversation = "CONVERSATION"
    case readOnlyWorkspaceInspection = "READ_ONLY_WORKSPACE_INSPECTION"
    case safeSandboxAcceptance = "SAFE_SANDBOX_ACCEPTANCE"
    case candidatePatchGeneration = "CANDIDATE_PATCH_GENERATION"
    case candidatePatchRevert = "CANDIDATE_PATCH_REVERT"
    case candidatePatchSandboxDestroy = "CANDIDATE_PATCH_SANDBOX_DESTROY"
    case engineeringModification = "ENGINEERING_MODIFICATION"

    init(intent: MissionIntent) {
        switch intent.intentType {
        case .candidatePatchSandboxDestroy:
            self = .candidatePatchSandboxDestroy
        case .candidatePatchRevert:
            self = .candidatePatchRevert
        case .candidatePatchGeneration:
            self = .candidatePatchGeneration
        case .safeSandboxAcceptance:
            self = .safeSandboxAcceptance
        case .aiAgentCompatibilityAssessment, .inspectWorkspace, .architectureAnalysis, .explainCode, .generateReport:
            self = .readOnlyWorkspaceInspection
        case .answerQuestion where intent.constraints.contains(.readOnly):
            self = .readOnlyWorkspaceInspection
        case .modifyCode, .createFeature, .refactorCode, .debugIssue, .runTests, .manageRuntime:
            self = .engineeringModification
        case .answerQuestion, .unknown:
            self = .conversation
        }
    }
}

enum ReadOnlyInspectionPolicy {
    static let allowedTools: Set<String> = [
        "engineering.list_directory",
        "engineering.inspect_project",
        "engineering.search_files",
        "engineering.search_code",
        "engineering.read_file"
    ]

    static let orderedAllowedTools = [
        "engineering.inspect_project",
        "engineering.list_directory",
        "engineering.search_files",
        "engineering.search_code",
        "engineering.read_file"
    ]
}

enum ReadOnlySensitivePathPolicy {
    private static let exactNames: Set<String> = [
        ".env", ".env.local", ".env.development", ".env.production", ".env.test",
        "credentials", "credentials.json", "secrets.json", "id_rsa", "id_ed25519"
    ]
    private static let sensitiveExtensions: Set<String> = ["pem", "p12", "pfx", "key", "keystore"]
    private static let sensitiveComponents: Set<String> = [".ssh", ".aws", ".gnupg", "secrets"]

    static func isSensitive(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let components = normalized.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        return exactNames.contains(name)
            || name.hasPrefix(".env.")
            || sensitiveExtensions.contains(URL(fileURLWithPath: name).pathExtension)
            || components.contains(where: sensitiveComponents.contains)
    }
}

enum ReadOnlyWorkspaceTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case legacy
    case agent
}

enum ReadOnlyMissionTarget: String, Codable, Hashable, Sendable {
    case legacy
    case agent
    case comparison

    init(request: String) {
        let value = request.lowercased()
        let mentionsLegacy = value.contains("legacy") || value.contains("旧项目") || value.contains("传统项目")
        let mentionsAgent = value.contains("agent") || value.contains("智能体")
        let explicitlyTargetsAgentWorkspace = [
            "agent workspace", "agent project", "agent codebase", "agent repository", "agent repo",
            "agent 工作区", "agent 项目", "agent 代码库", "agent 仓库",
            "智能体工作区", "智能体项目", "智能体代码库", "智能体仓库"
        ].contains { value.contains($0) }
        let explicitlyExcludesAgent = [
            "legacy only", "only legacy", "只读取 legacy", "只读 legacy", "只检查 legacy",
            "不要分析 agent", "不要检查 agent", "不要读取 agent", "不分析 agent", "不检查 agent",
            "do not analyze agent", "do not inspect agent", "do not read agent", "exclude agent"
        ].contains { value.contains($0) }
        let explicitlyExcludesLegacy = [
            "agent only", "only agent", "只读取 agent", "只读 agent", "只检查 agent",
            "不要分析 legacy", "不要检查 legacy", "不要读取 legacy", "不分析 legacy", "不检查 legacy",
            "do not analyze legacy", "do not inspect legacy", "do not read legacy", "exclude legacy"
        ].contains { value.contains($0) }
        let integrationComparison = mentionsAgent && [
            "integrate", "integration", "compatible", "compatibility",
            "可以接", "接入", "集成"
        ].contains { value.contains($0) }
        let explicitlyCompares = integrationComparison
            || value.contains("compare") || value.contains("comparison")
            || value.contains("对比") || value.contains("比较") || value.contains("两者")
            || value.contains("检查它们如何连接") || value.contains("它们如何连接")
            || value.contains("how they connect") || value.contains("compatibility between")
            || value.contains("both workspaces") || value.contains("both projects")
            || value.contains("legacy and agent") || value.contains("legacy 与 agent")
            || value.contains("legacy 和 agent")
        if explicitlyCompares && !explicitlyExcludesAgent && !explicitlyExcludesLegacy {
            self = .comparison
        } else if explicitlyExcludesAgent {
            self = .legacy
        } else if explicitlyExcludesLegacy {
            self = .agent
        } else if mentionsLegacy {
            self = .legacy
        } else if mentionsAgent && explicitlyTargetsAgentWorkspace {
            self = .agent
        } else {
            // "AI Agent" commonly names the capability being assessed, not the
            // Agent source workspace. The selected Legacy project remains the
            // default unless the request explicitly targets another codebase.
            self = .legacy
        }
    }

    var unambiguousWorkspace: ReadOnlyWorkspaceTarget? {
        switch self {
        case .legacy: .legacy
        case .agent: .agent
        case .comparison: nil
        }
    }
}

enum MissionWorkspaceScope: String, Codable, CaseIterable, Hashable, Sendable {
    case legacyOnly
    case agentOnly
    case legacyAndAgentComparison

    init(request: String) {
        switch ReadOnlyMissionTarget(request: request) {
        case .legacy:
            self = .legacyOnly
        case .agent:
            self = .agentOnly
        case .comparison:
            self = .legacyAndAgentComparison
        }
    }

    var readOnlyMissionTarget: ReadOnlyMissionTarget {
        switch self {
        case .legacyOnly: .legacy
        case .agentOnly: .agent
        case .legacyAndAgentComparison: .comparison
        }
    }

    var codebaseRoles: Set<String> {
        switch self {
        case .legacyOnly: ["legacy_software"]
        case .agentOnly: ["ai_agent"]
        case .legacyAndAgentComparison: ["legacy_software", "ai_agent"]
        }
    }
}

struct ReadOnlyToolArgumentSchema: Hashable, Sendable {
    var command: String
    var requiredModelArguments: [String]
    var runtimeDefaultableArguments: [String]
    var optionalArguments: [String]
    var exampleArguments: [String]

    var allowedArguments: [String] {
        Array(Set(requiredModelArguments + runtimeDefaultableArguments + optionalArguments)).sorted()
    }
}

enum ReadOnlyToolSchemas {
    static let all: [String: ReadOnlyToolArgumentSchema] = [
        "engineering.inspect_project": ReadOnlyToolArgumentSchema(
            command: "engineering.inspect_project",
            requiredModelArguments: [],
            runtimeDefaultableArguments: ["workspace", "path", "workingDirectory"],
            optionalArguments: [],
            exampleArguments: ["workspace=legacy", "path=."]
        ),
        "engineering.list_directory": ReadOnlyToolArgumentSchema(
            command: "engineering.list_directory",
            requiredModelArguments: [],
            runtimeDefaultableArguments: ["workspace", "path", "workingDirectory"],
            optionalArguments: [],
            exampleArguments: ["workspace=legacy", "path=."]
        ),
        "engineering.search_files": ReadOnlyToolArgumentSchema(
            command: "engineering.search_files",
            requiredModelArguments: ["query"],
            runtimeDefaultableArguments: ["workspace", "path", "workingDirectory"],
            optionalArguments: ["extensions"],
            exampleArguments: ["workspace=legacy", "query=package.json", "path=."]
        ),
        "engineering.search_code": ReadOnlyToolArgumentSchema(
            command: "engineering.search_code",
            requiredModelArguments: ["query"],
            runtimeDefaultableArguments: ["workspace", "path", "workingDirectory"],
            optionalArguments: ["extensions"],
            exampleArguments: ["workspace=legacy", "query=Data(contentsOf", "path=."]
        ),
        "engineering.read_file": ReadOnlyToolArgumentSchema(
            command: "engineering.read_file",
            requiredModelArguments: ["path"],
            runtimeDefaultableArguments: ["workspace", "workingDirectory"],
            optionalArguments: [],
            exampleArguments: ["workspace=legacy", "path=package.json"]
        )
    ]
}

enum PlanReadinessBlocker: String, Codable, Hashable, Sendable {
    case noExecutableToolStep = "no_executable_tool_step"
    case invalidToolCallReference = "invalid_tool_call_reference"
    case duplicateToolCallID = "duplicate_tool_call_id"
    case toolNotAllowed = "tool_not_allowed"
    case mutationProhibited = "mutation_prohibited"
    case missingRequiredArguments = "missing_required_arguments"
    case invalidArguments = "invalid_arguments"
    case approvalRequired = "approval_required"
    case workingDirectoryOutsideWorkspace = "working_directory_outside_workspace"
    case pathOutsideWorkspace = "path_outside_workspace"
    case workspaceNotFound = "workspace_not_found"
    case workspaceUnreadable = "workspace_unreadable"
    case workspaceTargetMismatch = "workspace_target_mismatch"
    case workspaceScopeMismatch = "workspace_scope_mismatch"
    case clarificationRequired = "clarification_required"
    case invalidPlanStep = "invalid_plan_step"
    case repairFailed = "plan_repair_failed"
    case invalidNextAction = "invalid_next_action"
    case multipleNextActions = "multiple_next_actions"
    case nextActionMissingTool = "next_action_missing_tool"
    case nextActionInvalidTool = "next_action_invalid_tool"
    case commandAlreadyCompleted = "command_already_completed"
    case commandPreviouslyFailed = "command_previously_failed"
    case explicitNoRereadConstraint = "explicit_no_reread_constraint"
    case canonicalSearchPathRequired = "canonical_search_path_required"
    case sensitiveFileExcluded = "sensitive_file_excluded"
    case insufficientEvidenceToFinalize = "insufficient_evidence_to_finalize"
    case nextActionRepairFailed = "next_action_repair_failed"
    case workspaceEmpty = "workspace_empty"
    case noSourceFiles = "no_source_files"
    case iterationLimitReached = "iteration_limit_reached"
    case toolCallLimitReached = "tool_call_limit_reached"
    case fileReadLimitReached = "file_read_limit_reached"
    case softDeadlineReached = "soft_deadline_reached"
    case durationLimitReached = "duration_limit_reached"
    case inspectionCancelled = "inspection_cancelled"
    case plannerProviderUnavailable = "planner_provider_unavailable"
    case repairProviderUnavailable = "repair_provider_unavailable"
    case observationProviderUnavailable = "observation_provider_unavailable"
    case finalAnswerProviderUnavailable = "final_answer_provider_unavailable"
    case providerRequestFailed = "provider_request_failed"
    case providerOutputInvalid = "provider_output_invalid"
    case providerTransportFailed = "provider_transport_failed"
    case providerHTTPFailed = "provider_http_failed"
    case providerResponseDecodeFailed = "provider_response_decode_failed"
    case providerResponseSchemaValidationFailed = "provider_response_schema_validation_failed"
    case providerTimeout = "provider_timeout"
    case plannerTimeout = "planner_timeout"
    case modelDecisionFailed = "model_decision_failed"
    case ungroundedFinalAnswer = "ungrounded_final_answer"
    case assessmentSemanticInconsistency = "assessment_semantic_inconsistency"
    case toolExecutionFailed = "tool_execution_failed"
}

struct RejectedReadOnlyToolCall: Error, Codable, Hashable, Sendable {
    var toolCallID: String
    var command: String
    var reason: PlanReadinessBlocker
    var detail: String
    var invalidFields: [String] = []
    var allowedArguments: [String] = []
    var stepID: String? = nil
    var stepKind: PlanStepKind? = nil
    var actualFields: [String] = []
    var expectedFields: [String] = []
    var originalStepJSON: String? = nil
    var authorityAudit: ReadOnlyWorkspaceAuthorityAudit? = nil
}

struct ReadOnlyWorkspaceAuthorityAudit: Codable, Hashable, Sendable {
    var modelWorkspaceLabel: String
    var normalizedWorkspaceIdentity: String
    var trustedRoot: String
    var rawModelWorkingDirectory: String
    var modelPath: String
    var normalizedRelativePath: String
    var rejectedValue: String
    var rejectedReason: String
    var symlinkResolutionChangedPath: Bool

    var summary: String {
        let symlinkResolutionChanged = symlinkResolutionChangedPath ? "true" : "false"
        return [
            "model_workspace=\(modelWorkspaceLabel)",
            "normalized_workspace=\(normalizedWorkspaceIdentity)",
            "trusted_root=\(trustedRoot)",
            "model_working_directory=\(rawModelWorkingDirectory)",
            "model_path=\(modelPath)",
            "normalized_path=\(normalizedRelativePath)",
            "rejected_value=\(rejectedValue)",
            "rejected_reason=\(rejectedReason)",
            "symlink_resolution_changed=\(symlinkResolutionChanged)"
        ].joined(separator: ",")
    }
}

struct ReadOnlyPlanStepNormalization: Codable, Hashable, Sendable {
    var stepID: String
    var originalKind: PlanStepKind
    var removedToolCallID: String
    var reason: String
}

struct ReadOnlyExecutableStep: Hashable, Sendable {
    var step: PlanStep
    var toolCall: ToolCall
    var workspaceIdentity: String
    var relativeTargetPath: String
    var modelSuppliedArguments: [String]
    var runtimeDefaultedArguments: [String]
    var authorityAudit: ReadOnlyWorkspaceAuthorityAudit
}

struct PlanReadinessResult: Sendable {
    var isReady: Bool
    var executableStepCount: Int
    var allowedToolCallCount: Int
    var rejectedToolCalls: [RejectedReadOnlyToolCall]
    var blockerReason: PlanReadinessBlocker?
    var repairable: Bool
    var executableSteps: [ReadOnlyExecutableStep]
    var normalizedPlan: [PlanStep]
    var stepNormalizations: [ReadOnlyPlanStepNormalization]

    var auditPayload: [String: String] {
        [
            "is_ready": isReady ? "true" : "false",
            "executable_step_count": String(executableStepCount),
            "allowed_tool_call_count": String(allowedToolCallCount),
            "rejected_tool_calls": rejectedToolCalls.prefix(12).map {
                "\($0.toolCallID):\($0.command):\($0.reason.rawValue)"
            }.joined(separator: " | "),
            "rejected_tool_call_details": rejectedToolCalls.prefix(12).map {
                "\($0.toolCallID): \($0.detail)"
            }.joined(separator: " | "),
            "rejected_fields": rejectedToolCalls.prefix(12).flatMap(\.invalidFields).joined(separator: " | "),
            "rejected_step_ids": rejectedToolCalls.prefix(12).compactMap(\.stepID).joined(separator: " | "),
            "rejected_step_kinds": rejectedToolCalls.prefix(12).compactMap { rejection in
                rejection.stepID.flatMap { _ in rejection.stepKind?.rawValue }
            }.joined(separator: " | "),
            "rejected_step_actual_fields": rejectedToolCalls.prefix(12).flatMap(\.actualFields).joined(separator: " | "),
            "rejected_step_expected_fields": rejectedToolCalls.prefix(12).flatMap(\.expectedFields).joined(separator: " | "),
            "rejected_steps_json": rejectedToolCalls.prefix(12).compactMap(\.originalStepJSON).joined(separator: " | "),
            "normalized_tool_calls": executableSteps.prefix(12).map {
                "\($0.toolCall.id):workspace=\($0.workspaceIdentity),target=\($0.relativeTargetPath)"
            }.joined(separator: " | "),
            "normalized_plan_steps": stepNormalizations.prefix(12).map {
                "\($0.stepID):removed_toolCallID=\($0.removedToolCallID):\($0.reason)"
            }.joined(separator: " | "),
            "runtime_defaulted_arguments": executableSteps.prefix(12).map {
                "\($0.toolCall.id):\($0.runtimeDefaultedArguments.joined(separator: ","))"
            }.joined(separator: " | "),
            "workspace_authority": executableSteps.prefix(12).map {
                "\($0.toolCall.id):\($0.authorityAudit.summary)"
            }.joined(separator: " | "),
            "rejected_workspace_authority": rejectedToolCalls.prefix(12).compactMap { rejection in
                rejection.authorityAudit.map { "\(rejection.toolCallID):\($0.summary)" }
            }.joined(separator: " | "),
            "blocker_reason": blockerReason?.rawValue ?? "",
            "repairable": repairable ? "true" : "false"
        ]
    }
}

struct ReadOnlyPlanReadinessValidator: Sendable {
    private struct NormalizedCall {
        var call: ToolCall
        var workspaceIdentity: String
        var relativeTargetPath: String
        var modelSuppliedArguments: [String]
        var runtimeDefaultedArguments: [String]
        var authorityAudit: ReadOnlyWorkspaceAuthorityAudit
    }

    func validate(
        _ output: StructuredAgentOutput,
        workspace: Workspace,
        missionTarget: ReadOnlyMissionTarget = .legacy
    ) -> PlanReadinessResult {
        var rejected: [RejectedReadOnlyToolCall] = []
        let groupedCalls = Dictionary(grouping: output.toolCalls, by: \.id)
        let duplicateIDs = Set(groupedCalls.filter { $0.value.count > 1 }.map(\.key))
        for id in duplicateIDs.sorted() {
            let call = groupedCalls[id]?.first
            rejected.append(rejection(call, fallbackID: id, reason: .duplicateToolCallID, detail: "Tool-call IDs must be unique."))
        }

        var validatedCalls: [String: NormalizedCall] = [:]
        for call in output.toolCalls where !duplicateIDs.contains(call.id) {
            switch normalizeAndValidate(call, workspace: workspace, missionTarget: missionTarget) {
            case .success(let scoped):
                validatedCalls[call.id] = scoped
            case .failure(let failure):
                rejected.append(failure)
            }
        }

        var executableSteps: [ReadOnlyExecutableStep] = []
        var normalizedPlan: [PlanStep] = []
        var stepNormalizations: [ReadOnlyPlanStepNormalization] = []
        var stepBlocker: PlanReadinessBlocker?
        let executableReferences = Set(
            output.plan.compactMap { step in
                step.kind == .tool ? step.toolCallID : nil
            }
        )
        for step in output.plan {
            var normalizedStep = step
            switch step.kind {
            case .tool:
                guard let callID = step.toolCallID, !callID.isEmpty else {
                    stepBlocker = stepBlocker ?? .noExecutableToolStep
                    rejected.append(
                        RejectedReadOnlyToolCall(
                            toolCallID: step.toolCallID ?? "",
                            command: "",
                            reason: .noExecutableToolStep,
                            detail: "Executable step \(step.id) has no toolCallID.",
                            stepID: step.id,
                            stepKind: step.kind,
                            actualFields: ["kind=\(step.kind.rawValue)", "toolCallID=null"],
                            expectedFields: ["kind=tool", "toolCallID=<existing tool call ID>"],
                            originalStepJSON: stepJSON(step)
                        )
                    )
                    normalizedPlan.append(normalizedStep)
                    continue
                }
                guard groupedCalls[callID]?.count == 1 else {
                    stepBlocker = stepBlocker ?? .invalidToolCallReference
                    if groupedCalls[callID] == nil {
                        rejected.append(
                            RejectedReadOnlyToolCall(
                                toolCallID: callID,
                                command: "",
                                reason: .invalidToolCallReference,
                                detail: "Executable step \(step.id) references a missing tool call.",
                                stepID: step.id,
                                stepKind: step.kind,
                                actualFields: ["kind=\(step.kind.rawValue)", "toolCallID=\(callID)"],
                                expectedFields: ["kind=tool", "toolCallID=<existing tool call ID>"],
                                originalStepJSON: stepJSON(step)
                            )
                        )
                    }
                    normalizedPlan.append(normalizedStep)
                    continue
                }
                guard let scoped = validatedCalls[callID] else {
                    // The reference exists, but call-specific validation already
                    // captured the more precise policy, argument, or scope reason.
                    for index in rejected.indices where rejected[index].toolCallID == callID && rejected[index].stepID == nil {
                        rejected[index].stepID = step.id
                        rejected[index].stepKind = step.kind
                        rejected[index].actualFields = ["kind=\(step.kind.rawValue)", "toolCallID=\(callID)"]
                        rejected[index].expectedFields = ["kind=tool", "toolCallID=<validated read-only tool call ID>"]
                        rejected[index].originalStepJSON = stepJSON(step)
                    }
                    normalizedPlan.append(normalizedStep)
                    continue
                }
                executableSteps.append(
                    ReadOnlyExecutableStep(
                        step: step,
                        toolCall: scoped.call,
                        workspaceIdentity: scoped.workspaceIdentity,
                        relativeTargetPath: scoped.relativeTargetPath,
                        modelSuppliedArguments: scoped.modelSuppliedArguments,
                        runtimeDefaultedArguments: scoped.runtimeDefaultedArguments,
                        authorityAudit: scoped.authorityAudit
                    )
                )
            case .reasoning, .finalization, .clarification, .blocker:
                if let callID = step.toolCallID,
                   (step.kind == .reasoning || step.kind == .finalization),
                   groupedCalls[callID]?.count == 1,
                   validatedCalls[callID] != nil,
                   !executableReferences.contains(callID) {
                    normalizedStep.toolCallID = nil
                    stepNormalizations.append(
                        ReadOnlyPlanStepNormalization(
                            stepID: step.id,
                            originalKind: step.kind,
                            removedToolCallID: callID,
                            reason: "Explicit non-tool kind takes precedence over an orphaned, validated read-only tool reference."
                        )
                    )
                } else if step.toolCallID != nil {
                    stepBlocker = stepBlocker ?? .invalidPlanStep
                    rejected.append(
                        RejectedReadOnlyToolCall(
                            toolCallID: step.toolCallID ?? "",
                            command: "",
                            reason: .invalidPlanStep,
                            detail: "Non-executable step \(step.id) must not reference a tool call.",
                            stepID: step.id,
                            stepKind: step.kind,
                            actualFields: ["kind=\(step.kind.rawValue)", "toolCallID=\(step.toolCallID ?? "null")"],
                            expectedFields: ["kind=\(step.kind.rawValue)", "toolCallID=null"],
                            originalStepJSON: stepJSON(step)
                        )
                    )
                }
                if step.kind == .clarification {
                    stepBlocker = stepBlocker ?? .clarificationRequired
                }
            }
            normalizedPlan.append(normalizedStep)
        }

        let blocker: PlanReadinessBlocker?
        if let stepBlocker {
            blocker = stepBlocker
        } else if executableSteps.isEmpty {
            blocker = rejected.first?.reason ?? .noExecutableToolStep
        } else if let firstRejected = rejected.first {
            blocker = firstRejected.reason
        } else {
            blocker = nil
        }

        return PlanReadinessResult(
            isReady: blocker == nil && !executableSteps.isEmpty,
            executableStepCount: executableSteps.count,
            allowedToolCallCount: validatedCalls.count,
            rejectedToolCalls: rejected,
            blockerReason: blocker,
            repairable: blocker.map(Self.isRepairable) ?? false,
            executableSteps: executableSteps,
            normalizedPlan: normalizedPlan,
            stepNormalizations: stepNormalizations
        )
    }

    private func stepJSON(_ step: PlanStep) -> String {
        (try? JSONCoding.encode(step)) ?? "{\"id\":\"\(step.id)\"}"
    }

    private func normalizeAndValidate(
        _ call: ToolCall,
        workspace: Workspace,
        missionTarget: ReadOnlyMissionTarget
    ) -> Result<NormalizedCall, RejectedReadOnlyToolCall> {
        guard ReadOnlyInspectionPolicy.allowedTools.contains(call.command) else {
            let mutationNames = ["edit", "write", "create", "patch", "command", "run", "delete"]
            let reason: PlanReadinessBlocker = mutationNames.contains { call.command.lowercased().contains($0) }
                ? .mutationProhibited
                : .toolNotAllowed
            return .failure(rejection(call, reason: reason, detail: "Only Phase 2A read-only engineering tools are allowed."))
        }
        guard call.type == .api else {
            return .failure(rejection(call, reason: .toolNotAllowed, detail: "Read-only workspace tools must use API tool type."))
        }
        guard !call.requiresApproval else {
            return .failure(rejection(call, reason: .approvalRequired, detail: "Read-only Phase 2A calls must not have unresolved approval requirements."))
        }
        guard let schema = ReadOnlyToolSchemas.all[call.command] else {
            return .failure(rejection(call, reason: .toolNotAllowed, detail: "No canonical read-only schema exists for this tool."))
        }

        let roots = workspaceRoots(workspace)
        guard !roots.isEmpty else {
            return .failure(rejection(call, reason: .workspaceNotFound, detail: "No selected Legacy or Agent workspace root is available."))
        }
        let parsed: [String: String]
        do {
            parsed = try normalizedArgumentMap(call.arguments)
        } catch let failure as ArgumentNormalizationFailure {
            return .failure(rejection(
                call,
                reason: .invalidArguments,
                detail: failure.detail,
                invalidFields: failure.fields,
                allowedArguments: schema.allowedArguments
            ))
        } catch {
            return .failure(rejection(call, reason: .invalidArguments, detail: "Tool arguments could not be normalized.", allowedArguments: schema.allowedArguments))
        }
        let unsupported = Set(parsed.keys).subtracting(schema.allowedArguments)
        if !unsupported.isEmpty {
            let fields = unsupported.sorted()
            return .failure(rejection(
                call,
                reason: .invalidArguments,
                detail: "\(call.command) does not accept argument(s): \(fields.joined(separator: ", ")).",
                invalidFields: fields,
                allowedArguments: schema.allowedArguments
            ))
        }

        var values = parsed
        var modelSupplied = Array(values.keys).sorted()
        var runtimeDefaulted: [String] = []

        let modelWorkingDirectory = call.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let argumentWorkingDirectory = values.removeValue(forKey: "workingDirectory")
        let rawWorkingDirectory = argumentWorkingDirectory ?? modelWorkingDirectory ?? ""
        let workingDirectoryHint = isNullLike(argumentWorkingDirectory) ? nil : argumentWorkingDirectory
        let hintedIdentity = workingDirectoryHint.flatMap {
            normalizedWorkspaceIdentity($0, workspace: workspace)
        } ?? modelWorkingDirectory.flatMap {
            normalizedWorkspaceIdentity($0, workspace: workspace)
        }
        if let hintedIdentity, values["workspace"] == nil {
            values["workspace"] = hintedIdentity.rawValue
            modelSupplied.removeAll { $0 == "workingDirectory" }
            modelSupplied.append("workspace")
        } else if isNullLike(argumentWorkingDirectory) {
            modelSupplied.removeAll { $0 == "workingDirectory" }
        }

        if values["workspace"] == nil {
            guard let inferred = missionTarget.unambiguousWorkspace else {
                return .failure(rejection(
                    call,
                    reason: .missingRequiredArguments,
                    detail: "\(call.command) is missing workspace; comparison requests must identify legacy or agent for every call.",
                    invalidFields: ["workspace"],
                    allowedArguments: schema.allowedArguments
                ))
            }
            values["workspace"] = inferred.rawValue
            runtimeDefaulted.append("workspace")
        }

        let modelWorkspaceLabel = values["workspace"] ?? ""
        guard let selectedTarget = normalizedWorkspaceIdentity(modelWorkspaceLabel, workspace: workspace) else {
            return .failure(rejection(
                call,
                reason: .invalidArguments,
                detail: "\(call.command) workspace must identify the selected legacy or agent workspace.",
                invalidFields: ["workspace"],
                allowedArguments: schema.allowedArguments
            ))
        }
        values["workspace"] = selectedTarget.rawValue
        if missionTarget != .comparison, missionTarget.rawValue != selectedTarget.rawValue {
            let trustedRoot = trustedRoot(for: missionTarget, roots: roots)?.path ?? ""
            let audit = ReadOnlyWorkspaceAuthorityAudit(
                modelWorkspaceLabel: modelWorkspaceLabel,
                normalizedWorkspaceIdentity: selectedTarget.rawValue,
                trustedRoot: trustedRoot,
                rawModelWorkingDirectory: rawWorkingDirectory,
                modelPath: values["path"] ?? "",
                normalizedRelativePath: "",
                rejectedValue: modelWorkspaceLabel,
                rejectedReason: PlanReadinessBlocker.workspaceScopeMismatch.rawValue,
                symlinkResolutionChangedPath: false
            )
            return .failure(rejection(
                call,
                reason: .workspaceScopeMismatch,
                detail: "\(call.command) targets \(selectedTarget.rawValue), outside this \(missionTarget.rawValue)-only mission.",
                invalidFields: ["workspace"],
                allowedArguments: schema.allowedArguments,
                authorityAudit: audit
            ))
        }
        guard let selectedRoot = roots.first(where: { $0.identity == selectedTarget.rawValue }) else {
            return .failure(rejection(
                call,
                reason: .workspaceNotFound,
                detail: "The selected \(selectedTarget.rawValue) workspace root is unavailable.",
                invalidFields: ["workspace"],
                allowedArguments: schema.allowedArguments
            ))
        }

        let modelPath = values["path"] ?? (schema.runtimeDefaultableArguments.contains("path") ? "." : "")
        if let hint = workingDirectoryHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty,
           hint != ".",
           normalizedWorkspaceIdentity(hint, workspace: workspace) == nil {
            let rawHintURL = URL(fileURLWithPath: hint, isDirectory: true).standardizedFileURL
            let hintedURL = secureCanonicalURL(rawHintURL)
            guard hintedURL.path == selectedRoot.url.path else {
                let reason: PlanReadinessBlocker = roots.contains(where: {
                    $0.identity != selectedRoot.identity && $0.url.path == hintedURL.path
                }) ? .workspaceScopeMismatch : .workingDirectoryOutsideWorkspace
                let audit = ReadOnlyWorkspaceAuthorityAudit(
                    modelWorkspaceLabel: modelWorkspaceLabel,
                    normalizedWorkspaceIdentity: selectedTarget.rawValue,
                    trustedRoot: selectedRoot.url.path,
                    rawModelWorkingDirectory: rawWorkingDirectory,
                    modelPath: modelPath,
                    normalizedRelativePath: "",
                    rejectedValue: hintedURL.path,
                    rejectedReason: reason.rawValue,
                    symlinkResolutionChangedPath: rawHintURL.path != hintedURL.path
                )
                return .failure(rejection(
                    call,
                    reason: reason,
                    detail: "workingDirectory is runtime-injected; use workspace=\(selectedTarget.rawValue) and a relative path.",
                    invalidFields: ["workingDirectory"],
                    allowedArguments: schema.allowedArguments,
                    authorityAudit: audit
                ))
            }
        }
        if let rawWorkingDirectory = modelWorkingDirectory,
           !rawWorkingDirectory.isEmpty,
           rawWorkingDirectory != ".",
           !isNullLike(rawWorkingDirectory),
           normalizedWorkspaceIdentity(rawWorkingDirectory, workspace: workspace) == nil {
            let rawRequestedURL = URL(fileURLWithPath: rawWorkingDirectory, isDirectory: true).standardizedFileURL
            let requestedURL = secureCanonicalURL(rawRequestedURL)
            guard requestedURL.path == selectedRoot.url.path else {
                let reason: PlanReadinessBlocker = roots.contains(where: {
                    $0.identity != selectedRoot.identity && $0.url.path == requestedURL.path
                }) ? .workspaceScopeMismatch : .workingDirectoryOutsideWorkspace
                let audit = ReadOnlyWorkspaceAuthorityAudit(
                    modelWorkspaceLabel: modelWorkspaceLabel,
                    normalizedWorkspaceIdentity: selectedTarget.rawValue,
                    trustedRoot: selectedRoot.url.path,
                    rawModelWorkingDirectory: rawWorkingDirectory,
                    modelPath: modelPath,
                    normalizedRelativePath: "",
                    rejectedValue: requestedURL.path,
                    rejectedReason: reason.rawValue,
                    symlinkResolutionChangedPath: rawRequestedURL.path != requestedURL.path
                )
                return .failure(rejection(
                    call,
                    reason: reason,
                    detail: "workingDirectory is runtime-injected; do not provide an external or nested absolute directory.",
                    invalidFields: ["workingDirectory"],
                    allowedArguments: schema.allowedArguments,
                    authorityAudit: audit
                ))
            }
            modelSupplied.append("workingDirectory")
        } else {
            runtimeDefaulted.append("workingDirectory")
        }

        for required in schema.requiredModelArguments {
            guard let value = values[required], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(rejection(
                    call,
                    reason: .missingRequiredArguments,
                    detail: "\(call.command) is missing required argument \(required).",
                    invalidFields: [required],
                    allowedArguments: schema.allowedArguments
                ))
            }
        }
        if values["path"] == nil, schema.runtimeDefaultableArguments.contains("path") {
            values["path"] = "."
            runtimeDefaulted.append("path")
        }

        let canonicalWorkingDirectory = selectedRoot.url

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalWorkingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(rejection(call, reason: .workspaceNotFound, detail: "Selected workspace directory does not exist."))
        }
        guard FileManager.default.isReadableFile(atPath: canonicalWorkingDirectory.path) else {
            return .failure(rejection(call, reason: .workspaceUnreadable, detail: "Selected workspace directory is not readable."))
        }

        let targetValue = values["path"] ?? "."
        let targetURL = targetValue.hasPrefix("/")
            ? URL(fileURLWithPath: targetValue)
            : canonicalWorkingDirectory.appendingPathComponent(targetValue)
        let canonicalTarget = secureCanonicalURL(targetURL)
        guard isInside(canonicalTarget, root: selectedRoot.url) else {
            let rawTarget = targetURL.standardizedFileURL
            let audit = ReadOnlyWorkspaceAuthorityAudit(
                modelWorkspaceLabel: modelWorkspaceLabel,
                normalizedWorkspaceIdentity: selectedTarget.rawValue,
                trustedRoot: selectedRoot.url.path,
                rawModelWorkingDirectory: rawWorkingDirectory,
                modelPath: targetValue,
                normalizedRelativePath: "",
                rejectedValue: canonicalTarget.path,
                rejectedReason: PlanReadinessBlocker.pathOutsideWorkspace.rawValue,
                symlinkResolutionChangedPath: rawTarget.path != canonicalTarget.path
            )
            return .failure(rejection(
                call,
                reason: .pathOutsideWorkspace,
                detail: "Tool path escapes its selected workspace root.",
                invalidFields: ["path"],
                allowedArguments: schema.allowedArguments,
                authorityAudit: audit
            ))
        }

        let relative = relativePath(canonicalTarget, root: selectedRoot.url)
        if call.command == "engineering.read_file", ReadOnlySensitivePathPolicy.isSensitive(relative) {
            return .failure(rejection(
                call,
                reason: .sensitiveFileExcluded,
                detail: "Sensitive credential and environment files are excluded from read-only inspection.",
                invalidFields: ["path"],
                allowedArguments: schema.allowedArguments
            ))
        }
        var canonicalArguments = ["workspace=\(selectedTarget.rawValue)"]
        if values["path"] != nil { canonicalArguments.append("path=\(relative)") }
        if let query = values["query"] { canonicalArguments.append("query=\(query)") }
        if let extensions = values["extensions"] { canonicalArguments.append("extensions=\(extensions)") }
        var scopedCall = call
        scopedCall.arguments = canonicalArguments
        scopedCall.workingDirectory = canonicalWorkingDirectory.path
        let authorityAudit = ReadOnlyWorkspaceAuthorityAudit(
            modelWorkspaceLabel: modelWorkspaceLabel,
            normalizedWorkspaceIdentity: selectedTarget.rawValue,
            trustedRoot: selectedRoot.url.path,
            rawModelWorkingDirectory: rawWorkingDirectory,
            modelPath: targetValue,
            normalizedRelativePath: relative,
            rejectedValue: "",
            rejectedReason: "",
            symlinkResolutionChangedPath: targetURL.standardizedFileURL.path != canonicalTarget.path
        )
        return .success(NormalizedCall(
            call: scopedCall,
            workspaceIdentity: selectedRoot.identity,
            relativeTargetPath: relative,
            modelSuppliedArguments: Array(Set(modelSupplied)).sorted(),
            runtimeDefaultedArguments: Array(Set(runtimeDefaulted)).sorted(),
            authorityAudit: authorityAudit
        ))
    }

    private struct ArgumentNormalizationFailure: Error {
        var detail: String
        var fields: [String]
    }

    private func normalizedArgumentMap(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for raw in arguments {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.first == "{", let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try mergeJSONObject(object, into: &result)
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw ArgumentNormalizationFailure(
                    detail: "Unkeyed argument '\(String(trimmed.prefix(80)))' is invalid; use key=value entries.",
                    fields: ["arguments"]
                )
            }
            try insert(key: parts[0], value: parts[1], into: &result)
        }
        return result
    }

    private func mergeJSONObject(_ object: [String: Any], into result: inout [String: String]) throws {
        for (key, value) in object {
            if key == "arguments", let nested = value as? [String: Any] {
                try mergeJSONObject(nested, into: &result)
            } else if let string = value as? String {
                try insert(key: key, value: string, into: &result)
            } else {
                throw ArgumentNormalizationFailure(detail: "Argument \(key) must be a string.", fields: [key])
            }
        }
    }

    private func insert(key: String, value: String, into result: inout [String: String]) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = [
            "workspace": "workspace", "target": "workspace", "codebase": "workspace",
            "path": "path", "relative_path": "path", "directory": "path", "dir": "path", "file": "path",
            "query": "query", "q": "query", "pattern": "query", "search_term": "query",
            "extensions": "extensions", "ext": "extensions", "file_extensions": "extensions",
            "workingdirectory": "workingDirectory", "working_directory": "workingDirectory"
        ]
        guard let canonical = aliases[trimmedKey.lowercased()] else {
            throw ArgumentNormalizationFailure(detail: "Unknown tool argument \(trimmedKey).", fields: [trimmedKey])
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = result[canonical], existing != trimmedValue {
            throw ArgumentNormalizationFailure(detail: "Conflicting values were supplied for \(canonical).", fields: [canonical])
        }
        result[canonical] = trimmedValue
    }

    private func isNullLike(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["null", "nil", "<null>"].contains(
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private func normalizedWorkspaceIdentity(
        _ value: String,
        workspace: Workspace
    ) -> ReadOnlyWorkspaceTarget? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let legacyAliases: Set<String> = [
            "legacy", "legacyonly", "legacy_only", "current_legacy", "selected_legacy"
        ]
        let agentAliases: Set<String> = [
            "agent", "agentonly", "agent_only", "current_agent", "selected_agent"
        ]
        if legacyAliases.contains(normalized) {
            return .legacy
        }
        if agentAliases.contains(normalized) {
            return .agent
        }

        let selectedLegacyNames = [
            workspace.name,
            workspace.displayName
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if selectedLegacyNames.contains(normalized) {
            return .legacy
        }
        return nil
    }

    private func trustedRoot(
        for target: ReadOnlyMissionTarget,
        roots: [(identity: String, url: URL)]
    ) -> URL? {
        guard let identity = target.unambiguousWorkspace?.rawValue else { return nil }
        return roots.first(where: { $0.identity == identity })?.url
    }

    private func workspaceRoots(_ workspace: Workspace) -> [(identity: String, url: URL)] {
        var roots: [(String, URL)] = []
        if let root = workspace.localProjectRootURL {
            roots.append(("legacy", secureCanonicalURL(root)))
        }
        if let root = workspace.localAgentProjectRootURL {
            roots.append(("agent", secureCanonicalURL(root)))
        }
        return roots
    }

    private func secureCanonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
    }

    private func isInside(_ url: URL, root: URL) -> Bool {
        let canonicalRoot = secureCanonicalURL(root)
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : "\(canonicalRoot.path)/"
        return url.path == canonicalRoot.path || url.path.hasPrefix(rootPrefix)
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        guard url.path != root.path else { return "." }
        let prefix = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : "."
    }

    private func rejection(
        _ call: ToolCall?,
        fallbackID: String = "",
        reason: PlanReadinessBlocker,
        detail: String,
        invalidFields: [String] = [],
        allowedArguments: [String] = [],
        authorityAudit: ReadOnlyWorkspaceAuthorityAudit? = nil
    ) -> RejectedReadOnlyToolCall {
        RejectedReadOnlyToolCall(
            toolCallID: call?.id ?? fallbackID,
            command: call?.command ?? "",
            reason: reason,
            detail: detail,
            invalidFields: invalidFields,
            allowedArguments: allowedArguments,
            authorityAudit: authorityAudit
        )
    }

    private static func isRepairable(_ reason: PlanReadinessBlocker) -> Bool {
        switch reason {
        case .noExecutableToolStep, .invalidToolCallReference, .duplicateToolCallID, .toolNotAllowed,
             .mutationProhibited, .missingRequiredArguments, .invalidArguments, .approvalRequired,
             .workingDirectoryOutsideWorkspace, .pathOutsideWorkspace, .workspaceTargetMismatch,
             .workspaceScopeMismatch, .invalidPlanStep, .commandAlreadyCompleted,
             .commandPreviouslyFailed, .explicitNoRereadConstraint, .canonicalSearchPathRequired:
            return true
        default:
            return false
        }
    }
}

struct ReadOnlyInspectionLimits: Hashable, Sendable {
    var maximumModelDecisionIterations = 10
    var maximumToolCalls = 12
    var maximumFilesRead = 8
    var maximumObservationCharacters = 6_000
    var simpleBudget = ReadOnlyMissionBudget(
        kind: .simpleFileInspection,
        softLimit: 30,
        hardLimit: 45,
        providerCallReserve: 8,
        finalizationReserve: 15
    )
    var projectBudget = ReadOnlyMissionBudget(
        kind: .projectInspection,
        softLimit: 70,
        hardLimit: 90,
        providerCallReserve: 10,
        finalizationReserve: 20
    )
    var broadAssessmentBudget = ReadOnlyMissionBudget(
        kind: .broadStaticAssessment,
        softLimit: 110,
        hardLimit: 140,
        providerCallReserve: 15,
        finalizationReserve: 30
    )
    var budgetOverride: ReadOnlyMissionBudget?

    static let conservative = ReadOnlyInspectionLimits()

    func budget(for request: String, workspaceScope: MissionWorkspaceScope) -> ReadOnlyMissionBudget {
        if let budgetOverride {
            return budgetOverride.validated()
        }

        let normalized = request.lowercased()
        let intent = MissionIntentParser().parse(request)
        if intent.intentType == .aiAgentCompatibilityAssessment,
           AgentCapabilityProfile.detect(from: request).kind == .customerSupportOrderLookup {
            return broadAssessmentBudget.validated()
        }
        let broadTerms = [
            "architecture", "risk assessment", "security", "performance", "database", "dependency", "dependencies",
            "架构", "风险", "安全", "性能", "数据库", "依赖", "全面", "广泛"
        ]
        let projectTerms = [
            "project", "workspace", "structure", "framework", "manifest", "package", "backend", "frontend",
            "项目", "工作区", "结构", "框架", "清单", "后端", "前端"
        ]
        let looksLikeDirectFileRequest = [
            ".swift", ".ts", ".tsx", ".js", ".jsx", ".py", ".java", ".kt", ".go", ".rs", ".json", ".toml"
        ].contains { normalized.contains($0) }

        if workspaceScope == .legacyAndAgentComparison
            || broadTerms.filter({ normalized.contains($0) }).count >= 2
            || projectTerms.filter({ normalized.contains($0) }).count >= 3 {
            return broadAssessmentBudget.validated()
        }
        if !looksLikeDirectFileRequest || projectTerms.contains(where: { normalized.contains($0) }) {
            return projectBudget.validated()
        }
        return simpleBudget.validated()
    }

    func operationBudget(for kind: ReadOnlyMissionBudgetKind) -> ReadOnlyOperationBudget {
        let adaptive: ReadOnlyOperationBudget
        switch kind {
        case .simpleFileInspection:
            adaptive = ReadOnlyOperationBudget(
                maximumModelDecisionIterations: 3,
                maximumToolCalls: 4,
                maximumFilesRead: 3
            )
        case .projectInspection:
            adaptive = ReadOnlyOperationBudget(
                maximumModelDecisionIterations: 6,
                maximumToolCalls: 8,
                maximumFilesRead: 5
            )
        case .broadStaticAssessment:
            adaptive = ReadOnlyOperationBudget(
                maximumModelDecisionIterations: 10,
                maximumToolCalls: 12,
                maximumFilesRead: 8
            )
        }
        return ReadOnlyOperationBudget(
            maximumModelDecisionIterations: min(
                max(1, maximumModelDecisionIterations),
                adaptive.maximumModelDecisionIterations
            ),
            maximumToolCalls: min(max(1, maximumToolCalls), adaptive.maximumToolCalls),
            maximumFilesRead: min(max(1, maximumFilesRead), adaptive.maximumFilesRead)
        )
    }
}

struct ReadOnlyOperationBudget: Hashable, Sendable {
    var maximumModelDecisionIterations: Int
    var maximumToolCalls: Int
    var maximumFilesRead: Int

    var auditPayload: [String: String] {
        [
            "selected_iteration_budget": String(maximumModelDecisionIterations),
            "selected_tool_call_budget": String(maximumToolCalls),
            "selected_file_read_budget": String(maximumFilesRead),
            "finalization_uses_observation_iteration": "false"
        ]
    }
}

enum ReadOnlyMissionBudgetKind: String, Codable, Hashable, Sendable {
    case simpleFileInspection = "SIMPLE_FILE_INSPECTION"
    case projectInspection = "PROJECT_INSPECTION"
    case broadStaticAssessment = "BROAD_STATIC_ASSESSMENT"
}

struct ReadOnlyMissionBudget: Hashable, Sendable {
    var kind: ReadOnlyMissionBudgetKind
    var softLimit: TimeInterval
    var hardLimit: TimeInterval
    var providerCallReserve: TimeInterval
    var finalizationReserve: TimeInterval

    func validated() -> ReadOnlyMissionBudget {
        let hard = max(0.05, hardLimit)
        let finalReserve = min(max(0.01, finalizationReserve), hard * 0.8)
        let soft = min(max(0.01, softLimit), hard - finalReserve)
        return ReadOnlyMissionBudget(
            kind: kind,
            softLimit: soft,
            hardLimit: hard,
            providerCallReserve: min(max(0.01, providerCallReserve), soft),
            finalizationReserve: finalReserve
        )
    }

    var auditPayload: [String: String] {
        [
            "mission_budget_kind": kind.rawValue,
            "soft_limit_ms": String(Int(softLimit * 1_000)),
            "hard_limit_ms": String(Int(hardLimit * 1_000)),
            "provider_call_reserve_ms": String(Int(providerCallReserve * 1_000)),
            "finalization_reserve_ms": String(Int(finalizationReserve * 1_000))
        ]
    }
}

struct ReadOnlyMissionTiming: Sendable {
    let startedAt: Date
    let budget: ReadOnlyMissionBudget
    let operationBudget: ReadOnlyOperationBudget
    var contextCompilation: TimeInterval = 0
    var planning: TimeInterval = 0
    var readinessAndRepair: TimeInterval = 0
    var observationProvider: TimeInterval = 0
    var toolExecution: TimeInterval = 0
    var finalization: TimeInterval = 0

    init(
        startedAt: Date,
        budget: ReadOnlyMissionBudget,
        operationBudget: ReadOnlyOperationBudget = ReadOnlyOperationBudget(
            maximumModelDecisionIterations: 8,
            maximumToolCalls: 12,
            maximumFilesRead: 8
        )
    ) {
        self.startedAt = startedAt
        self.budget = budget
        self.operationBudget = operationBudget
    }

    var softDeadline: Date { startedAt.addingTimeInterval(budget.softLimit) }
    var hardDeadline: Date { startedAt.addingTimeInterval(budget.hardLimit) }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    func remainingSoft(at now: Date = Date()) -> TimeInterval {
        max(0, softDeadline.timeIntervalSince(now))
    }

    func remainingHard(at now: Date = Date()) -> TimeInterval {
        max(0, hardDeadline.timeIntervalSince(now))
    }

    func shouldFinalizeBeforeAnotherIteration(at now: Date = Date()) -> Bool {
        remainingSoft(at: now) <= budget.providerCallReserve
            || remainingHard(at: now) <= budget.providerCallReserve + budget.finalizationReserve
    }

    func durationFinalizationTrigger(at now: Date = Date()) -> ReadOnlyFinalizationTrigger? {
        if remainingHard(at: now) <= 0 {
            return .hardDurationReached
        }
        if remainingHard(at: now) <= budget.finalizationReserve {
            return .hardDurationReserve
        }
        if remainingSoft(at: now) <= budget.providerCallReserve {
            return .softDurationReserve
        }
        if remainingHard(at: now) <= budget.providerCallReserve + budget.finalizationReserve {
            return .providerAndFinalizationReserve
        }
        return nil
    }

    func auditPayload(at now: Date = Date()) -> [String: String] {
        budget.auditPayload.merging(operationBudget.auditPayload) { current, _ in current }.merging([
            "elapsed_ms": Self.milliseconds(elapsed(at: now)),
            "context_compilation_ms": Self.milliseconds(contextCompilation),
            "planning_ms": Self.milliseconds(planning),
            "readiness_repair_ms": Self.milliseconds(readinessAndRepair),
            "observation_provider_ms": Self.milliseconds(observationProvider),
            "tool_execution_ms": Self.milliseconds(toolExecution),
            "finalization_ms": Self.milliseconds(finalization),
            "remaining_soft_ms": Self.milliseconds(remainingSoft(at: now)),
            "remaining_ms": Self.milliseconds(remainingHard(at: now))
        ]) { current, _ in current }
    }

    private static func milliseconds(_ value: TimeInterval) -> String {
        String(max(0, Int((value * 1_000).rounded())))
    }
}

enum ReadOnlyBudgetStopDecision: String, Codable, Hashable, Sendable {
    case completeWithCurrentEvidence = "complete_with_current_evidence"
    case partialWithCurrentEvidence = "partial_with_current_evidence"
    case hardCancel = "hard_cancel"
}

enum ReadOnlyToolFailureClassification: String, Codable, Hashable, Sendable {
    case recoverableCandidateFailure = "recoverable_candidate_failure"
    case permissionSecurityFailure = "permission_security_failure"
    case workspaceScopeViolation = "workspace_scope_violation"
    case missingPath = "missing_path"
    case malformedAction = "malformed_action"
    case hardRuntimeFailure = "hard_runtime_failure"

    var isRecoverableCandidateFailure: Bool {
        self == .recoverableCandidateFailure || self == .missingPath
    }
}

enum ReadOnlyFinalizationTrigger: String, Codable, Hashable, Sendable {
    case evidenceSatisfied = "evidence_requirements_satisfied"
    case restoredEvidence = "restored_evidence_ready"
    case softDurationReserve = "soft_duration_reserve"
    case hardDurationReserve = "hard_duration_reserve"
    case hardDurationReached = "hard_duration_reached"
    case providerAndFinalizationReserve = "provider_and_finalization_reserve"
    case iterationReserve = "iteration_reserve"
    case toolCallLimit = "tool_call_limit"
    case fileReadLimit = "file_read_limit"

    var blockerReason: PlanReadinessBlocker {
        switch self {
        case .iterationReserve:
            return .iterationLimitReached
        case .toolCallLimit:
            return .toolCallLimitReached
        case .fileReadLimit:
            return .fileReadLimitReached
        case .hardDurationReached, .hardDurationReserve, .providerAndFinalizationReserve:
            return .durationLimitReached
        case .softDurationReserve:
            return .softDeadlineReached
        case .evidenceSatisfied, .restoredEvidence:
            return .insufficientEvidenceToFinalize
        }
    }
}

struct ReadOnlyBudgetStopResolution: Hashable, Sendable {
    var decision: ReadOnlyBudgetStopDecision
    var trigger: ReadOnlyFinalizationTrigger

    var auditPayload: [String: String] {
        [
            "budget_stop_decision": decision.rawValue,
            "budget_stop_trigger": trigger.rawValue,
            "budget_stop_reason": trigger.blockerReason.rawValue
        ]
    }
}

enum ReadOnlyEvidenceRequirementKind: String, Codable, Hashable, Sendable {
    case requestedFile = "requested_file"
    case projectRoot = "project_root_inspection"
    case projectStructure = "project_structure"
    case staticSourceEvidence = "static_source_evidence"
    case primaryLanguages = "primary_languages"
    case projectManifest = "project_manifest"
    case frontendManifestOrConfig = "frontend_manifest_or_config"
    case frontendConfiguration = "frontend_configuration"
    case backendManifest = "backend_manifest"
    case databaseSchemaOrConfig = "database_schema_or_config"
    case backendEntryPoint = "backend_startup_entry"
    case backendApplicationAssembly = "backend_application_assembly"
    case importantDependencies = "important_dependencies"
    case inspectedManifestsAndKeyFiles = "inspected_manifests_and_key_files"
    case assessmentOrderReadBoundary = "assessment_order_read_boundary"
    case assessmentAPIServiceBoundary = "assessment_api_service_boundary"
    case assessmentAuthentication = "assessment_authentication"
    case assessmentRecordAuthorization = "assessment_record_authorization"
    case assessmentPermissionModel = "assessment_permission_model"
    case assessmentAuditLogging = "assessment_audit_logging"
    case assessmentMutationPaths = "assessment_mutation_paths"
    case assessmentSensitiveResponseFields = "assessment_sensitive_response_fields"
    case assessmentArchitectureDocumentation = "assessment_architecture_documentation"
    case assessmentExampleConfiguration = "assessment_example_configuration"

    var label: String {
        switch self {
        case .requestedFile: return "requested file"
        case .projectRoot: return "project root inspection"
        case .projectStructure: return "project structure"
        case .staticSourceEvidence: return "static source evidence"
        case .primaryLanguages: return "primary languages"
        case .projectManifest: return "project manifest"
        case .frontendManifestOrConfig: return "frontend framework"
        case .frontendConfiguration: return "frontend configuration"
        case .backendManifest: return "backend framework"
        case .databaseSchemaOrConfig: return "database"
        case .backendEntryPoint: return "backend startup entry"
        case .backendApplicationAssembly: return "backend application assembly"
        case .importantDependencies: return "important dependencies"
        case .inspectedManifestsAndKeyFiles: return "inspected manifests and key files"
        case .assessmentOrderReadBoundary: return "order read/data boundary"
        case .assessmentAPIServiceBoundary: return "API/service boundary"
        case .assessmentAuthentication: return "authentication boundary"
        case .assessmentRecordAuthorization: return "record-level authorization"
        case .assessmentPermissionModel: return "permission model"
        case .assessmentAuditLogging: return "audit logging"
        case .assessmentMutationPaths: return "mutation paths and read-only boundary"
        case .assessmentSensitiveResponseFields: return "sensitive response fields"
        case .assessmentArchitectureDocumentation: return "relevant architecture documentation"
        case .assessmentExampleConfiguration: return "relevant example configuration"
        }
    }

    static var backendStartupEntry: Self { .backendEntryPoint }
}

struct ReadOnlyEvidenceRequirements: Hashable, Sendable {
    var required: [ReadOnlyEvidenceRequirementKind]

    init(request: String) {
        // Recovery prompts append an internal evidence ledger after this marker.
        // Requirement extraction must inspect the user's request and clarification,
        // not paths or labels echoed inside that runtime-owned audit context.
        let requestText = request.components(separatedBy: "\n\nSame-task continuation state:").first ?? request
        let normalized = requestText.lowercased()
        let fileExtensions = [".swift", ".ts", ".tsx", ".js", ".jsx", ".py", ".java", ".kt", ".go", ".rs"]
        let staticTerms = ["performance", "security", "risk", "性能", "安全", "风险"]
        let asksBackendStartup = [
            "backend entry", "entry point", "startup entry", "startup file",
            "后端入口", "启动入口", "启动文件"
        ].contains(where: { normalized.contains($0) })
        let asksBackendAssembly = [
            "application assembly", "application composition", "app assembly", "app.ts",
            "应用组装", "应用装配", "组装文件"
        ].contains(where: { normalized.contains($0) })
        let isAIAgentAssessment = MissionIntentParser().parse(requestText).intentType == .aiAgentCompatibilityAssessment
        var values: [ReadOnlyEvidenceRequirementKind]
        if isAIAgentAssessment {
            values = [.projectRoot, .projectStructure, .staticSourceEvidence, .inspectedManifestsAndKeyFiles]
            if AgentCapabilityProfile.detect(from: requestText).kind == .customerSupportOrderLookup {
                values += [
                    .assessmentOrderReadBoundary,
                    .assessmentAPIServiceBoundary,
                    .assessmentAuthentication,
                    .assessmentRecordAuthorization,
                    .assessmentPermissionModel,
                    .assessmentAuditLogging,
                    .assessmentMutationPaths,
                    .assessmentSensitiveResponseFields,
                    .assessmentArchitectureDocumentation,
                    .assessmentExampleConfiguration
                ]
            }
        } else if fileExtensions.contains(where: { normalized.contains($0) }) {
            values = [.requestedFile]
        } else if staticTerms.contains(where: { normalized.contains($0) }) {
            values = [.staticSourceEvidence]
        } else {
            values = [.projectRoot]
        }

        if ["project structure", "workspace structure", "项目结构", "目录结构"].contains(where: { normalized.contains($0) }) {
            values.append(.projectStructure)
        }
        if ["primary language", "main language", "languages", "主要语言", "编程语言"].contains(where: { normalized.contains($0) }) {
            values.append(.primaryLanguages)
        }

        if ["manifest", "dependency", "dependencies", "framework", "package", "清单", "依赖", "框架"].contains(where: { normalized.contains($0) }) {
            values.append(.projectManifest)
        }
        if ["frontend", "front-end", "前端"].contains(where: { normalized.contains($0) }) {
            values.append(.frontendManifestOrConfig)
            if ["config", "configuration", "配置", "vite.config", "webpack", "next.config"].contains(where: { normalized.contains($0) }) {
                values.append(.frontendConfiguration)
            }
        }
        if ["backend", "back-end", "server", "后端", "服务端"].contains(where: { normalized.contains($0) }) {
            let explicitlyAsksManifestOrFramework = [
                "backend framework", "back-end framework", "server framework", "backend manifest",
                "backend dependency", "backend dependencies", "后端框架", "服务端框架",
                "后端 manifest", "后端依赖", "服务端依赖"
            ].contains(where: { normalized.contains($0) })
            if explicitlyAsksManifestOrFramework || (!asksBackendStartup && !asksBackendAssembly) {
                values.append(.backendManifest)
            }
        }
        if asksBackendAssembly {
            values.append(.backendApplicationAssembly)
        }
        if asksBackendStartup {
            values.append(.backendEntryPoint)
        }
        if ["database", "schema", "prisma", "数据库", "数据模型"].contains(where: { normalized.contains($0) }) {
            values.append(.databaseSchemaOrConfig)
        }
        if ["dependency", "dependencies", "important dependencies", "依赖", "重要依赖"].contains(where: { normalized.contains($0) }) {
            values.append(.importantDependencies)
        }
        if [
            "files/manifests read", "manifests and key files", "manifest and key files",
            "actually read", "actual inspected", "实际读取", "实际检查", "manifest 和关键文件",
            "清单和关键文件", "列出实际读取"
        ].contains(where: { normalized.contains($0) }) {
            values.append(.inspectedManifestsAndKeyFiles)
        }
        required = Self.unique(values)
    }

    func satisfied(by evidence: [ReadOnlyInspectionEvidence]) -> [ReadOnlyEvidenceRequirementKind] {
        ReadOnlyFinalizationEvidenceLedger(requirements: self, evidence: evidence).satisfied
    }

    func unsatisfied(by evidence: [ReadOnlyInspectionEvidence]) -> [ReadOnlyEvidenceRequirementKind] {
        ReadOnlyFinalizationEvidenceLedger(requirements: self, evidence: evidence).unsatisfied
    }

    func auditPayload(evidence: [ReadOnlyInspectionEvidence]) -> [String: String] {
        ReadOnlyFinalizationEvidenceLedger(requirements: self, evidence: evidence).auditPayload
    }

    func hasUnsatisfiedFileRequirement(evidence: [ReadOnlyInspectionEvidence]) -> Bool {
        unsatisfied(by: evidence).contains { requirement in
            switch requirement {
            case .projectRoot, .staticSourceEvidence:
                return false
            case .requestedFile, .projectStructure, .primaryLanguages, .projectManifest,
                 .frontendManifestOrConfig, .frontendConfiguration, .backendManifest,
                 .databaseSchemaOrConfig, .backendEntryPoint, .backendApplicationAssembly, .importantDependencies,
                 .inspectedManifestsAndKeyFiles, .assessmentOrderReadBoundary,
                 .assessmentAPIServiceBoundary, .assessmentAuthentication,
                 .assessmentRecordAuthorization, .assessmentPermissionModel,
                 .assessmentAuditLogging, .assessmentMutationPaths,
                 .assessmentSensitiveResponseFields, .assessmentArchitectureDocumentation,
                 .assessmentExampleConfiguration:
                return true
            }
        }
    }

    var supportsEvidenceDrivenEarlyFinalization: Bool {
        required.contains(.requestedFile)
            || required.contains(.staticSourceEvidence)
            || required.contains(.frontendManifestOrConfig)
            || required.contains(.backendManifest)
            || required.contains(.backendEntryPoint)
            || required.contains(.backendApplicationAssembly)
            || required.contains(.databaseSchemaOrConfig)
    }

    private static func unique(_ values: [ReadOnlyEvidenceRequirementKind]) -> [ReadOnlyEvidenceRequirementKind] {
        var seen: Set<ReadOnlyEvidenceRequirementKind> = []
        return values.filter { seen.insert($0).inserted }
    }
}

struct ReadOnlyInspectionEvidence: Hashable, Sendable {
    var toolCallID: String
    var toolName: String
    var workspaceID: UUID
    var workspaceIdentity: String
    var targetPath: String
    var output: String
    var toolCalledEventID: UUID
    var toolResultEventID: UUID
    var extractedFacts: ReadOnlyExtractedFacts? = nil
    var query: String? = nil

    var structuredFacts: ReadOnlyExtractedFacts {
        extractedFacts ?? ReadOnlySafeFactExtractor.extract(
            toolName: toolName,
            targetPath: targetPath,
            output: output
        )
    }

    var evidenceLabel: String {
        targetPath == "." ? "\(workspaceIdentity) workspace" : targetPath
    }
}

struct ReadOnlyInspectionObservation: Sendable {
    var missionGoal: String
    var trustedWorkspaceScope: String
    var toolName: String
    var workspaceIdentity: String
    var targetPath: String
    var success: Bool
    var boundedOutput: String
    var accumulatedEvidence: [String]
    var structuredFacts: [String]
    var inspectedFiles: [String]
    var responseLanguage: ReadOnlyResponseLanguage
    var remainingDecisionIterations: Int
    var remainingToolCalls: Int
    var remainingFileReads: Int
    var elapsedMilliseconds: Int
    var remainingDurationMilliseconds: Int
    var estimatedNextProviderCallMilliseconds: Int
    var finalizationReserveMilliseconds: Int
    var finalizationRequired: Bool
    var satisfiedEvidenceRequirements: [String]
    var unsatisfiedEvidenceRequirements: [String]
    var canonicalUnreadPaths: [String] = []
    var highestValueCandidateCategories: [String] = []
    var unavailableReadPaths: [String] = []
    var completedCommandSignatures: [String] = []
    var failedCommandSignatures: [String] = []

    func prompt() -> String {
        let isAIAssessment = MissionIntentParser().parse(missionGoal).intentType == .aiAgentCompatibilityAssessment
        let aiAssessmentContract = isAIAssessment ? """

        AI Agent integration assessment contract:
        - This is assessment-only. Never request mutation, deployment, production access, credentials, or direct agent database access.
        - Identify and preserve the explicit normalized AgentCapabilityProfile. A customer-support order-query request is `customer_support_order_lookup` with display label `Customer Support AI Agent — Read-only Order Lookup`; never downgrade an explicit capability to Unspecified AI Agent.
        - Gather static evidence for API/service boundaries, authentication, permissions, relevant data or knowledge, events, approvals, and audit logging when applicable.
        - For `customer_support_order_lookup`, investigate the order read/data boundary, API/service boundary, authentication, record-level authorization, permission model, audit logging, mutation paths, sensitive response fields, relevant architecture documentation, and relevant example configuration. Discover candidates from the selected workspace and inspect their exact canonical relative paths; never assume fixture-specific paths in production.
        - UNKNOWN is valid only after a relevant bounded read/search was recorded, no matching evidence exists after bounded search, or the inspection budget is exhausted and the remaining requirement is named explicitly.
        - SUPPORTED requires a successfully read file or extracted configuration. BLOCKED requires evidence of an architectural conflict or a bounded zero-result static search. Otherwise use UNKNOWN.
        - The final answer must be an "FDE AI Integration Assessment Report" with exactly these sections: 1. Executive Summary; 2. Legacy System Understanding; 3. Requested AI Capability; 4. Compatibility Matrix; 5. Integration Opportunities; 6. Security Assessment; 7. Integration Blockers; 8. Recommended Architecture; 9. Validation Test Plan; 10. Unknowns and Next Investigation Steps.
        - Begin the Executive Summary with YES, PARTIAL, or NO. Every conclusion must cite evidence, confidence, and unknowns. Generate validation tests only; do not execute them.
        """ : ""
        return """
        Current mission goal: \(missionGoal)
        Trusted workspace scope: \(trustedWorkspaceScope)

        Latest successful read-only tool:
        - tool_name: \(toolName)
        - selected_workspace: \(workspaceIdentity)
        - target_path: \(targetPath)
        - success: \(success)
        - compact_result:
        \(boundedOutput)

        Accumulated successful evidence:
        \(accumulatedEvidence.isEmpty ? "- none" : accumulatedEvidence.map { "- \($0)" }.joined(separator: "\n"))

        Canonical structured safe facts (use these for finalization instead of rereading unrestricted raw source):
        \(structuredFacts.isEmpty ? "- none" : structuredFacts.map { "- \($0)" }.joined(separator: "\n"))

        Files already inspected with engineering.read_file:
        \(inspectedFiles.isEmpty ? "- none" : inspectedFiles.map { "- \($0)" }.joined(separator: "\n"))

        Canonical discovered-but-unread relative paths (a subsequent read_file must use one exactly; never shorten or guess it):
        \(canonicalUnreadPaths.isEmpty ? "- none" : canonicalUnreadPaths.map { "- \($0)" }.joined(separator: "\n"))

        Highest-value candidate categories, ordered by the remaining request:
        \(highestValueCandidateCategories.isEmpty ? "- no material file category remains" : highestValueCandidateCategories.map { "- \($0)" }.joined(separator: "\n"))

        Unavailable read paths (do not retry or change their extension speculatively):
        \(unavailableReadPaths.isEmpty ? "- none" : unavailableReadPaths.map { "- \($0)" }.joined(separator: "\n"))

        Unavailable command signatures:
        - completed: \(completedCommandSignatures.isEmpty ? "none" : completedCommandSignatures.joined(separator: " | "))
        - failed: \(failedCommandSignatures.isEmpty ? "none" : failedCommandSignatures.joined(separator: " | "))

        Remaining bounds:
        - remaining_model_decisions: \(remainingDecisionIterations)
        - remaining_tool_calls: \(remainingToolCalls)
        - remaining_file_reads: \(remainingFileReads)
        - elapsed_ms: \(elapsedMilliseconds)
        - remaining_duration_ms: \(remainingDurationMilliseconds)
        - estimated_next_provider_call_ms: \(estimatedNextProviderCallMilliseconds)
        - finalization_reserve_ms: \(finalizationReserveMilliseconds)
        - finalization_required: \(finalizationRequired)

        Evidence requirements:
        - satisfied: \(satisfiedEvidenceRequirements.isEmpty ? "none" : satisfiedEvidenceRequirements.joined(separator: " | "))
        - unsatisfied: \(unsatisfiedEvidenceRequirements.isEmpty ? "none" : unsatisfiedEvidenceRequirements.joined(separator: " | "))

        Response language contract:
        - latest_user_language: \(responseLanguage.rawValue)
        - write all report prose in \(responseLanguage == .chinese ? "Chinese" : "English"); keep paths, dependency names, framework names, and identifiers canonical.

        Allowed read-only tools:
        \(ReadOnlyInspectionPolicy.orderedAllowedTools.map { "- \($0)" }.joined(separator: "\n"))

        Return exactly one ReadOnlyNextAction decision, never a plan or a list of steps:
        - decision=tool: exactly one tool_call and no final_answer, clarification, or blocker_reason.
        - decision=finalize: zero tool calls and one grounded final_answer.
        - decision=clarify: zero tool calls and one essential clarification.
        - decision=block: zero tool calls and one safe blocker_reason.
        reasoning_summary is optional metadata and is never another action.
        Do not request mutation, shell, build, test, network, or connector actions.
        If finalization_required is true, do not request another tool. Produce a grounded partial or complete final answer now. A partial answer must explicitly name completed inspections, confirmed evidence, uninspected or unsatisfied areas, conclusions that cannot yet be made, and how to continue this same task.
        After inspect_project, reasonable next tools include list_directory, search_files, search_code, or read_file when the exact observed relative path is known. Do not repeat inspect_project for the same workspace root.
        For broad frontend/backend/database/dependency assessments, prioritize: repository root evidence; root manifest; discovered nested backend manifest; requested database schema/config; manifest-derived or exactly discovered backend startup entry; then a directly referenced or exactly discovered application assembly file when explicitly requested. Never spend a read on a guessed entry while a grounded backend manifest is available.
        A directory listing proves only each canonical child path and its file/directory type. A listed file is discovered, not inspected, and cannot establish contents, framework usage, dependencies, database provider, or runtime behavior.
        For a structure/framework/dependency report that asks for actual manifests or important files, do not finalize until relevant manifests have been successfully read with engineering.read_file.
        A final answer must begin with the useful conclusion and separate confirmed facts, engineering inferences, and limitations. For a Chinese structure/framework/database/dependency request, organize it as: 结论; 已确认的技术栈; 项目结构; 数据库; 重要依赖; 实际读取的文件; 推断与限制; 下一步. For English, use equivalent natural headings. Cite only paths present in successful read observations, except that a source-import path may be labeled referenced but not read. Do not count a discovered/search/referenced path as inspected. State backend startup entry and application assembly as separate requirements. Include actual extracted dependency names; never use vague placeholders such as "likely other dependencies." Never recommend reading a file already listed as successfully read. Include only the requested workspace; do not inventory the other workspace in a single-workspace mission. Performance findings must be labeled static/possible/suspected and must not claim CPU, memory, profiler, benchmark, build, or test results that were not observed. When build scripts or configuration are present, say exactly "Build scripts and configuration are present, but no build was executed during this inspection." in English or "已确认存在构建脚本和构建配置，但本轮未实际执行构建。" in Chinese. Never say build succeeds, build verified, 可构建, or production ready from static evidence.
        \(aiAssessmentContract)
        """
    }

    func repairPrompt(rejection: ReadOnlyNextActionRejection) -> String {
        """
        \(prompt())

        The previous observation decision was invalid.
        Exact rejection: \(rejection.reason.rawValue): \(rejection.detail)
        Return exactly one decision: one read-only tool call, one grounded final answer, one clarification, or one blocker. Do not return a complete plan.
        Valid contract:
        {"decision":"tool|finalize|clarify|block","tool_call":"one tool object or null","final_answer":"string or null","clarification":"string or null","blocker_reason":"string or null","reasoning_summary":"string or null"}
        Correct example:
        {"decision":"tool","tool_call":{"id":"next-read","type":"api","command":"engineering.read_file","arguments":["workspace=\(workspaceIdentity)","path=package.json"],"workingDirectory":null,"requiresApproval":false},"final_answer":null,"clarification":null,"blocker_reason":null,"reasoning_summary":"Read an observed manifest before finalizing."}
        """
    }
}

enum ReadOnlyModelDecision: Sendable {
    case tool(ReadOnlyExecutableStep)
    case clarification(String)
    case finalAnswer(String)
    case blocker(String)
}

struct ReadOnlyNextActionRejection: Error, Hashable, Sendable {
    var reason: PlanReadinessBlocker
    var detail: String
}

enum ReadOnlyNextActionValidation: Sendable {
    case accepted(ReadOnlyModelDecision)
    case rejected(ReadOnlyNextActionRejection)

    var rejection: ReadOnlyNextActionRejection? {
        guard case .rejected(let rejection) = self else { return nil }
        return rejection
    }
}
