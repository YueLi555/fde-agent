import Foundation

struct FieldFeedbackEngine: Sendable {
    func insights(for task: FDETask, events: [ExecutionEvent], assessment: RealityAssessment) -> [FeedbackInsight] {
        var insights: [FeedbackInsight] = []
        insights.append(contentsOf: integrationInsights(for: task, events: events, assessment: assessment))

        let failedEvents = events.filter { $0.type == .toolFailed }

        for event in failedEvents {
            insights.append(
                FeedbackInsight(
                    id: UUID(),
                    workspaceID: task.workspaceID,
                    taskID: task.id,
                    kind: .bugReport,
                    title: "Tool failure during \(task.title)",
                    detail: event.summary,
                    createdAt: Date()
                )
            )
        }

        if assessment.realityRiskScore >= 60 {
            insights.append(
                FeedbackInsight(
                    id: UUID(),
                    workspaceID: task.workspaceID,
                    taskID: task.id,
                    kind: .productGap,
                    title: "High execution uncertainty",
                    detail: "Reality risk reached \(Int(assessment.realityRiskScore)). Mitigations: \(assessment.mitigations.joined(separator: "; "))",
                    createdAt: Date()
                )
            )
        }

        let lowercased = task.rawInput.lowercased()
        for connector in ["slack", "github", "notion", "gmail"] where lowercased.contains(connector) {
            insights.append(
                FeedbackInsight(
                    id: UUID(),
                    workspaceID: task.workspaceID,
                    taskID: task.id,
                    kind: .missingIntegration,
                    title: "\(connector.capitalized) connector readiness",
                    detail: "Task referenced \(connector), so OAuth, queue retry, and reconciliation should be validated before write operations.",
                    createdAt: Date()
                )
            )
        }

        if insights.isEmpty {
            insights.append(
                FeedbackInsight(
                    id: UUID(),
                    workspaceID: task.workspaceID,
                    taskID: task.id,
                    kind: .roadmapSuggestion,
                    title: "Capture reusable workflow template",
                    detail: "This execution completed without tool failures. Promote the plan shape into a workspace memory candidate.",
                    createdAt: Date()
                )
            )
        }

        return insights
    }

