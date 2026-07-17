import Foundation

enum MissionIntentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case aiAgentCompatibilityAssessment = "AI_AGENT_COMPATIBILITY_ASSESSMENT"
    case safeSandboxAcceptance = "SAFE_SANDBOX_ACCEPTANCE"
    case candidatePatchGeneration = "CANDIDATE_PATCH_GENERATION"
    case candidatePatchRevert = "CANDIDATE_PATCH_REVERT"
    case candidatePatchSandboxDestroy = "CANDIDATE_PATCH_SANDBOX_DESTROY"
    case answerQuestion = "answer_question"
    case inspectWorkspace = "inspect_workspace"
    case architectureAnalysis = "architecture_analysis"
    case debugIssue = "debug_issue"
    case modifyCode = "modify_code"
    case runTests = "run_tests"
    case createFeature = "create_feature"
    case refactorCode = "refactor_code"
    case explainCode = "explain_code"
    case generateReport = "generate_report"
    case manageRuntime = "manage_runtime"
    case unknown

    var id: String { rawValue }
}

enum MissionConstraint: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly = "read_only"
    case allowFileEdits = "allow_file_edits"
    case noNetwork = "no_network"
    case requiresApproval = "requires_approval"
    case preserveWorkspace = "preserve_workspace"
    case runVerification = "run_verification"

    var id: String { rawValue }
}

enum MissionExpectedOutput: String, Codable, CaseIterable, Identifiable, Sendable {
    case aiIntegrationAssessmentReport = "ai_integration_assessment_report"
    case safeSandboxAcceptanceReport = "safe_sandbox_acceptance_report"
    case candidatePatchPlan = "candidate_patch_plan"
    case candidatePatchReview = "candidate_patch_review"
    case candidatePatchRevertReview = "candidate_patch_revert_review"
    case candidatePatchSandboxDestructionReview = "candidate_patch_sandbox_destruction_review"
    case directAnswer = "direct_answer"
    case workspaceSummary = "workspace_summary"
    case architectureSummary = "architecture_summary"
    case riskAssessment = "risk_assessment"
    case improvementSuggestions = "improvement_suggestions"
    case testPlan = "test_plan"
    case codePatch = "code_patch"
    case testResults = "test_results"
    case executionReport = "execution_report"

    var id: String { rawValue }
}

enum MissionRiskTolerance: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }
}

struct MissionIntent: Codable, Hashable, Sendable {
    var originalText: String
    var detectedLanguage: String
    var normalizedGoal: String
    var intentType: MissionIntentType
    var domain: String?
    var targetFiles: [String]
    var constraints: [MissionConstraint]
    var expectedOutputs: [MissionExpectedOutput]
    var riskTolerance: MissionRiskTolerance
    var missingInformation: [String]
    var shouldAskClarification: Bool
    var clarificationQuestion: String?
    var confidence: Double

    enum CodingKeys: String, CodingKey {
        case originalText = "original_text"
        case detectedLanguage = "detected_language"
        case normalizedGoal = "normalized_goal"
        case intentType = "intent_type"
        case domain
        case targetFiles = "target_files"
        case constraints
        case expectedOutputs = "expected_outputs"
        case riskTolerance = "risk_tolerance"
        case missingInformation = "missing_information"
        case shouldAskClarification = "should_ask_clarification"
        case clarificationQuestion = "clarification_question"
        case confidence
    }
}

protocol MissionIntentParsing: Sendable {
    func parse(_ input: String) -> MissionIntent
}

