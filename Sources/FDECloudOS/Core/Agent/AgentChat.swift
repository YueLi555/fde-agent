import Foundation

struct AgentChatMessageContext: Codable, Hashable, Sendable {
    var sender: AgentMessageSender
    var type: AgentMessageType
    var content: String
}

struct AgentToolEvidenceContext: Codable, Hashable, Sendable {
    var toolCallID: String
    var toolName: String
    var workspaceID: UUID
    var taskID: UUID?
    var workspaceIdentity: String
    var targetPath: String
    var toolCalledEventID: UUID
    var toolResultEventID: UUID

    static func successfulPairs(
        from events: [ExecutionEvent],
        workspaceID: UUID,
        taskID: UUID?
    ) -> [AgentToolEvidenceContext] {
        let scoped = events.filter { event in
            event.workspaceID == workspaceID
                && (taskID == nil || event.taskID == taskID)
        }
        var called: [String: ExecutionEvent] = [:]
        for event in scoped where event.type == .toolCalled {
            guard let callID = event.payload["tool_call_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !callID.isEmpty,
                  called[callID] == nil else {
                continue
            }
            called[callID] = event
        }
        var seen = Set<String>()
        return scoped.compactMap { result in
            guard result.type == .stepExecuted,
                  result.payload["success"] == "true" || result.payload["exit_code"] == "0",
                  let callID = result.payload["tool_call_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let call = called[callID],
                  call.taskID == result.taskID,
                  seen.insert(callID).inserted else {
                return nil
            }
            let calledTool = call.payload["command"] ?? call.payload["tool_name"] ?? ""
            let resultTool = result.payload["command"] ?? result.payload["tool_name"] ?? calledTool
            guard !calledTool.isEmpty,
                  resultTool == calledTool || resultTool.isEmpty else {
                return nil
            }
            return AgentToolEvidenceContext(
                toolCallID: callID,
                toolName: calledTool,
                workspaceID: workspaceID,
                taskID: result.taskID,
                workspaceIdentity: result.payload["workspace_identity"]
                    ?? call.payload["workspace_identity"]
                    ?? "",
                targetPath: result.payload["target_path"]
                    ?? call.payload["target_path"]
                    ?? ".",
                toolCalledEventID: call.id,
                toolResultEventID: result.id
            )
        }
    }
}

enum FDEConversationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case casualConversation
    case fdeCapabilityExplanation
    case engineeringExplanation
    case legacyTransformationAdvisory
    case workspaceReadOnlyInvestigation
    case executableEngineeringTask
    case runtimeControl
}

enum AgentRuntimeMode: String, Codable, Hashable, Sendable {
    case chat = ".chat"
    case agentTask = ".agentTask"
    case fallback = ".fallback"
}

struct AgentRuntimeProfile: Codable, Hashable, Sendable {
    var currentMissionState: MissionState
    var allowedNextStates: [MissionState]
    var transitionGraph: [String: [String]]
    var executableIntentTypes: [MissionIntentType]
    var directChatIntentTypes: [MissionIntentType]
    var workspaceActions: [AgentRuntimeAction]
    var humanGateActions: [AgentRuntimeAction]
    var toolStates: [ToolExecutionState]

    enum CodingKeys: String, CodingKey {
        case currentMissionState = "current_mission_state"
        case allowedNextStates = "allowed_next_states"
        case transitionGraph = "transition_graph"
        case executableIntentTypes = "executable_intent_types"
        case directChatIntentTypes = "direct_chat_intent_types"
        case workspaceActions = "workspace_actions"
        case humanGateActions = "human_gate_actions"
        case toolStates = "tool_states"
    }

