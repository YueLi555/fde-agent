import Foundation

struct CompiledPrompt: Codable, Hashable, Sendable {
    var missionState: MissionState
    var systemInstruction: String
    var userPrompt: String
    var workspaceContextJSON: String
    var worldModelJSON: String
    var policyConstraints: [String]
    var toolAccess: PromptToolAccess
    var allowedActions: [AgentRuntimeAction]
    var forbiddenActions: [AgentRuntimeAction]
    var outputContract: PromptOutputContract
}

struct PromptToolAccess: Codable, Hashable, Sendable {
    var enabled: Bool
    var mode: String
    var availableTools: [String]
    var allowedToolTypes: [ToolType]
}

struct PromptOutputContract: Codable, Hashable, Sendable {
    var schemaName: String
    var format: String
    var requiredTopLevelKeys: [String]
    var validationRules: [String]
    var schemaJSON: String
}

struct PromptOrchestrator: Sendable {
    func compile(
        state: MissionState,
        input: String,
        context: ExecutionContext,
        worldModel: SystemWorldModel? = nil,
        memory: AgentRelevantMemory? = nil
    ) -> CompiledPrompt {
        let profile = MissionStatePromptProfile.profile(for: state)
        let readOnlyMission = context.missionIntent.map {
            MissionExecutionSemantic(intent: $0) == .readOnlyWorkspaceInspection
        } ?? false
        let allowedActions = Self.allowedActions(for: state)
        let forbiddenActions = AgentRuntimeAction.allCases.filter { !allowedActions.contains($0) }
        let toolAccess = Self.toolAccess(for: state, context: context)
        let outputContract = Self.outputContract(for: state)
        let effectiveWorldModel = worldModel ?? Self.synthesizedWorldModel(from: context)
        let workspaceContext = PromptWorkspaceContext(
            workspaceID: context.workspace.id,
            workspaceName: context.workspace.name,
            displayName: context.workspace.displayName,
            role: context.workspace.role.rawValue,
            graphSummary: context.graphSummary,
            recentTaskTitles: context.recentTaskTitles,
            taskFingerprint: context.taskFingerprint,
            missionIntent: context.missionIntent,
            contextBundle: context.contextBundle
        )
        let workspaceContextJSON = Self.encode(workspaceContext)
        let worldModelJSON = Self.encode(effectiveWorldModel)
        let policyConstraints = Self.policyConstraints(from: context)
        let userPayload = PromptUserPayload(
            taskInput: input,
            currentMissionState: state,
            workspaceContext: workspaceContext,
            worldModel: effectiveWorldModel,
            memory: memory,
            policyConstraints: policyConstraints,
            toolAccess: toolAccess,
            allowedActions: allowedActions,
            forbiddenActions: forbiddenActions,
            outputContract: outputContract
        )
        let userPayloadJSON = Self.encode(userPayload)
        let systemInstruction = Self.systemInstruction(
            state: state,
            profile: profile,
            allowedActions: allowedActions,
            forbiddenActions: forbiddenActions,
            toolAccess: toolAccess,
            outputContract: outputContract,
            readOnlyMission: readOnlyMission
        )

        return CompiledPrompt(
            missionState: state,
            systemInstruction: systemInstruction,
            userPrompt: """
            Runtime prompt compiler payload:
            \(userPayloadJSON)
            """,
            workspaceContextJSON: workspaceContextJSON,
            worldModelJSON: worldModelJSON,
            policyConstraints: policyConstraints,
            toolAccess: toolAccess,
            allowedActions: allowedActions,
            forbiddenActions: forbiddenActions,
            outputContract: outputContract
        )
    }