struct MissionIntentParser: MissionIntentParsing {
    func parse(_ input: String) -> MissionIntent {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let language = detectedLanguage(for: trimmed)

        if trimmed.isEmpty || isGreeting(normalized) || isVague(normalized) {
            return MissionIntent(
                originalText: trimmed,
                detectedLanguage: language,
                normalizedGoal: trimmed.isEmpty ? "Clarify the user's mission" : trimmed,
                intentType: .unknown,
                domain: nil,
                targetFiles: [],
                constraints: [.preserveWorkspace],
                expectedOutputs: [.directAnswer],
                riskTolerance: .low,
                missingInformation: ["specific objective"],
                shouldAskClarification: true,
                clarificationQuestion: clarificationQuestion(for: .unknown, language: language),
                confidence: trimmed.isEmpty ? 0.05 : 0.25
            )
        }

        let intentType = classify(normalized)
        let constraints = constraints(for: normalized, intentType: intentType)
        let expectedOutputs = expectedOutputs(for: intentType)
        let targetFiles = targetFiles(for: trimmed, normalized: normalized, intentType: intentType)
        let missingInformation = missingInformation(for: normalized, intentType: intentType)
        let confidence = confidence(for: normalized, intentType: intentType, missingInformation: missingInformation)
        let shouldAsk = confidence < 0.55 || !missingInformation.isEmpty && intentType == .unknown

        return MissionIntent(
            originalText: trimmed,
            detectedLanguage: language,
            normalizedGoal: normalizedGoal(for: trimmed, intentType: intentType),
            intentType: intentType,
            domain: domain(for: normalized),
            targetFiles: targetFiles,
            constraints: constraints,
            expectedOutputs: expectedOutputs,
            riskTolerance: riskTolerance(for: constraints),
            missingInformation: missingInformation,
            shouldAskClarification: shouldAsk,
            clarificationQuestion: shouldAsk ? clarificationQuestion(for: intentType, language: language) : nil,
            confidence: confidence
        )
    }

    private func classify(_ normalized: String) -> MissionIntentType {
        if let primaryCandidatePatchAction = primaryCandidatePatchAction(normalized) {
            return primaryCandidatePatchAction
        }
        if isCandidatePatchRevert(normalized) {
            return .candidatePatchRevert
        }
        if isCandidatePatchGeneration(normalized) {
            return .candidatePatchGeneration
        }
        if isSafeSandboxAcceptance(normalized) {
            return .safeSandboxAcceptance
        }
        if isAgentCapabilityInquiry(normalized) {
            return .answerQuestion
        }
        if isPriorWorkQuestion(normalized) {
            return .answerQuestion
        }
        if isApprovedAIAgentIntegrationImplementation(normalized) {
            return .modifyCode
        }
        if isAIAgentIntegrationAssessment(normalized) {
            return .aiAgentCompatibilityAssessment
        }
        if isExplicitReadOnlyInspection(normalized) {
            return .inspectWorkspace
        }
        if containsAny(normalized, ["run test", "test suite", "测试", "跑测试"]) {
            return .runTests
        }
        if containsAny(normalized, ["debug", "bug", "error", "failure", "crash", "recover", "recovery", "missing api dependency", "报错", "错误", "失败", "崩溃", "排查"]) {
            return .debugIssue
        }
        if containsAny(normalized, ["architecture", "architectural", "project structure", "module", "dependencies", "架构", "结构", "模块", "依赖"]) {
            return .architectureAnalysis
        }
        if isImperativeReadOnlyInvestigation(normalized) {
            return .inspectWorkspace
        }
        if containsAny(normalized, ["refactor", "重构"]) {
            return .refactorCode
        }
        if containsAny(
            normalized,
            [
                "implement", "create feature", "add feature", "create a page", "new page", "new feature",
                "create a connector", "add an api", "新增", "实现功能", "新页面", "新功能", "创建一个 connector",
                "创建 connector", "新增一个 api", "新增 api"
            ]
        ) {
            return .createFeature
        }
        if containsAny(normalized, ["modify", "change code", "update code", "fix", "edit", "修改", "改代码", "改成", "调整", "变更", "更新代码", "修复"]) {
            return .modifyCode
        }
        if containsAny(normalized, ["explain", "walk me through", "解释", "说明"]) {
            return .explainCode
        }
        if containsAny(normalized, ["report", "summary", "summarize", "报告", "总结"]) {
            return .generateReport
        }
        if containsAny(normalized, ["audit", "inspect", "workspace", "read-only", "只读", "审计", "检查", "查看", "工作区", "看看项目", "看一下项目"]) {
            return .inspectWorkspace
        }
        if containsAny(normalized, ["pause", "continue", "stop", "cancel", "暂停", "继续", "停止", "取消"]) {
            return .manageRuntime
        }
        if normalized.hasSuffix("?") || containsAny(normalized, ["what", "why", "how", "什么", "为什么", "如何", "怎么", "吗"]) {
            return .answerQuestion
        }
        return .unknown
    }