    static func make(
        interactionState: AgentInteractionState,
        hasRuntimeTask: Bool
    ) -> AgentRuntimeProfile {
        let stateMachine = MissionStateMachine()
        let currentState = missionState(for: interactionState, hasRuntimeTask: hasRuntimeTask)
        let graph = stateMachine.transitionGraph().reduce(into: [String: [String]]()) { result, item in
            result[item.key.rawValue] = item.value.map(\.rawValue)
        }

        return AgentRuntimeProfile(
            currentMissionState: currentState,
            allowedNextStates: stateMachine.allowedNextStates(from: currentState),
            transitionGraph: graph,
            executableIntentTypes: [
                .candidatePatchGeneration,
                .generatedTestPlan,
                .safeSandboxAcceptance,
                .inspectWorkspace,
                .architectureAnalysis,
                .debugIssue,
                .modifyCode,
                .runTests,
                .createFeature,
                .refactorCode,
                .explainCode,
                .generateReport,
                .manageRuntime
            ],
            directChatIntentTypes: [.answerQuestion, .unknown],
            workspaceActions: [
                .submitTask,
                .executeTool,
                .continueMission,
                .resumeTask,
                .changeApproach,
                .requestPause,
                .stopTask
            ],
            humanGateActions: [
                .askClarification,
                .requestHumanApproval,
                .answerCapability,
                .acknowledgeInstruction
            ],
            toolStates: ToolExecutionState.allCases
        )
    }

    private static func missionState(
        for interactionState: AgentInteractionState,
        hasRuntimeTask: Bool
    ) -> MissionState {
        switch interactionState {
        case .idle:
            return hasRuntimeTask ? .ready : .idle
        case .understanding:
            return .understand
        case .planning:
            return .plan
        case .working:
            return .execute
        case .waitingForUser, .waitingForApproval:
            return .waitingHuman
        case .verifying:
            return .verifying
        case .blocked:
            return .blocked
        case .completed:
            return .complete
        case .failed:
            return .failed
        }
    }
}

struct AgentChatRequest: Codable, Hashable, Sendable {
    var message: String
    var detectedLanguage: String
    var intentType: MissionIntentType
    var workspaceName: String
    var legacyWorkspaceName: String?
    var agentWorkspaceName: String?
    var interactionState: AgentInteractionState
    var hasRuntimeTask: Bool
    var selectedMode: FDEConversationMode
    var recentMessages: [AgentChatMessageContext]
    var runtimeProfile: AgentRuntimeProfile
    var repairInstruction: String?
    var toolEvidence: [AgentToolEvidenceContext]
    var activeTaskContextIncluded: Bool

    enum CodingKeys: String, CodingKey {
        case message
        case detectedLanguage = "detected_language"
        case intentType = "intent_type"
        case workspaceName = "workspace_name"
        case legacyWorkspaceName = "legacy_workspace_name"
        case agentWorkspaceName = "agent_workspace_name"
        case interactionState = "interaction_state"
        case hasRuntimeTask = "has_runtime_task"
        case selectedMode = "selected_chat_mode"
        case recentMessages = "recent_messages"
        case runtimeProfile = "runtime_profile"
        case repairInstruction = "repair_instruction"
        case toolEvidence = "tool_evidence"
        case activeTaskContextIncluded = "active_task_context_included"
    }