    private static func systemInstruction(
        state: MissionState,
        profile: MissionStatePromptProfile,
        allowedActions: [AgentRuntimeAction],
        forbiddenActions: [AgentRuntimeAction],
        toolAccess: PromptToolAccess,
        outputContract: PromptOutputContract,
        readOnlyMission: Bool
    ) -> String {
        let readOnlyProtocol = readOnlyMission ? readOnlyToolProtocol(observation: state == .observe) : ""
        let semanticContract = state == .observe && readOnlyMission
            ? "OBSERVE returns one ReadOnlyNextAction object. It must not return plan, actions, risks, confidence, or a list of steps. reasoning_summary is metadata only."
            : "Every plan step must declare an explicit kind: tool, reasoning, finalization, clarification, or blocker. A tool step must reference a real tool_call id; non-tool steps must not reference one."
        return """
        You are the FDE Cloud OS runtime LLM boundary for mission state \(state.rawValue).
        \(profile.instruction)
        The MissionStateMachine controls behavior. Treat current_mission_state as the source of truth for what the model may decide next.
        Allowed runtime actions: \(allowedActions.map(\.rawValue).joined(separator: ", ")).
        Forbidden runtime actions: \(forbiddenActions.map(\.rawValue).joined(separator: ", ")).
        Tool access mode: \(toolAccess.mode). Tool execution enabled: \(toolAccess.enabled ? "true" : "false").
        Available tools are supplied in the user payload. PLAN declares proposed tool calls for later runtime execution; it never executes them directly. OBSERVE may propose exactly one next read-only tool call after an actual observation. Only EXECUTE performs a validated call.
        \(semanticContract)
        COMPLETE is runtime-controlled: only VERIFYING may enter COMPLETE, and only after the controller validates real successful tool-result evidence. Planning, narration, and state-transition events are not completion evidence.
        Return only valid JSON matching \(outputContract.schemaName).
        Required top-level keys: \(outputContract.requiredTopLevelKeys.joined(separator: ", ")).
        Do not wrap JSON in markdown fences, backticks, or explanatory prose.
        Do not include chain-of-thought, secrets, credentials, raw logs beyond the supplied sanitized context, or actions forbidden for this state.
        Do not rely on memorized user phrasing. Derive behavior from mission state, runtime context, world model, policy constraints, tool policy, and output contract.
        \(readOnlyProtocol)
        """
    }

    private static func readOnlyToolProtocol(observation: Bool) -> String {
        let schemas = ReadOnlyInspectionPolicy.orderedAllowedTools.compactMap { command -> String? in
            guard let schema = ReadOnlyToolSchemas.all[command] else { return nil }
            let required = schema.requiredModelArguments.isEmpty ? "none" : schema.requiredModelArguments.joined(separator: ", ")
            let defaults = schema.runtimeDefaultableArguments.joined(separator: ", ")
            let optional = schema.optionalArguments.isEmpty ? "none" : schema.optionalArguments.joined(separator: ", ")
            return "- \(command): model-required=[\(required)]; runtime-defaultable=[\(defaults)]; optional=[\(optional)]"
        }.joined(separator: "\n")
        let example = observation
            ? #"{"decision":"tool","tool_call":{"id":"next-read","type":"api","command":"engineering.read_file","arguments":["workspace=legacy","path=package.json"],"workingDirectory":null,"requiresApproval":false},"final_answer":null,"clarification":null,"blocker_reason":null,"reasoning_summary":"Read an observed manifest before finalizing."}"#
            : #"{"plan":[{"id":"step-1","title":"Inspect Legacy structure","intent":"Inspect the selected Legacy project structure.","kind":"tool","toolCallID":"inspect-legacy-root","requiresApproval":false,"retryBudget":0}],"actions":[],"tool_calls":[{"id":"inspect-legacy-root","type":"api","command":"engineering.inspect_project","arguments":["workspace=legacy","path=."],"workingDirectory":null,"requiresApproval":false}],"risks":[],"confidence":0.9}"#
        let contractRule = observation
            ? "Return exactly one tool_call or one terminal decision. Do not return plan steps or a full replacement plan."
            : "The plan step toolCallID must exactly match the tool call id."
        return """
        Read-only workspace tool argument protocol:
        \(schemas)
        workspace values are only legacy or agent. Omit workspace only for an unambiguous single-workspace mission; comparison calls must provide it.
        The runtime injects workingDirectory from the selected workspace. Never guess an absolute path. Supply paths relative to that workspace.
        inspect_project and list_directory default path to ".". search_files and search_code default path to "." but always require query. read_file always requires path.
        For structure or dependency inspection, begin with engineering.inspect_project or engineering.list_directory. A read_file path must then exactly match a canonical file path from a successful directory listing, file/code search, manifest-derived entry, or inspected project metadata. Never guess a directory, basename, or extension.
        For broad frontend/backend/database/dependency requests, prioritize root evidence, the root manifest, a discovered nested backend manifest, requested database schema/config, then the exact manifest-derived or discovered backend entry. A listed file is discovered but not read and does not prove contents or framework usage.
        Tool-call arguments use key=value strings. Example:
        \(example)
        \(contractRule)
        """
    }