    private func isPriorWorkQuestion(_ normalized: String) -> Bool {
        let chineseHistoryReference = containsAny(normalized, ["刚才", "刚刚", "之前", "上次", "前面", "先前"])
            && containsAny(normalized, ["修改", "改了", "变更", "做了", "执行", "运行", "代码", "文件", "测试"])
        let chinesePastChangeQuestion = containsAny(normalized, ["你修改了", "你改了", "修改了哪些", "改了哪些"])
            && containsAny(normalized, ["代码", "文件"])
        let englishHistoryQuestion = containsAny(
            normalized,
            [
                "what did you change",
                "what did you modify",
                "what code did you change",
                "what code did you modify",
                "what files changed",
                "what changes did you make",
                "did you modify any code",
                "did you change any code",
                "which files did you change",
                "which files did you modify",
                "how did you change",
                "how did you modify",
                "how was the code changed",
                "what changed",
                "previous mission",
                "previous task",
                "last mission",
                "last task",
                "earlier work"
            ]
        )
        return chineseHistoryReference || chinesePastChangeQuestion || englishHistoryQuestion
    }

    private func isSafeSandboxAcceptance(_ normalized: String) -> Bool {
        let explicitPhase = containsAny(
            normalized,
            [
                "phase 2d.0", "phase2d.0", "phase 2d0", "2d.0 安全沙箱", "2d.0 safe sandbox"
            ]
        ) && containsAny(normalized, ["sandbox", "沙箱", "验收", "acceptance"])
        let sandboxAction = containsAny(
            normalized,
            [
                "run safe sandbox acceptance",
                "safe sandbox acceptance",
                "create and validate an isolated sandbox",
                "create and validate isolated sandbox",
                "create and validate a safe sandbox",
                "创建并验证安全 sandbox",
                "创建并验证安全沙箱",
                "执行 phase 2d.0 安全沙箱验收",
                "对当前 legacy 创建隔离沙箱",
                "验证 sandbox 不修改原始项目",
                "验证沙箱不修改原始项目"
            ]
        )
        let isolatedSandboxRequest = containsAny(normalized, ["sandbox", "沙箱"])
            && containsAny(normalized, ["isolated", "isolation", "隔离", "安全"])
            && containsAny(normalized, ["create", "validate", "verify", "run", "acceptance", "创建", "验证", "执行", "验收"])
        return explicitPhase || sandboxAction || isolatedSandboxRequest
    }

    private func isCandidatePatchGeneration(_ normalized: String) -> Bool {
        let explicitlyProhibitsCandidatePatch = containsAny(
            normalized,
            [
                "do not generate a candidate patch", "don't generate a candidate patch",
                "no candidate patch", "without a candidate patch",
                "不要生成 candidate patch", "不要生成候选修改", "不要生成候选补丁",
                "不生成 candidate patch", "不生成候选修改", "不生成候选补丁"
            ]
        )
        if explicitlyProhibitsCandidatePatch { return false }
        let explicitCandidatePatch = containsAny(
            normalized,
            [
                "candidate patch", "candidate-patch", "候选修改", "候选补丁", "候选 patch",
                "生成候选修改", "生成 candidate patch", "candidate changes"
            ]
        )
        let sandboxImplementation = containsAny(normalized, ["sandbox", "沙箱"])
            && containsAny(
                normalized,
                [
                    "implement the proposed integration", "implement the proposed change",
                    "implement in an isolated", "implement in the safe", "apply proposed source changes",
                    "实现建议方案", "实现建议", "实施建议", "实现接入方案", "生成修改"
                ]
            )
        let assessmentBacked = containsAny(
            normalized,
            ["phase 2c", "phase2c", "integration assessment", "接入评估", "当前 ai 接入评估"]
        ) && containsAny(normalized, ["generate", "implement", "apply", "生成", "实现", "实施"])
        return explicitCandidatePatch || sandboxImplementation || assessmentBacked
    }