    private func integrationInsights(
        for task: FDETask,
        events: [ExecutionEvent],
        assessment: RealityAssessment
    ) -> [FeedbackInsight] {
        guard shouldAssessAIAgentIntegration(task: task, events: events) else { return [] }

        let legacyRoot = firstPayloadValue(
            in: events,
            keys: ["legacy_project_root", "project_root", "workspace_root", "root_path"]
        ) ?? "selected legacy project"
        let agentRoot = firstPayloadValue(
            in: events,
            keys: ["agent_project_root", "agent_root_path"]
        ) ?? "selected AI agent project"
        let codebaseRoles = firstPayloadValue(in: events, keys: ["codebase_roles"]) ?? "legacy_software | ai_agent"
        let inspectedSteps = unique(
            events
                .filter { $0.type == .stepExecuted }
                .map(\.summary)
        )
        let observedTools = unique(
            events
                .filter { $0.type == .toolCalled }
                .compactMap { event -> String? in
                    guard let command = event.payload["command"], !command.isEmpty else { return nil }
                    let arguments = event.payload["arguments"].flatMap { $0.isEmpty ? nil : $0 }
                    return [command, arguments].compactMap { $0 }.joined(separator: " ")
                }
        )
        let sourceReadTools = unique(
            events
                .filter { $0.type == .toolCalled || $0.type == .stepExecuted }
                .compactMap { event -> String? in
                    guard let command = event.payload["command"],
                          ["/usr/bin/head", "/bin/cat"].contains(command) else {
                        return nil
                    }
                    let arguments = event.payload["arguments"].flatMap { $0.isEmpty ? nil : $0 }
                    return [command, arguments].compactMap { $0 }.joined(separator: " ")
                }
        )
        let evidenceLevel = sourceReadTools.isEmpty
            ? "STRUCTURAL ONLY - no source content sample was read in this run."
            : "SOURCE-SAMPLED - bounded source content was read through project-scoped tools."

        let evidenceLines = [
            "Legacy root: \(legacyRoot)",
            "AI agent root: \(agentRoot)",
            "Codebases in context: \(codebaseRoles)",
            "Steps inspected: \(displayList(inspectedSteps, fallback: "runtime inspection steps"))",
            "Tools used: \(displayList(observedTools, fallback: "scoped read-only shell probes"))",
            "Source reads: \(displayList(sourceReadTools, fallback: "none captured"))"
        ]

        let assessmentDetail = """
        Integration verdict: CONDITIONALLY CONNECTABLE, NOT PRODUCTION-READY.
        Evidence level: \(evidenceLevel)
        FDE can proceed with an adapter-based integration because both the legacy project and AI agent project are in the approved scope. This run does not prove the integration is complete because it has not verified a concrete agent call boundary, written code, or run project-specific tests.

        Runtime evidence actually captured:
        \(evidenceLines.map { "- \($0)" }.joined(separator: "\n"))

        Inference boundary:
        - The verdict is a bounded planning conclusion, not proof of a working integration.
        - Recommendations below are implementation guidance until source-specific adapter code and tests are generated and executed.
        - If Source reads is "none captured", the assessment must be treated as structural triage only.

        Current capability result:
        - Can assess the two scoped projects: YES.
        - Can recommend where and how to connect them: YES.
        - Can honestly claim the legacy app is already connected to the agent: NO.
        - Can claim production readiness: NO, not until a real CLI/HTTP API/SDK/local module contract is verified and tests pass.

        Problems to resolve:
        - Identify the legacy app extension point where agent work should be invoked.
        - Identify the AI agent call boundary: CLI, local API, SDK, server endpoint, or package API.
        - Define request and response contracts, including files, prompts, errors, progress events, and artifacts.
        - Add auth/config handling for any model provider, connector, or secret without broad machine access.
        - Add integration tests or mocks that prove the legacy app can call the agent and handle failure states.
        - Keep code mutation behind explicit approval; this run only produced an assessment.

        Confidence inputs: risk \(Int(assessment.realityRiskScore)), failure probability \(Int((assessment.failureProbability * 100).rounded()))%.
        """

        let implementationDetail = """
        Implementation decision: PROCEED AFTER APPROVAL, BUT KEEP IT PROJECT-SCOPED.

        Recommended implementation path:
        1. Deep-read the legacy project entry points, routing/state layer, and UI action that should trigger agent work.
        2. Deep-read the AI agent project API surface and decide whether FDE should call it through a CLI adapter, local HTTP client, SDK wrapper, or in-process module.
        3. Create an adapter boundary in the legacy app, for example LegacyAction -> AgentIntegrationService -> AgentClient -> AgentResult.
        4. Add tests for success, model/tool failure, missing credentials, and user-cancelled approval.
        5. After customer approval, generate code changes and run verification. Without approval, deliver the assessment and implementation plan only.
        """

        let testPlanDetail = """
        Test status: REQUIRED BEFORE CLAIMING INTEGRATION SUCCESS.

        Test plan:
        - Agent client contract test: proves the selected AI agent can accept the legacy request payload and return a normalized result.
        - Legacy adapter unit test: proves the legacy app calls the agent through one adapter/service boundary instead of scattering agent calls through UI code.
        - Failure handling test: covers missing credentials, agent timeout, malformed response, and tool/model failure.
        - UI/workflow state test: proves progress, cancellation, and final artifacts are surfaced to the user.
        - Integration smoke test: runs the adapter against a mock or local agent endpoint before any live credentials are required.
        """

        var generatedInsights = [
            FeedbackInsight(
                id: UUID(),
                workspaceID: task.workspaceID,
                taskID: task.id,
                kind: .missingIntegration,
                title: "Integration assessment",
                detail: assessmentDetail,
                createdAt: Date()
            ),
            FeedbackInsight(
                id: UUID(),
                workspaceID: task.workspaceID,
                taskID: task.id,
                kind: .roadmapSuggestion,
                title: "Implementation plan",
                detail: implementationDetail,
                createdAt: Date()
            ),
            FeedbackInsight(
                id: UUID(),
                workspaceID: task.workspaceID,
                taskID: task.id,
                kind: .testPlan,
                title: "Test plan",
                detail: testPlanDetail,
                createdAt: Date()
            )
        ]

        if isApprovedImplementationTask(task) {
            generatedInsights.append(
                FeedbackInsight(
                    id: UUID(),
                    workspaceID: task.workspaceID,
                    taskID: task.id,
                    kind: .codePatch,
                    title: "Code patch",
                    detail: codePatchDetail(legacyRoot: legacyRoot, agentRoot: agentRoot),
                    createdAt: Date()
                )
            )
            generatedInsights.append(
                FeedbackInsight(
                    id: UUID(),
                    workspaceID: task.workspaceID,
                    taskID: task.id,
                    kind: .verificationReport,
                    title: "Verification report",
                    detail: verificationReportDetail,
                    createdAt: Date()
                )
            )
        }

        return generatedInsights
    }

