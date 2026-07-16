import XCTest
@testable import FDECloudOS

final class MissionIntentTests: XCTestCase {
    func testParsesChineseArchitectureAnalysisIntent() {
        let intent = MissionIntentParser().parse("帮我看看这个项目架构有什么问题，并给出改进建议")

        XCTAssertEqual(intent.detectedLanguage, "zh")
        XCTAssertEqual(intent.intentType, .architectureAnalysis)
        XCTAssertTrue(intent.constraints.contains(.readOnly))
        XCTAssertTrue(intent.expectedOutputs.contains(.architectureSummary))
        XCTAssertTrue(intent.expectedOutputs.contains(.improvementSuggestions))
        XCTAssertEqual(intent.targetFiles, ["Package.swift", "Sources", "Tests"])
        XCTAssertFalse(intent.shouldAskClarification)
        XCTAssertGreaterThanOrEqual(intent.confidence, 0.85)
    }

    func testChineseAIAgentIntegrationQuestionIsActionableCompatibilityAssessment() {
        let intent = MissionIntentParser().parse("看看这个项目可以接ai agent吗")

        XCTAssertEqual(intent.detectedLanguage, "zh")
        XCTAssertEqual(intent.intentType, .aiAgentCompatibilityAssessment)
        XCTAssertTrue(intent.constraints.contains(.readOnly))
        XCTAssertTrue(intent.expectedOutputs.contains(.riskAssessment))
        XCTAssertTrue(intent.expectedOutputs.contains(.aiIntegrationAssessmentReport))
        XCTAssertFalse(intent.shouldAskClarification)
    }

    func testAssessmentExamplesSelectDedicatedMissionType() {
        let inputs = [
            "Can this system support a customer service AI agent?",
            "Can we integrate an AI assistant into this legacy application?",
            "Analyze whether this software is ready for an AI workflow.",
            "Find blockers preventing AI agent integration."
        ]

        for input in inputs {
            let intent = MissionIntentParser().parse(input)
            XCTAssertEqual(intent.intentType, .aiAgentCompatibilityAssessment, input)
            XCTAssertTrue(intent.constraints.contains(.readOnly), input)
            XCTAssertFalse(intent.constraints.contains(.allowFileEdits), input)
        }
    }

    func testApprovedAIAgentIntegrationImplementationAllowsCodePatchAndVerification() {
        let intent = MissionIntentParser().parse(
            "Customer approved implementation for AI agent integration, write tests, generate patch, adapter client service"
        )

        XCTAssertEqual(intent.intentType, .modifyCode)
        XCTAssertTrue(intent.constraints.contains(.allowFileEdits))
        XCTAssertTrue(intent.constraints.contains(.requiresApproval))
        XCTAssertTrue(intent.constraints.contains(.runVerification))
        XCTAssertTrue(intent.expectedOutputs.contains(.testPlan))
        XCTAssertTrue(intent.expectedOutputs.contains(.codePatch))
        XCTAssertTrue(intent.expectedOutputs.contains(.testResults))
    }

    func testVagueMissionAsksForClarification() {
        let intent = MissionIntentParser().parse("帮我")

        XCTAssertEqual(intent.intentType, .unknown)
        XCTAssertTrue(intent.shouldAskClarification)
        XCTAssertEqual(intent.clarificationQuestion, "你想让我在这个工作区里做什么？")
        XCTAssertEqual(intent.missingInformation, ["specific objective"])
    }

    func testChineseClarificationOptionPhrasesClassifyAsActionableIntents() {
        let inspect = MissionIntentParser().parse("查看工作区")
        let debug = MissionIntentParser().parse("排查问题")

        XCTAssertEqual(inspect.intentType, .inspectWorkspace)
        XCTAssertFalse(inspect.shouldAskClarification)
        XCTAssertEqual(debug.intentType, .debugIssue)
    }