    init(
        message: String,
        detectedLanguage: String,
        intentType: MissionIntentType,
        workspaceName: String,
        legacyWorkspaceName: String? = nil,
        agentWorkspaceName: String? = nil,
        interactionState: AgentInteractionState,
        hasRuntimeTask: Bool,
        selectedMode: FDEConversationMode = .casualConversation,
        recentMessages: [AgentChatMessageContext],
        runtimeProfile: AgentRuntimeProfile? = nil,
        repairInstruction: String? = nil,
        toolEvidence: [AgentToolEvidenceContext] = [],
        activeTaskContextIncluded: Bool = false
    ) {
        self.message = message
        self.detectedLanguage = detectedLanguage
        self.intentType = intentType
        self.workspaceName = workspaceName
        self.legacyWorkspaceName = legacyWorkspaceName
        self.agentWorkspaceName = agentWorkspaceName
        self.interactionState = interactionState
        self.hasRuntimeTask = hasRuntimeTask
        self.selectedMode = selectedMode
        self.recentMessages = recentMessages
        self.runtimeProfile = runtimeProfile ?? AgentRuntimeProfile.make(
            interactionState: interactionState,
            hasRuntimeTask: hasRuntimeTask
        )
        self.repairInstruction = repairInstruction
        self.toolEvidence = toolEvidence
        self.activeTaskContextIncluded = activeTaskContextIncluded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try container.decode(String.self, forKey: .message)
        self.detectedLanguage = try container.decode(String.self, forKey: .detectedLanguage)
        self.intentType = try container.decode(MissionIntentType.self, forKey: .intentType)
        self.workspaceName = try container.decode(String.self, forKey: .workspaceName)
        self.legacyWorkspaceName = try container.decodeIfPresent(String.self, forKey: .legacyWorkspaceName)
        self.agentWorkspaceName = try container.decodeIfPresent(String.self, forKey: .agentWorkspaceName)
        self.interactionState = try container.decode(AgentInteractionState.self, forKey: .interactionState)
        self.hasRuntimeTask = try container.decode(Bool.self, forKey: .hasRuntimeTask)
        self.selectedMode = try container.decodeIfPresent(FDEConversationMode.self, forKey: .selectedMode)
            ?? .casualConversation
        self.recentMessages = try container.decode([AgentChatMessageContext].self, forKey: .recentMessages)
        self.runtimeProfile = try container.decodeIfPresent(AgentRuntimeProfile.self, forKey: .runtimeProfile)
            ?? AgentRuntimeProfile.make(
                interactionState: interactionState,
                hasRuntimeTask: hasRuntimeTask
            )
        self.repairInstruction = try container.decodeIfPresent(String.self, forKey: .repairInstruction)
        self.toolEvidence = try container.decodeIfPresent([AgentToolEvidenceContext].self, forKey: .toolEvidence) ?? []
        self.activeTaskContextIncluded = try container.decodeIfPresent(Bool.self, forKey: .activeTaskContextIncluded) ?? false
    }
}

struct AgentChatResponse: Codable, Hashable, Sendable {
    var content: String
    var confidence: Double?
    var provider: ModelProviderKind?
    var usedFallback: Bool
    var runtimeMode: AgentRuntimeMode
    var model: String?
    var qualityRetryUsed: Bool
    var qualityRejectionReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case confidence
        case provider
        case usedFallback = "used_fallback"
        case runtimeMode = "runtime_mode"
        case model
        case qualityRetryUsed = "quality_retry_used"
        case qualityRejectionReason = "quality_rejection_reason"
    }

    init(
        content: String,
        confidence: Double? = nil,
        provider: ModelProviderKind? = nil,
        usedFallback: Bool = false,
        runtimeMode: AgentRuntimeMode = .chat,
        model: String? = nil,
        qualityRetryUsed: Bool = false,
        qualityRejectionReason: String? = nil
    ) {
        self.content = content
        self.confidence = confidence
        self.provider = provider
        self.usedFallback = usedFallback
        self.runtimeMode = runtimeMode
        self.model = model
        self.qualityRetryUsed = qualityRetryUsed
        self.qualityRejectionReason = qualityRejectionReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try container.decode(String.self, forKey: .content)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        self.provider = try container.decodeIfPresent(ModelProviderKind.self, forKey: .provider)
        self.usedFallback = try container.decodeIfPresent(Bool.self, forKey: .usedFallback) ?? false
        self.runtimeMode = try container.decodeIfPresent(AgentRuntimeMode.self, forKey: .runtimeMode) ?? .chat
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.qualityRetryUsed = try container.decodeIfPresent(Bool.self, forKey: .qualityRetryUsed) ?? false
        self.qualityRejectionReason = try container.decodeIfPresent(String.self, forKey: .qualityRejectionReason)
    }

    func sanitized(
        fallbackContent: String,
        provider selectedProvider: ModelProviderKind?,
        usedFallback fallbackUsed: Bool,
        runtimeMode selectedRuntimeMode: AgentRuntimeMode? = nil
    ) -> AgentChatResponse {
        let safeContent = AgentPresentationSanitizer.safeMarkdownContent(content, fallback: fallbackContent)
        let finalContent = AgentPresentationSanitizer.containsRestrictedContent(safeContent)
            ? fallbackContent
            : safeContent
        return AgentChatResponse(
            content: finalContent,
            confidence: confidence.map { min(max($0, 0), 1) },
            provider: selectedProvider ?? provider,
            usedFallback: fallbackUsed,
            runtimeMode: selectedRuntimeMode ?? runtimeMode,
            model: model,
            qualityRetryUsed: qualityRetryUsed,
            qualityRejectionReason: qualityRejectionReason
        )
    }
}