    private func shouldAssessAIAgentIntegration(task: FDETask, events: [ExecutionEvent]) -> Bool {
        let normalized = task.rawInput.lowercased()
        let mentionsAgent = containsAny(normalized, ["ai agent", "ai-agent", "aiagent", "agent"])
        let mentionsIntegration = containsAny(
            normalized,
            ["integrate", "integration", "connect", "agent", "接入", "集成", "可以接"]
        )
        if mentionsAgent && mentionsIntegration {
            return true
        }
        return events.contains { event in
            nonEmpty(event.payload["agent_project_root"]) != nil
                || nonEmpty(event.payload["agent_root_path"]) != nil
                || (event.payload["codebase_roles"]?.contains("ai_agent") ?? false)
        }
    }

    private func isApprovedImplementationTask(_ task: FDETask) -> Bool {
        let normalized = task.rawInput.lowercased()
        return containsAny(normalized, ["approved implementation", "implementation approved", "customer approved", "批准实施", "批准写代码"])
            || containsAny(normalized, ["generate patch", "code patch", "adapter", "client", "service", "写代码", "生成 patch"])
    }

    private func codePatchDetail(legacyRoot: String, agentRoot: String) -> String {
        """
        Patch status: BLUEPRINT ONLY IN THIS RUN.
        No source files were changed, no diff was applied, and no project tests were run. This artifact defines the patch that FDE should generate next through project-scoped write tools.

        Patch scope:
        - Legacy project: \(legacyRoot)
        - AI agent project: \(agentRoot)

        Proposed patch structure:
        1. Add AgentClient protocol with a single request/response contract.
        2. Add AgentIntegrationService that converts legacy app actions into AgentClient requests.
        3. Add a concrete client for the selected agent invocation mode: CLI, HTTP API, SDK, or local module.
        4. Update the legacy extension point to call AgentIntegrationService.
        5. Add tests from the Test plan artifact before enabling live agent calls.

        Exit criteria before saying "connected":
        - A real agent invocation mode is selected and verified: CLI, HTTP API, SDK, or local module.
        - The legacy app has exactly one adapter/service boundary for agent calls.
        - Contract, failure handling, and smoke tests pass.
        - Secrets and broad local filesystem access are not required for normal operation.

        Patch application status: not applied. Apply file mutations only after the customer approves project-scoped write tools.
        """
    }

    private var verificationReportDetail: String {
        """
        Verification status: NOT VERIFIED YET.
        Patch blueprint generation completed, but this run did not prove a working integration.

        Required verification before customer handoff:
        - Run the legacy project unit tests.
        - Run the AI agent project tests.
        - Run the new integration smoke test against a mock or local agent endpoint.
        - Confirm the agent call handles success, timeout, missing credentials, malformed response, and cancellation.
        - If the project-specific test command is unknown, FDE must infer it from package manifests or ask for it before claiming the integration is complete.
        - Remaining risk: no live credentials or agent runtime should be required until mock tests pass.
        """
    }

    private func firstPayloadValue(in events: [ExecutionEvent], keys: [String]) -> String? {
        for event in events.reversed() {
            for key in keys {
                if let value = nonEmpty(event.payload[key]) {
                    return value
                }
            }
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return AgentPresentationSanitizer.safeContent(trimmed, fallback: "")
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let safe = AgentPresentationSanitizer.safeContent(value, fallback: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safe.isEmpty, seen.insert(safe).inserted else { return nil }
            return safe
        }
    }

    private func displayList(_ values: [String], fallback: String) -> String {
        let visible = values.prefix(6)
        guard !visible.isEmpty else { return fallback }
        let suffix = values.count > visible.count ? " ..." : ""
        return visible.joined(separator: "; ") + suffix
    }
}