    func testPriorCodeChangeQuestionIsReadOnlyConversationIntent() {
        let input = "你刚才修改了哪些代码？"
        let intent = MissionIntentParser().parse(input)
        let classifier = AgentMissionClassifier()

        XCTAssertEqual(intent.intentType, .answerQuestion)
        XCTAssertTrue(intent.constraints.contains(.readOnly))
        XCTAssertFalse(intent.constraints.contains(.allowFileEdits))
        XCTAssertTrue(classifier.isPriorWorkQuestion(input))
        XCTAssertFalse(classifier.isExplicitMissionRequest(input, intent: intent))
    }

    func testReadOnlyFilenameInspectionDoesNotBecomeModificationIntent() {
        let input = "检查 AgentConversationView.swift，告诉我它负责什么，不要修改。"
        let intent = MissionIntentParser().parse(input)
        let classifier = AgentMissionClassifier()

        XCTAssertEqual(intent.intentType, .inspectWorkspace)
        XCTAssertEqual(intent.targetFiles, ["AgentConversationView.swift"])
        XCTAssertTrue(intent.constraints.contains(.readOnly))
        XCTAssertFalse(intent.constraints.contains(.allowFileEdits))
        XCTAssertTrue(classifier.isWorkspaceQuestion(input, intent: intent))
        XCTAssertFalse(classifier.isExplicitMissionRequest(input, intent: intent))
    }

    func testImperativeReadOnlyRequestsDoNotRequireQuestionPunctuation() {
        let inputs = [
            "查看 AppStore.swift",
            "搜索状态机实现",
            "分析 AgentSession.swift，不要修改",
            "找到输入框代码",
            "review AgentChat.swift"
        ]
        let classifier = AgentMissionClassifier()

        for input in inputs {
            let intent = MissionIntentParser().parse(input)
            XCTAssertEqual(intent.intentType, .inspectWorkspace, input)
            XCTAssertTrue(classifier.isWorkspaceQuestion(input, intent: intent), input)
            XCTAssertFalse(classifier.isExplicitMissionRequest(input, intent: intent), input)
            XCTAssertEqual(
                classifier.conversationMode(for: input, intent: intent, hasActiveRuntimeTask: false),
                .workspaceReadOnlyInvestigation,
                input
            )
        }
    }

    func testExplicitWorkspaceEngineeringWinsOverPassiveSummaryRouting() {
        let classifier = AgentMissionClassifier()
        let engineeringInputs = [
            "只读取当前 Legacy 项目的根目录并列出主要文件，不要修改任何文件。",
            "请只读检查当前 Legacy 项目的 package.json 和 manifest，分析 framework、database 与 dependency，验证主要文件并列出依据；不要修改任何文件。"
        ]

        for input in engineeringInputs {
            let intent = classifier.intent(for: input)
            XCTAssertTrue(classifier.isWorkspaceQuestion(input, intent: intent), input)
            XCTAssertTrue(classifier.requiresReadOnlyRuntime(input, intent: intent), input)
            XCTAssertFalse(classifier.isPassiveWorkspaceSummaryRequest(input), input)
            XCTAssertEqual(
                classifier.conversationMode(for: input, intent: intent, hasActiveRuntimeTask: false),
                .workspaceReadOnlyInvestigation,
                input
            )
        }
    }

    func testPassiveWorkspaceSummaryShortcutRequiresExplicitOverviewWording() {
        let classifier = AgentMissionClassifier()
        let overviewInputs = [
            "当前两个 workspace 各有多少文件？",
            "当前选择了哪些项目？",
            "给我一个 workspace 概览。"
        ]

        for input in overviewInputs {
            XCTAssertTrue(classifier.isPassiveWorkspaceSummaryRequest(input), input)
            XCTAssertFalse(classifier.requiresReadOnlyRuntime(input), input)
        }
    }

    func testConversationModesKeepAdviceAndEngineeringQuestionsOutOfExecution() {
        let classifier = AgentMissionClassifier()
        let cases: [(String, FDEConversationMode)] = [
            ("还在吗", .casualConversation),
            ("怎么了", .casualConversation),
            ("怎么弄", .casualConversation),
            ("你是谁？你的工作是什么？", .fdeCapabilityExplanation),
            ("你懂 Swift 吗？具体能做什么？", .fdeCapabilityExplanation),
            ("你能做什么", .fdeCapabilityExplanation),
            ("状态机路由是什么？", .engineeringExplanation),
            ("解释状态机", .engineeringExplanation),
            ("如何判断一个传统软件能不能接入 AI Agent？", .legacyTransformationAdvisory),
            ("传统软件怎么接 Agent", .legacyTransformationAdvisory),
            ("修改输入框文案，然后运行 swift build。", .executableEngineeringTask)
        ]

        for (input, expectedMode) in cases {
            let intent = classifier.intent(for: input)
            XCTAssertEqual(
                classifier.conversationMode(for: input, intent: intent, hasActiveRuntimeTask: false),
                expectedMode,
                input
            )
        }
    }