protocol AgentChatProviding: Sendable {
    var kind: ModelProviderKind { get }
    var modelIdentifier: String? { get }
    var isAvailable: Bool { get }
    var disabledReason: String? { get }
    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse
}

extension AgentChatProviding {
    var modelIdentifier: String? { nil }
}

struct StateMachineChatProvider: AgentChatProviding {
    let kind: ModelProviderKind = .local
    let isAvailable = true
    let disabledReason: String? = nil

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        AgentChatResponse(
            content: responseContent(for: request),
            confidence: 0.72,
            provider: kind,
            usedFallback: true,
            runtimeMode: .fallback
        )
    }

    private func responseContent(for request: AgentChatRequest) -> String {
        let usesChinese = request.detectedLanguage == "zh" || containsCJK(request.message)
        let normalized = request.message
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?.,， "))
        switch request.selectedMode {
        case .casualConversation:
            if containsAny(normalized, ["哈哈", "haha", "lol"]) {
                return usesChinese ? "哈哈，我在。" : "Ha, I’m here."
            }
            if containsAny(normalized, ["为什么笑", "why i laughed", "why did i laugh"]) {
                return usesChinese
                    ? "我只能猜：可能是刚才的内容戳中了你的笑点，也可能只是心情不错。你愿意告诉我是哪一种吗？"
                    : "I can only guess: maybe something just landed as funny, or you were simply in a good mood. Which was it?"
            }
            if isGreeting(normalized) || containsAny(normalized, ["还在吗", "在吗", "怎么了", "you there"]) {
                return usesChinese ? "在，我在这儿。" : "Yes, I’m here."
            }
            return usesChinese ? "可以。你具体想弄哪件事？" : "Sure. What are you trying to work out?"

        case .fdeCapabilityExplanation:
            if isIdentityQuestion(normalized) {
                return usesChinese
                    ? "我是 FDE Agent，一个帮助传统软件接入 AI Agent 的工程助手。我能解释方案，也能在真实只读检查后给出代码依据；只有明确的执行任务才会修改文件、运行命令和验证，任务结论以真实工具和文件证据为准。"
                    : "I’m FDE Agent, an engineering agent for moving traditional software toward safe AI Agent integration. I can explain designs, ground findings in real read-only inspection, and only modify or verify work through an explicit executable task with evidence."
            }
            if containsAny(normalized, ["swift", "swiftui", "swiftpm", "xcode"]) {
                return usesChinese
                    ? "懂。我可以解释 Swift、SwiftUI 状态管理、并发、SwiftPM 依赖、构建与测试问题；也可以在你要求只读分析时检查真实项目。现在我还没有因为这条能力问题读取任何文件。"
                    : "Yes. I can reason about Swift, SwiftUI state, concurrency, SwiftPM dependencies, builds, and tests, and inspect a real project when you ask for read-only analysis. I have not read files merely from this capability question."
            }
            return usesChinese
                ? "我主要做 Legacy-to-Agent 工程转型：分析现有架构与工作流，设计 API、工具、权限、审批、上下文和审计边界，并在明确授权后实现代码、运行测试和提供证据。没有实际检查或执行时，我会把建议与已验证事实分开。"
                : "I focus on Legacy-to-Agent engineering: architecture and workflow analysis, API/tool/permission/approval/context/audit design, and—when explicitly requested—implementation and evidence-backed verification. I separate advice from facts actually inspected or executed."

        case .engineeringExplanation:
            if containsAny(normalized, ["状态机", "state machine"]) {
                return usesChinese
                    ? "状态机定义“有哪些状态以及状态如何转换”；状态机路由根据当前输入和状态选择下一条允许的路径；总状态机则在系统级协调多个子状态机并维护全局约束。工程 Agent 中，对话路由可以直接回答概念问题，而执行状态机只在真实任务中进入规划、执行和验证。"
                    : "A state machine defines states and legal transitions; state-machine routing selects a legal next path from the current input and state; an overall state machine coordinates several subordinate machines and global invariants. In an engineering agent, chat routing can answer a concept directly while execution states are reserved for real work."
            }
            return usesChinese
                ? "这是一个工程解释问题，不需要读取工作区。核心要看机制、触发条件、失败原因和取舍；如果你给出具体概念或报错，我可以按这四层展开。"
                : "This is an engineering explanation, so no workspace inspection is needed. The useful breakdown is mechanism, trigger, failure cause, and tradeoffs; give me the exact concept or error and I’ll work through those layers."

        case .legacyTransformationAdvisory:
            return usesChinese
                ? "判断传统软件是否适合接入 Agent，要依次检查：架构边界与可调用接口、业务流程是否可分解、数据质量与敏感性、权限和人工审批、Agent 能力与集成缺口、失败回退与审计、测试可观测性，以及可量化的业务结果。这是通用评估框架；没有读取当前 Legacy 和 Agent 工作区前，我不会把它当作项目结论。"
                : "Assess Agent readiness across architecture and callable interfaces, workflow decomposability, data quality and sensitivity, permissions and human approval, Agent capability gaps, failure fallback and auditability, test observability, and measurable business outcomes. This is an advisory framework, not a conclusion about the selected workspaces until they are inspected."

        case .workspaceReadOnlyInvestigation:
            return usesChinese
                ? "这个请求需要先读取真实工作区文件；在获得读取证据前我不能给出项目结论。"
                : "This request requires real workspace reads; I cannot give a project-specific conclusion before collecting evidence."
        case .executableEngineeringTask:
            return usesChinese
                ? "这是可执行工程任务，应交给现有任务运行时处理，并以真实变更和验证结果为准。"
                : "This is executable engineering work and should be handled by the task runtime with real changes and verification evidence."
        case .runtimeControl:
            return usesChinese ? "已收到运行控制指令。" : "Runtime control instruction received."
        }
    }

    private func isGreeting(_ normalized: String) -> Bool {
        ["hi", "hello", "hey", "你好", "您好", "嗨", "哈喽", "早上好", "晚上好"].contains(normalized)
    }

    private func isCapabilityQuestion(_ normalized: String) -> Bool {
        [
            "你能做什么",
            "你可以做什么",
            "你会做什么",
            "你有什么能力",
            "你能帮我做什么",
            "what can you do",
            "what do you do",
            "your capabilities",
            "capabilities"
        ].contains { normalized.contains($0) }
    }

    private func isIdentityQuestion(_ normalized: String) -> Bool {
        ["你是谁", "你是做什么的", "who are you", "what are you"].contains { normalized.contains($0) }
    }

    private func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }

    private func capabilitySummary(for profile: AgentRuntimeProfile, chinese: Bool) -> String {
        let capabilities = profile.executableIntentTypes.compactMap { intent -> String? in
            switch intent {
            case .candidatePatchSandboxDestroy:
                return chinese ? "销毁已回滚候选补丁的确切 Sandbox" : "destroy the exact Sandbox bound to a reverted Candidate Patch"
            case .candidatePatchRevert:
                return chinese ? "安全回滚已应用候选补丁" : "revert exactly bound applied Candidate Patches"
            case .candidatePatchGeneration:
                return chinese ? "生成审批后候选补丁" : "generate approval-gated Candidate Patches"
            case .generatedTestPlan:
                return chinese ? "只读准备 Generated Test Plan" : "prepare an exact-bound read-only Generated Test Plan"
            case .safeSandboxAcceptance:
                return chinese ? "执行安全沙箱验收" : "run Safe Sandbox acceptance"
            case .aiAgentCompatibilityAssessment:
                return chinese ? "评估 AI Agent 接入兼容性" : "assess AI Agent integration compatibility"
            case .inspectWorkspace:
                return chinese ? "检查项目" : "inspect the selected projects"
            case .architectureAnalysis:
                return chinese ? "分析架构" : "analyze architecture"
            case .debugIssue:
                return chinese ? "排查问题" : "debug issues"
            case .modifyCode, .createFeature, .refactorCode:
                return chinese ? "修改或新增代码" : "modify, add, or refactor code"
            case .runTests:
                return chinese ? "运行验证" : "run validation"
            case .explainCode:
                return chinese ? "解释代码" : "explain code"
            case .generateReport:
                return chinese ? "生成报告" : "produce a report"
            case .manageRuntime:
                return chinese ? "暂停、继续或停止任务" : "pause, resume, or stop work"
            case .answerQuestion, .unknown:
                return nil
            }
        }
        let uniqueCapabilities = unique(capabilities)
        if chinese {
            return "我能处理：\(uniqueCapabilities.joined(separator: "、"))。"
        }
        return "I can \(uniqueCapabilities.joined(separator: ", "))."
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct FDEChatQualityGuard: Sendable {
    func rejectionReason(
        for response: AgentChatResponse,
        request: AgentChatRequest
    ) -> String? {
        let answer = normalized(response.content)
        guard !answer.isEmpty else { return "empty_response" }

        if let evidenceRejection = AgentEvidenceClaimGuard().rejectionReason(
            for: response.content,
            evidence: request.toolEvidence,
            workspaceID: nil
        ) {
            return evidenceRejection
        }

        if request.selectedMode != .fdeCapabilityExplanation,
           let previousAssistant = request.recentMessages.last(where: { $0.sender == .agent })?.content,
           let previousUser = request.recentMessages.last(where: { $0.sender == .user })?.content,
           materiallyDifferent(previousUser, request.message),
           similarity(previousAssistant, response.content) >= 0.9 {
            return "repeated_previous_answer"
        }

        if request.selectedMode != .fdeCapabilityExplanation,
           capabilityEnumerationScore(answer) >= 3 {
            return "capability_enumeration_for_unrelated_question"
        }

        if request.selectedMode != .runtimeControl,
           containsAny(answer, [
               "task state remains unchanged", "current mission state", "understanding → planning", "planning → execution",
               "interaction state", "work status", "任务状态保持不变", "当前任务状态", "理解→规划", "工作状态"
           ]) {
            return "runtime_state_dominated_answer"
        }

        if containsAny(answer, [
            "customer service assistant", "customer support assistant", "help customers with common questions",
            "客户服务助手", "客服助手", "帮助客户解决常见问题"
        ]) {
            return "generic_customer_support_answer"
        }

        if request.selectedMode == .engineeringExplanation,
           containsAny(answer, [
               "i understand your question", "please provide more details", "how can i assist",
               "我理解了你的问题", "请提供更多信息", "我能如何帮助你"
           ]) {
            return "direct_engineering_question_ignored"
        }
        return nil
    }

    func repairInstruction(reason: String, mode: FDEConversationMode) -> String {
        let evidenceBoundary = reason.hasPrefix("unsupported_evidence_claim")
            ? " There is no matching successful tool evidence for the rejected claim. Do not say or imply that files were read, inspected, checked, analyzed, or commands were run. Do not invent likely framework filenames. If useful, label a statement explicitly as an unverified hypothesis."
            : ""
        return "The previous answer was rejected (\(reason)). Answer the current user message directly in \(mode.rawValue) mode. Preserve useful conversational context, do not enumerate unrelated capabilities, do not narrate runtime state, and do not claim inspection or execution without evidence.\(evidenceBoundary)"
    }

    private func capabilityEnumerationScore(_ answer: String) -> Int {
        [
            "inspect", "modify", "run tests", "build", "deploy", "architecture", "permissions", "approval",
            "检查", "修改", "运行测试", "构建", "部署", "架构", "权限", "审批"
        ].reduce(0) { $0 + (answer.contains($1) ? 1 : 0) }
    }

    private func materiallyDifferent(_ lhs: String, _ rhs: String) -> Bool {
        similarity(lhs, rhs) < 0.65
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        guard left != right else { return 1 }
        let leftBigrams = bigrams(left)
        let rightBigrams = bigrams(right)
        guard !leftBigrams.isEmpty, !rightBigrams.isEmpty else { return 0 }
        let overlap = leftBigrams.intersection(rightBigrams).count
        return Double(2 * overlap) / Double(leftBigrams.count + rightBigrams.count)
    }

    private func bigrams(_ value: String) -> Set<String> {
        let characters = Array(value)
        guard characters.count > 1 else { return Set([value]) }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }

    private func normalized(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }
}

struct AgentEvidenceClaimGuard: Sendable {
    func rejectionReason(
        for answer: String,
        evidence: [AgentToolEvidenceContext],
        workspaceID: UUID?
    ) -> String? {
        let normalized = answer.lowercased()
        let claimsReadOrInspection = containsAny(normalized, [
            "i read ", "i've read ", "i have read ", "i inspected ", "i've inspected ",
            "i checked ", "i've checked ", "i found in ", "i found that in ",
            "已读取", "我读取了", "我已读取", "已检查", "我检查了", "我已检查",
            "已分析项目代码", "我分析了项目代码"
        ])
        let claimsExecution = containsAny(normalized, [
            "i ran ", "i've run ", "i have run ", "tests passed", "已运行", "我运行了", "测试已通过"
        ])
        guard claimsReadOrInspection || claimsExecution else { return nil }

        let scopedEvidence = evidence.filter { item in
            workspaceID == nil || item.workspaceID == workspaceID
        }
        guard !scopedEvidence.isEmpty else {
            return "unsupported_evidence_claim:no_matching_tool_call_and_result"
        }

        if claimsReadOrInspection {
            let paths = claimedFilePaths(in: answer)
            if !paths.isEmpty {
                for path in paths where !scopedEvidence.contains(where: { matches(path: path, evidence: $0) }) {
                    return "unsupported_evidence_claim:path=\(path)"
                }
            } else if !scopedEvidence.contains(where: { item in
                item.toolName == "engineering.inspect_project"
                    || item.toolName == "engineering.list_directory"
                    || item.toolName == "engineering.search_files"
                    || item.toolName == "engineering.search_code"
                    || item.toolName == "engineering.read_file"
            }) {
                return "unsupported_evidence_claim:no_matching_inspection_result"
            }
        }
        return nil
    }

    private func matches(path: String, evidence: AgentToolEvidenceContext) -> Bool {
        guard evidence.toolName == "engineering.read_file" else { return false }
        let claimed = normalizePath(path)
        let observed = normalizePath(evidence.targetPath)
        guard !claimed.isEmpty, !observed.isEmpty else { return false }
        if claimed.contains("/") {
            return observed == claimed || observed.hasSuffix("/\(claimed)")
        }
        return URL(fileURLWithPath: observed).lastPathComponent == claimed
    }

    private func claimedFilePaths(in answer: String) -> [String] {
        let pattern = #"(?i)(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:prisma|swift|json|jsx|tsx|java|cpp|hpp|yaml|toml|php|yml|js|ts|py|kt|go|rs|rb|cs|cc|mm|md|c|h|m)(?![A-Za-z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var values: [String] = []
        var inReadSection = false
        let readSectionMarkers = ["files read", "read files", "files/manifests read", "实际读取的文件", "实际读取文件"]
        let directReadMarkers = [
            "i read ", "i've read ", "i have read ", "i inspected ", "i checked ",
            "successfully read", "已读取", "我读取了", "我已读取", "已检查", "我检查了", "我已检查"
        ]
        let negativeMarkers = ["not read", "unread", "未读取", "尚未读取", "引用但未读取", "仅被引用"]
        for rawLine in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let normalizedLine = line.lowercased().trimmingCharacters(in: .whitespaces)
            if normalizedLine.hasPrefix("#") {
                inReadSection = readSectionMarkers.contains(where: normalizedLine.contains)
            }
            let isNegative = negativeMarkers.contains(where: normalizedLine.contains)
            let isReadClaim = inReadSection || directReadMarkers.contains(where: normalizedLine.contains)
            guard isReadClaim, !isNegative else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in expression.matches(in: line, range: range) {
                guard let swiftRange = Range(match.range, in: line) else { continue }
                let value = normalizePath(String(line[swiftRange]))
                if seen.insert(value).inserted { values.append(value) }
            }
        }
        return values
    }

    private func normalizePath(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()[]{}.,，。:：;； "))
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
    }

    private func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }
}