    private func isCandidatePatchRevert(_ normalized: String) -> Bool {
        let affirmativePhrases = [
            "回滚刚刚应用的 candidate patch",
            "撤销这个候选修改",
            "恢复 patch 修改前的 sandbox",
            "删除本次 patch 创建的文件",
            "恢复 preimage",
            "revert the applied candidate patch",
            "roll back this patch",
            "rollback this patch",
            "undo the sandbox changes",
            "restore the patch preimages"
        ]
        if containsAny(normalized, affirmativePhrases) { return true }

        let revertAction = containsAny(
            normalized,
            [
                "revert", "roll back", "rollback", "undo", "restore preimage", "restore the preimage",
                "回滚", "撤销", "恢复 preimage", "恢复修改前", "删除本次 patch 创建"
            ]
        )
        let patchObject = containsAny(
            normalized,
            [
                "candidate patch", "candidate-patch", "this patch", "the patch", "sandbox changes",
                "patch preimage", "候选修改", "候选补丁", "候选 patch", "本次 patch", "sandbox"
            ]
        )
        return revertAction && patchObject
    }

    private func primaryCandidatePatchAction(_ normalized: String) -> MissionIntentType? {
        let clauses = normalized
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var hasAffirmativeDestruction = false
        var hasAffirmativeRevert = false
        for clause in clauses {
            hasAffirmativeDestruction = hasAffirmativeDestruction
                || isAffirmativeCurrentSandboxDestruction(clause)
            hasAffirmativeRevert = hasAffirmativeRevert
                || isAffirmativeCurrentCandidatePatchRevert(clause)
        }
        if hasAffirmativeDestruction { return .candidatePatchSandboxDestroy }
        if hasAffirmativeRevert { return .candidatePatchRevert }
        return nil
    }

    private func isAffirmativeCurrentSandboxDestruction(_ clause: String) -> Bool {
        guard !isNegatedSandboxDestruction(clause),
              !isConditionalOrFutureSandboxDestruction(clause) else {
            return false
        }
        let affirmativePhrases = [
            "销毁这个已回滚的 sandbox",
            "销毁这个已经回滚的 sandbox",
            "删除这个 safe sandbox",
            "删除以下 safe sandbox",
            "销毁 patch 对应的隔离环境",
            "清理已完成 revert 的 sandbox",
            "现在清理这个已 revert 的隔离环境",
            "启动 sandbox_destruction_confirmation_required",
            "destroy the reverted patch sandbox",
            "destroy this reverted sandbox",
            "delete this safe sandbox",
            "delete the following safe sandbox",
            "remove the isolated sandbox after revert",
            "clean up the reverted patch sandbox",
            "start sandbox destruction confirmation now",
            "sandbox_destruction_confirmation_required"
        ]
        if containsAny(clause, affirmativePhrases) { return true }

        let imperativeDestruction = containsAny(
            clause,
            [
                "please destroy", "destroy this", "destroy the", "delete this", "delete the following",
                "remove this", "remove the", "clean up this", "clean up the", "cleanup this", "cleanup the",
                "want to destroy", "start sandbox destruction", "and destroy", "then destroy",
                "请销毁", "请删除", "请清理", "销毁这个", "销毁以下", "删除这个", "删除以下",
                "移除这个", "清理这个", "现在清理", "立即销毁", "希望销毁", "要销毁",
                "并销毁", "然后销毁", "启动 sandbox_destruction"
            ]
        )
        let sandboxObject = containsAny(
            clause,
            [
                "sandbox", "safe sandbox", "isolated sandbox", "isolated environment",
                "隔离环境", "沙箱"
            ]
        )
        return imperativeDestruction && sandboxObject
    }