    func testFailureDependencyIntentWinsOverArchitectureDependencyKeyword() {
        let intent = MissionIntentParser().parse(
            "Simulate a missing API dependency, trigger recovery, and generate a failure report"
        )

        XCTAssertEqual(intent.intentType, .debugIssue)
        XCTAssertFalse(intent.shouldAskClarification)
    }

    func testLocalPlannerUsesArchitectureIntentForProjectStructurePlan() async throws {
        let workspace = Workspace.default()
        let input = "Analyze this project architecture and suggest improvements."
        let context = ExecutionContext(
            workspace: workspace,
            policyRules: [],
            graphSummary: "empty",
            recentTaskTitles: [],
            taskFingerprint: TaskFingerprint.make(from: input),
            policyDeltas: [],
            failurePatterns: [],
            systemFailureProfile: nil,
            globalExecutionPolicy: nil,
            missionIntent: MissionIntentParser().parse(input)
        )

        let output = try await LocalDeterministicModelProvider()
            .generatePlan(for: input, context: context)

        XCTAssertEqual(output.plan.map(\.id), [
            "step.context",
            "step.package",
            "step.sources",
            "step.tests",
            "step.report"
        ])
        XCTAssertTrue(output.toolCalls.contains {
            $0.id == "tool.sources.inspect" && $0.command == "/bin/ls" && $0.arguments == ["-la", "Sources"]
        })
        XCTAssertTrue(output.toolCalls.contains {
            $0.id == "tool.tests.inspect" && $0.command == "/bin/ls" && $0.arguments == ["-la", "Tests"]
        })
        XCTAssertNoThrow(try StructuredOutputValidator().validate(output))
    }

    func testLocalPlannerUsesImplementationFlowAfterCustomerApproval() async throws {
        let workspace = Workspace(
            id: UUID(),
            name: "Integration Workspace",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: "/tmp/PetFound",
            localAgentProjectRoot: "/tmp/FDE"
        )
        let input = "Customer approved implementation for AI agent integration, write tests and generate patch"
        let context = ExecutionContext(
            workspace: workspace,
            policyRules: [],
            graphSummary: "empty",
            recentTaskTitles: [],
            taskFingerprint: TaskFingerprint.make(from: input),
            policyDeltas: [],
            failurePatterns: [],
            systemFailureProfile: nil,
            globalExecutionPolicy: nil,
            missionIntent: MissionIntentParser().parse(input)
        )

        let output = try await LocalDeterministicModelProvider()
            .generatePlan(for: input, context: context)

        XCTAssertEqual(output.plan.map(\.id), [
            "step.implementation-scope",
            "step.agent-implementation-scope",
            "step.test-plan",
            "step.code-patch",
            "step.verification-report"
        ])
        XCTAssertTrue(output.toolCalls.contains { $0.id == "tool.implementation.patch" })
        XCTAssertTrue(output.toolCalls.contains { $0.id == "tool.implementation.verify" })
        XCTAssertNoThrow(try StructuredOutputValidator().validate(output))
    }

    func testContextCompilerInjectsMissionIntentIntoPlannerContext() async {
        let workspace = Workspace.default()
        let context = await InstructionContextCompiler().compile(
            workspace: workspace,
            taskInput: "Analyze this project architecture and suggest improvements.",
            recentTasks: [],
            graph: ([], [])
        )

        XCTAssertEqual(context.missionIntent?.intentType, .architectureAnalysis)
        XCTAssertEqual(context.contextBundle?.missionIntent?.intentType, .architectureAnalysis)
    }
}