    private static func allowedActions(for state: MissionState) -> [AgentRuntimeAction] {
        switch state {
        case .idle:
            return [.answerCapability, .askClarification, .submitTask, .acknowledgeInstruction]
        case .understand:
            return [.answerCapability, .askClarification, .submitTask]
        case .plan:
            return [.submitTask, .requestHumanApproval, .continueMission]
        case .ready:
            return [.continueMission, .requestHumanApproval, .requestPause, .replan]
        case .execute:
            return [.executeTool, .requestHumanApproval, .continueMission, .requestPause]
        case .observe:
            return [.continueMission, .replan, .requestHumanApproval, .stopTask]
        case .verifying:
            return [.continueMission, .replan, .requestHumanApproval, .stopTask]
        case .adapt:
            return [.replan, .changeApproach, .requestHumanApproval, .continueMission]
        case .waitingHuman:
            return [.askClarification, .resumeTask, .stopTask, .acknowledgeInstruction]
        case .blocked:
            return [.askClarification, .replan, .resumeTask, .stopTask]
        case .failed:
            return [.acknowledgeInstruction, .replan, .stopTask]
        case .complete:
            return [.acknowledgeInstruction, .stopTask]
        }
    }

    private static func toolAccess(for state: MissionState, context: ExecutionContext) -> PromptToolAccess {
        let availableTools = runtimeAvailableTools(from: context)
        let executionEnabled = state == .execute
        let mayProposeTools = state == .plan || state == .observe || executionEnabled
        return PromptToolAccess(
            enabled: executionEnabled,
            mode: executionEnabled
                ? "EXECUTION_ENABLED_FOR_VALIDATED_TOOLS"
                : (mayProposeTools ? "TOOL_PROPOSAL_ONLY_RUNTIME_EXECUTES" : "NO_TOOL_EXECUTION_OR_PROPOSAL"),
            availableTools: availableTools,
            allowedToolTypes: mayProposeTools ? [.api] : []
        )
    }

    private static func runtimeAvailableTools(from context: ExecutionContext) -> [String] {
        let localTools = context.contextBundle?.systemState.availableLocalTools ?? []
        let graphTools = context.contextBundle?.graphSummary.knownTools ?? []
        if context.missionIntent.map({ MissionExecutionSemantic(intent: $0) == .readOnlyWorkspaceInspection }) == true {
            return ReadOnlyInspectionPolicy.orderedAllowedTools
        }
        let fallbackTools = ReadOnlyInspectionPolicy.orderedAllowedTools
        return unique(localTools + graphTools + fallbackTools)
    }

    private static func outputContract(for state: MissionState) -> PromptOutputContract {
        if state == .observe {
            return PromptOutputContract(
                schemaName: "ReadOnlyNextAction",
                format: "strict JSON object",
                requiredTopLevelKeys: ["decision", "tool_call", "final_answer", "clarification", "blocker_reason", "reasoning_summary"],
                validationRules: [
                    "Return exactly one decision: tool, finalize, clarify, or block.",
                    "tool requires exactly one allowed read-only tool_call and no terminal field.",
                    "finalize, clarify, and block require zero tool calls and exactly their matching terminal field.",
                    "reasoning_summary is optional metadata, never a second executable action.",
                    "Do not return plan, actions, risks, confidence, or a complete list of steps."
                ],
                schemaJSON: schemaJSON(ReadOnlyNextActionSchema.jsonSchema())
            )
        }
        return PromptOutputContract(
            schemaName: "StructuredAgentOutput",
            format: "strict JSON object",
            requiredTopLevelKeys: ["plan", "actions", "tool_calls", "risks", "confidence"],
            validationRules: [
                "Output must pass StructuredAgentOutputSchema JSON validation before decoding.",
                "Output must pass StructuredOutputValidator before any state transition.",
                "Plan steps may reference only tool_call ids present in tool_calls.",
                "Every plan step must have an explicit semantic kind.",
                "Executable tool steps must reference a present tool_call; non-tool steps must not reference one.",
                "Confidence must be between 0 and 1.",
                "A no-tool response cannot complete an executable mission.",
                "Only the runtime completion gate may transition VERIFYING to COMPLETE after validating tool-result evidence."
            ],
            schemaJSON: schemaJSON(StructuredAgentOutputSchema.jsonSchema())
        )
    }