    private func isAffirmativeCurrentCandidatePatchRevert(_ clause: String) -> Bool {
        guard !isNegatedCandidatePatchRevert(clause),
              !isConditionalRevertReference(clause) else {
            return false
        }
        let explicitMissionToken = clause.contains("candidate_patch_revert")
            && containsAny(
                clause,
                ["启动", "start", "route to", "流程", "flow", "仅对", "only"]
            )
            && !containsAny(
                clause,
                ["不要启动", "不得启动", "do not start", "do not route", "must not route"]
            )
        let imperativeRevert = containsAny(
            clause,
            [
                "please revert", "revert this", "revert the", "roll back this", "roll back the",
                "rollback this", "undo the sandbox changes", "restore the patch preimages",
                "start candidate_patch_revert", "启动专用 candidate_patch_revert", "启动 candidate_patch_revert",
                "请回滚", "仅对", "回滚这个", "回滚以下", "撤销这个候选修改",
                "恢复 patch 修改前", "恢复 preimage", "删除本次 patch 创建"
            ]
        )
        let patchObject = explicitMissionToken || containsAny(
            clause,
            [
                "candidate patch", "candidate-patch", "this patch", "the patch", "sandbox changes",
                "patch preimage", "候选修改", "候选补丁", "候选 patch", "本次 patch", "sandbox"
            ]
        )
        return (explicitMissionToken || imperativeRevert) && patchObject
    }

    private func isNegatedSandboxDestruction(_ clause: String) -> Bool {
        containsAny(
            clause,
            [
                "不要销毁", "不要删除", "不得销毁", "不销毁", "未授权销毁",
                "do not destroy", "don't destroy", "must not destroy", "not destroy",
                "do not delete", "do not remove", "destruction is not authorized",
                "destruction not authorized", "not authorized yet", "without destroying"
            ]
        )
    }

    private func isConditionalOrFutureSandboxDestruction(_ clause: String) -> Bool {
        let destructionMention = containsAny(
            clause,
            ["销毁", "删除 sandbox", "destruction", "destroy", "delete the sandbox"]
        )
        guard destructionMention else { return false }
        return containsAny(
            clause,
            [
                "销毁必须在", "成功后进行", "后再单独销毁", "revert 后再", "作为独立操作",
                "仅在 revert 成功后", "only after revert", "after revert succeeds",
                "destruction must", "separate later action", "separate action later",
                "must remain a separate action", "not authorized yet"
            ]
        )
    }

    private func isNegatedCandidatePatchRevert(_ clause: String) -> Bool {
        containsAny(
            clause,
            ["不要回滚", "不得回滚", "不回滚", "do not revert", "don't revert", "must not revert"]
        )
    }

    private func isConditionalRevertReference(_ clause: String) -> Bool {
        let destructionMention = containsAny(clause, ["销毁", "destruction", "destroy", "delete"])
        guard destructionMention else { return false }
        return containsAny(
            clause,
            [
                "revert 成功后", "revert 后再", "after revert succeeds", "only after revert",
                "after the revert succeeds", "once revert succeeds"
            ]
        )
    }

    private func isExplicitReadOnlyInspection(_ normalized: String) -> Bool {
        let forbidsMutation = containsAny(
            normalized,
            [
                "read-only",
                "readonly",
                "do not modify",
                "don't modify",
                "do not change",
                "without modifying",
                "no changes",
                "只读",
                "不要修改",
                "不要改",
                "不修改"
            ]
        )
        let asksToInspect = containsAny(
            normalized,
            [
                "inspect", "check", "read", "review", "analyze", "search", "find", "compare", "assess", "scan",
                "explain", "tell me", "检查", "查看", "读取", "审查", "分析", "搜索", "找到", "对比", "评估", "扫描", "看看", "解释", "告诉我"
            ]
        )
        return forbidsMutation && asksToInspect
    }

    private func isImperativeReadOnlyInvestigation(_ normalized: String) -> Bool {
        let readOnlyVerb = containsAny(
            normalized,
            [
                "read ", "inspect", "review", "analyze", "search", "find", "compare", "assess", "scan", "explain this file",
                "读取", "查看", "检查", "分析", "搜索", "找到", "看看", "审查", "对比", "评估", "扫描"
            ]
        )
        let workspaceOrSourceReference = containsAny(
            normalized,
            [
                "workspace", "repository", "repo", "project", "source", "code", "file", "class", "interface",
                ".swift", ".ts", ".tsx", ".js", ".jsx", ".py", ".md", ".json", ".yaml", ".yml",
                "工作区", "项目", "源码", "代码", "文件", "类", "接口", "实现", "输入框", "状态机",
                "legacy", "agent"
            ]
        )
        let mutationOrExecution = containsAny(
            normalized,
            [
                " edit", "modify", "fix", "create", "delete", "refactor", "build", "run test", "run command", "deploy",
                "修改", "改代码", "修复", "创建", "新建", "删除", "重构", "构建", "运行测试", "运行命令", "跑测试", "部署"
            ]
        )
        let explicitlyForbidsMutation = containsAny(
            normalized,
            ["do not modify", "don't modify", "without modifying", "no changes", "不要修改", "不要改", "不修改"]
        )
        return readOnlyVerb
            && workspaceOrSourceReference
            && (!mutationOrExecution || explicitlyForbidsMutation)
    }