    private static func schemaJSON(_ schema: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(schema),
              let data = try? JSONSerialization.data(
                withJSONObject: schema,
                options: [.sortedKeys]
              ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func policyConstraints(from context: ExecutionContext) -> [String] {
        var constraints = context.policyRules
        constraints += context.policyDeltas.map(\.summary)
        constraints += context.policyDeltas.compactMap(\.avoidToolCommand).map { "avoid_tool:\($0)" }
        constraints += context.policyDeltas.compactMap { delta in
            guard let avoid = delta.avoidToolCommand, let replacement = delta.replacementToolCommand else {
                return nil
            }
            return "fallback:\(avoid)->\(replacement)"
        }
        if let globalExecutionPolicy = context.globalExecutionPolicy {
            constraints.append("global_policy:\(globalExecutionPolicy.summary)")
            constraints += globalExecutionPolicy.avoidedToolCommands.map { "global_avoid_tool:\($0)" }
            constraints += globalExecutionPolicy.toolPreferences.map { "global_fallback:\($0.key)->\($0.value)" }
        }
        constraints += context.contextBundle?.policySummary.policyRules ?? []
        constraints += context.contextBundle?.policySummary.avoidedTools.map { "context_avoid_tool:\($0)" } ?? []
        return unique(constraints)
    }

    private static func synthesizedWorldModel(from context: ExecutionContext) -> SystemWorldModel {
        let bundle = context.contextBundle
        return SystemWorldModel(
            workspaceID: context.workspace.id,
            customerContext: "\(context.workspace.displayName) role=\(context.workspace.role.rawValue) org=\(context.workspace.orgID.uuidString)",
            connectedSystems: unique(bundle?.graphSummary.detectedSystems ?? []),
            permissions: unique(["role:\(context.workspace.role.rawValue)"] + context.policyRules),
            previousFailures: unique(
                context.failurePatterns.map { "\($0.command):\($0.count) prior failure(s)" }
                    + (context.systemFailureProfile?.recurringSignatures ?? [])
            ),
            environmentFacts: unique([
                "workspace_namespace:\(context.workspace.eventNamespace)",
                "task_fingerprint:\(context.taskFingerprint)"
            ] + (bundle?.workspace.packageIndicators.map { "package:\($0)" } ?? [])),
            observations: []
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        (try? JSONCoding.encode(value)) ?? "{}"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let safeValue = AgentPresentationSanitizer.safeContent(value, fallback: "")
            guard !safeValue.isEmpty, seen.insert(safeValue).inserted else {
                continue
            }
            result.append(safeValue)
        }
        return result
    }
}

private struct PromptWorkspaceContext: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var workspaceName: String
    var displayName: String
    var role: String
    var graphSummary: String
    var recentTaskTitles: [String]
    var taskFingerprint: String
    var missionIntent: MissionIntent?
    var contextBundle: ContextBundle?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case workspaceName = "workspace_name"
        case displayName = "display_name"
        case role
        case graphSummary = "graph_summary"
        case recentTaskTitles = "recent_task_titles"
        case taskFingerprint = "task_fingerprint"
        case missionIntent = "mission_intent"
        case contextBundle = "context_bundle"
    }
}

private struct PromptUserPayload: Codable, Hashable, Sendable {
    var taskInput: String
    var currentMissionState: MissionState
    var workspaceContext: PromptWorkspaceContext
    var worldModel: SystemWorldModel
    var memory: AgentRelevantMemory?
    var policyConstraints: [String]
    var toolAccess: PromptToolAccess
    var allowedActions: [AgentRuntimeAction]
    var forbiddenActions: [AgentRuntimeAction]
    var outputContract: PromptOutputContract