    private func isAIAgentIntegrationAssessment(_ normalized: String) -> Bool {
        let desiredAICapability = containsAny(
            normalized,
            [
                "ai agent", "ai-agent", "aiagent", "ai assistant", "ai workflow",
                "customer support", "customer-support", "customer service", "customer-service",
                "customer support agent", "customer-support agent", "customer service agent",
                "customer-service agent", "sales agent", "workflow agent",
                "data analysis agent", "knowledge agent", "developer assistant",
                "智能体", "客服 agent", "客户支持 agent", "客户服务 agent", "ai 助手", "ai 工作流"
            ]
        )
        let asksForAssessment = containsAny(
            normalized,
            [
                "assess", "assessment", "evaluate", "evaluation", "评估", "评价",
                "接入", "集成", "可以接", "兼容", "准备好", "阻碍", "阻塞",
                "integrate", "integration", "connect", "support", "compatible", "compatibility",
                "ready", "readiness", "blocker", "preventing"
            ]
        )
        return desiredAICapability && asksForAssessment
    }

    private func isApprovedAIAgentIntegrationImplementation(_ normalized: String) -> Bool {
        guard isAIAgentIntegrationAssessment(normalized) else { return false }
        let explicitApproval = containsAny(
            normalized,
            [
                "approved implementation", "implementation approved", "customer approved",
                "批准实施", "批准写代码"
            ]
        )
        let explicitMutation = containsAny(
            normalized,
            [
                "write tests", "write code", "generate patch", "implement the integration",
                "写测试", "写代码", "生成 patch", "生成补丁", "实施接入"
            ]
        )
        return explicitApproval || explicitMutation
    }

    private func constraints(for normalized: String, intentType: MissionIntentType) -> [MissionConstraint] {
        var values: [MissionConstraint] = [.preserveWorkspace]
        if containsAny(normalized, ["read-only", "readonly", "no changes", "do not change", "只读", "不要修改"]) {
            values.append(.readOnly)
        }
        if containsAny(normalized, ["no network", "offline", "不要联网", "不联网"]) {
            values.append(.noNetwork)
        }

        switch intentType {
        case .candidatePatchSandboxDestroy:
            values.append(contentsOf: [.allowFileEdits, .requiresApproval, .noNetwork])
        case .candidatePatchRevert:
            values.append(contentsOf: [.allowFileEdits, .requiresApproval, .noNetwork])
        case .candidatePatchGeneration:
            values.append(contentsOf: [.allowFileEdits, .requiresApproval, .noNetwork])
        case .safeSandboxAcceptance:
            values.append(contentsOf: [.readOnly, .noNetwork, .runVerification])
        case .aiAgentCompatibilityAssessment, .architectureAnalysis, .inspectWorkspace, .answerQuestion, .explainCode, .generateReport:
            values.append(.readOnly)
        case .modifyCode, .createFeature, .refactorCode:
            values.append(contentsOf: [.allowFileEdits, .requiresApproval, .runVerification])
        case .debugIssue, .runTests:
            values.append(.runVerification)
        case .manageRuntime, .unknown:
            break
        }

        return unique(values)
    }