    enum CodingKeys: String, CodingKey {
        case taskInput = "task_input"
        case currentMissionState = "current_mission_state"
        case workspaceContext = "workspace_context"
        case worldModel = "world_model"
        case memory
        case policyConstraints = "policy_constraints"
        case toolAccess = "tool_access"
        case allowedActions = "allowed_actions"
        case forbiddenActions = "forbidden_actions"
        case outputContract = "output_contract"
    }
}

private struct MissionStatePromptProfile: Hashable, Sendable {
    var instruction: String

    static func profile(for state: MissionState) -> MissionStatePromptProfile {
        switch state {
        case .idle:
            return MissionStatePromptProfile(
                instruction: "Remain idle until a concrete executable mission is accepted. Conversation-only requests must not start tool execution or synthesize execution phases."
            )
        case .understand:
            return MissionStatePromptProfile(
                instruction: "Act as the System Understanding Agent. Understand mission intent, identify missing information, build or refine the world model, and decide whether planning may begin. Do not execute tools in UNDERSTAND."
            )
        case .plan:
            return MissionStatePromptProfile(
                instruction: "Act as the Planner Agent. Create a bounded plan and declare proposed tool calls that the runtime will execute later. PLAN itself never executes tools, but executable missions must still include linked tool steps. For read-only inspection, use only the five allowed engineering inspection tools and never propose mutation or commands."
            )
        case .ready:
            return MissionStatePromptProfile(
                instruction: "Act as the Readiness Agent. Confirm that the validated plan contains a concrete executable tool step and that required approvals are satisfied. If no executable tool step exists, remain READY or request clarification; never claim completion."
            )
        case .execute:
            return MissionStatePromptProfile(
                instruction: "Act as the Executor Agent. Select only approved tool calls from the validated plan, respect scoped working directories, and request approval before risky or forbidden execution. Tools are enabled only in EXECUTE."
            )
        case .observe:
            return MissionStatePromptProfile(
                instruction: "Act as the Observation Agent. Analyze the actual bounded tool result and choose exactly one next action: propose one allowed read-only tool, ask one essential clarification, provide a grounded final answer, or declare a truthful blocker. OBSERVE proposes but never directly executes tools."
            )
        case .verifying:
            return MissionStatePromptProfile(
                instruction: "Act as the Verification Agent. Evaluate runtime-provided tool results, exit status, observations, and unresolved errors against the mission. Only validated real evidence may pass the controller completion gate; synthetic phase events and narration are invalid evidence."
            )
        case .adapt:
            return MissionStatePromptProfile(
                instruction: "Act as the Recovery Agent. Adapt after failures or human steering by forming a recovery hypothesis, modifying the plan, and producing safe recovery tool proposals for a later EXECUTE state."
            )
        case .waitingHuman:
            return MissionStatePromptProfile(
                instruction: "Act as the Human Coordination Agent. Preserve state, ask for the smallest missing decision or approval, and do not advance execution until human input resolves the wait condition."
            )
        case .blocked:
            return MissionStatePromptProfile(
                instruction: "Act as the Blocked-State Coordinator. Preserve the blocking evidence, identify the exact policy, permission, dependency, or environment obstacle, and request only the input needed to resume safely."
            )
        case .failed:
            return MissionStatePromptProfile(
                instruction: "Act as the Failure Reporter. Preserve real error evidence, explain what failed without claiming completion, and offer a bounded recovery path. Do not execute tools in FAILED."
            )
        case .complete:
            return MissionStatePromptProfile(
                instruction: "Act as the Completion Agent. Close the mission with validated outcome evidence, residual risks, and final confidence. Do not create new tool calls in COMPLETE."
            )
        }
    }
}

extension ModelReasoningRole {
    var missionState: MissionState {
        switch self {
        case .planning:
            return .plan
        case .execution:
            return .execute
        case .recovery:
            return .adapt
        case .policy:
            return .verifying
        }
    }
}