    private func expectedOutputs(for intentType: MissionIntentType) -> [MissionExpectedOutput] {
        switch intentType {
        case .candidatePatchSandboxDestroy:
            return [.candidatePatchSandboxDestructionReview, .executionReport]
        case .candidatePatchRevert:
            return [.candidatePatchRevertReview, .executionReport]
        case .candidatePatchGeneration:
            return [.candidatePatchPlan, .candidatePatchReview, .codePatch, .riskAssessment]
        case .safeSandboxAcceptance:
            return [.safeSandboxAcceptanceReport, .executionReport]
        case .aiAgentCompatibilityAssessment:
            return [.aiIntegrationAssessmentReport, .architectureSummary, .riskAssessment, .testPlan]
        case .architectureAnalysis:
            return [.architectureSummary, .riskAssessment, .improvementSuggestions, .testPlan]
        case .inspectWorkspace:
            return [.workspaceSummary, .executionReport]
        case .debugIssue:
            return [.riskAssessment, .codePatch, .testResults]
        case .modifyCode, .createFeature, .refactorCode:
            return [.testPlan, .codePatch, .testResults, .executionReport]
        case .runTests:
            return [.testResults]
        case .explainCode, .answerQuestion:
            return [.directAnswer]
        case .generateReport:
            return [.executionReport]
        case .manageRuntime:
            return [.executionReport]
        case .unknown:
            return [.directAnswer]
        }
    }

    private func targetFiles(
        for input: String,
        normalized: String,
        intentType: MissionIntentType
    ) -> [String] {
        var targets = explicitFileReferences(in: input)
        if normalized.contains("package.swift") {
            targets.append("Package.swift")
        }
        if containsAny(normalized, ["source", "sources", "源码", "源代码"]) {
            targets.append("Sources")
        }
        if containsAny(normalized, ["test", "tests", "测试"]) {
            targets.append("Tests")
        }

        switch intentType {
        case .candidatePatchGeneration, .candidatePatchRevert, .candidatePatchSandboxDestroy:
            break
        case .safeSandboxAcceptance:
            break
        case .aiAgentCompatibilityAssessment, .architectureAnalysis:
            targets.append(contentsOf: ["Package.swift", "Sources", "Tests"])
        case .inspectWorkspace:
            if targets.isEmpty {
                targets.append(".")
            }
        default:
            break
        }

        return unique(targets)
    }

    private func explicitFileReferences(in input: String) -> [String] {
        let delimiters = CharacterSet.whitespacesAndNewlines
            .union(.init(charactersIn: "`'\"，。！？,;:()[]{}<>"))
        let supportedExtensions = [
            ".swift", ".ts", ".tsx", ".js", ".jsx", ".py", ".md", ".json", ".yaml", ".yml"
        ]
        return input.components(separatedBy: delimiters)
            .map { $0.trimmingCharacters(in: delimiters) }
            .filter { token in
                let lowercased = token.lowercased()
                return supportedExtensions.contains { lowercased.hasSuffix($0) }
            }
    }

    private func missingInformation(for normalized: String, intentType: MissionIntentType) -> [String] {
        switch intentType {
        case .debugIssue:
            if !containsAny(normalized, ["error", "报错", "错误", "crash", "失败", "stack", "log"]) {
                return ["error message or reproduction steps"]
            }
        case .unknown:
            return ["specific objective"]
        default:
            break
        }
        return []
    }

    private func confidence(
        for normalized: String,
        intentType: MissionIntentType,
        missingInformation: [String]
    ) -> Double {
        let base: Double
        switch intentType {
        case .unknown:
            base = 0.35
        case .debugIssue where !missingInformation.isEmpty:
            base = 0.62
        case .answerQuestion:
            base = 0.72
        case .modifyCode, .createFeature, .refactorCode:
            base = 0.78
        default:
            base = 0.88
        }
        let lengthBoost = normalized.count > 24 ? 0.05 : 0
        return min(0.95, max(0.05, base + lengthBoost))
    }

    private func normalizedGoal(for input: String, intentType: MissionIntentType) -> String {
        switch intentType {
        case .candidatePatchSandboxDestroy:
            return "Destroy one exactly bound reverted Candidate Patch Sandbox after separate explicit confirmation."
        case .candidatePatchRevert:
            return "Revert one exactly bound applied Candidate Patch inside its existing Safe Sandbox after explicit confirmation."
        case .candidatePatchGeneration:
            return "Generate an approval-gated Candidate Patch only inside the validated Safe Sandbox."
        case .safeSandboxAcceptance:
            return "Create, validate, and destroy an isolated Sandbox without changing the selected Legacy source."
        case .aiAgentCompatibilityAssessment:
            return "Assess whether the Legacy system can safely integrate the requested AI Agent capability."
        case .architectureAnalysis:
            return "Analyze the project architecture and suggest improvements."
        case .inspectWorkspace:
            return "Inspect the workspace and summarize relevant findings."
        case .debugIssue:
            return "Investigate the reported issue and identify a safe fix path."
        case .modifyCode:
            return "Modify the code according to the user's request."
        case .createFeature:
            return "Implement the requested feature."
        case .refactorCode:
            return "Refactor the code while preserving behavior."
        case .runTests:
            return "Run or prepare verification for the requested test scope."
        case .explainCode:
            return "Explain the relevant code clearly."
        case .generateReport:
            return "Generate a concise report from the available evidence."
        case .manageRuntime:
            return "Apply the requested runtime control instruction."
        case .answerQuestion:
            return input
        case .unknown:
            return input
        }
    }

    private func clarificationQuestion(for intentType: MissionIntentType, language: String) -> String {
        let usesChinese = language == "zh"
        switch intentType {
        case .candidatePatchSandboxDestroy:
            return usesChinese
                ? "请选择要销毁的确切已回滚 Candidate Patch Sandbox。"
                : "Select the exact reverted Candidate Patch Sandbox to destroy."
        case .candidatePatchRevert:
            return usesChinese
                ? "请选择要回滚的确切 Candidate Patch。"
                : "Select the exact Candidate Patch to revert."
        case .debugIssue:
            return usesChinese
                ? "你希望我从哪个报错、异常现象或复现步骤开始排查？"
                : "What error message, failing behavior, or reproduction step should I start from?"
        default:
            return usesChinese
                ? "你想让我在这个工作区里做什么？"
                : "What would you like me to do in this workspace?"
        }
    }

    private func riskTolerance(for constraints: [MissionConstraint]) -> MissionRiskTolerance {
        if constraints.contains(.allowFileEdits) || constraints.contains(.requiresApproval) {
            return .medium
        }
        return .low
    }

    private func domain(for normalized: String) -> String? {
        if containsAny(normalized, ["ios", "swiftui", "swift", "xcode"]) {
            return "apple_platform"
        }
        if containsAny(normalized, ["react", "next.js", "frontend", "web"]) {
            return "web"
        }
        if containsAny(normalized, ["api", "backend", "server"]) {
            return "backend"
        }
        return nil
    }

    private func detectedLanguage(for input: String) -> String {
        input.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        } ? "zh" : "en"
    }

    private func isGreeting(_ normalized: String) -> Bool {
        [
            "hi",
            "hello",
            "hey",
            "你好",
            "您好",
            "嗨",
            "哈喽"
        ].contains(normalized)
    }

    private func isVague(_ normalized: String) -> Bool {
        [
            "help",
            "start",
            "开始",
            "帮我",
            "看一下",
            "看看"
        ].contains(normalized) || normalized.count < 4
    }

    private func isAgentCapabilityInquiry(_ normalized: String) -> Bool {
        let asksQuestion = normalized.contains("?")
            || normalized.contains("？")
            || normalized.contains("吗")
            || normalized.contains("么")
            || normalized.contains("什么")
            || normalized.contains("what can")
            || normalized.contains("can you")
            || normalized.contains("could you")
            || normalized.contains("are you able")
        guard asksQuestion else { return false }

        let refersToAgent = normalized.contains("你")
            || normalized.contains("you")
            || normalized.contains("agent")
        guard refersToAgent else { return false }

        return containsAny(
            normalized,
            [
                "会什么",
                "能做什么",
                "可以做什么",
                "有什么能力",
                "是否会",
                "会不会",
                "能不能",
                "可不可以",
                "会解决",
                "能解决",
                "解决软件测试",
                "软件测试的问题",
                "修复测试",
                "跑测试",
                "改代码",
                "写代码",
                "what can you do",
                "capabilities",
                "can you fix",
                "can you solve",
                "can you run tests",
                "are you able to"
            ]
        )
    }

    private func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
