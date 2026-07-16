import Foundation

enum RuntimeCompletionContractKind: String, Codable, Hashable, Sendable {
    case safeSandboxAcceptance = "SAFE_SANDBOX_ACCEPTANCE"
    case planOnly = "PLAN_ONLY"
    case modification = "MODIFICATION"
    case commandExecution = "COMMAND_EXECUTION"
    case readOnlyInspection = "READ_ONLY_INSPECTION"
    case generalExecution = "GENERAL_EXECUTION"
}

struct RuntimeCompletionEvaluation: Equatable, Sendable {
    var allowed: Bool
    var reason: String
    var report: String
    var successfulCommands: [String]
    var inspectedTargets: [String]
    var changedArtifacts: [String]
    var verificationCommands: [String]
    var unresolvedErrors: [String]

    var auditPayload: [String: String] {
        [
            "completion_gate_passed": allowed ? "true" : "false",
            "completion_gate_reason": reason,
            "completion_report": report,
            "completion_commands": successfulCommands.prefix(12).joined(separator: " | "),
            "completion_inspected_targets": inspectedTargets.prefix(12).joined(separator: " | "),
            "completion_changed_artifacts": changedArtifacts.prefix(12).joined(separator: " | "),
            "completion_verification_commands": verificationCommands.prefix(12).joined(separator: " | "),
            "completion_unresolved_errors": unresolvedErrors.prefix(12).joined(separator: " | ")
        ]
    }
}

struct RuntimeCompletionContract: Sendable {
    let kind: RuntimeCompletionContractKind
    let requiresVerification: Bool

    private let normalizedInput: String

    init(input: String, intent: MissionIntent) {
        normalizedInput = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        requiresVerification = intent.constraints.contains(.runVerification)

        if Self.isExplicitPlanOnlyRequest(normalizedInput) {
            kind = .planOnly
            return
        }

        switch intent.intentType {
        case .safeSandboxAcceptance:
            kind = .safeSandboxAcceptance
        case .modifyCode, .createFeature, .refactorCode:
            kind = .modification
        case .runTests, .manageRuntime:
            kind = .commandExecution
        case .aiAgentCompatibilityAssessment, .inspectWorkspace, .architectureAnalysis, .explainCode, .generateReport:
            kind = .readOnlyInspection
        case .debugIssue:
            kind = Self.containsCommandDirective(normalizedInput) ? .commandExecution : .generalExecution
        case .answerQuestion:
            kind = intent.constraints.contains(.readOnly) ? .readOnlyInspection : .generalExecution
        case .unknown:
            kind = Self.containsCommandDirective(normalizedInput) ? .commandExecution : .generalExecution
        }
    }

    var isPlanOnly: Bool {
        kind == .planOnly
    }

    func evaluate(events: [ExecutionEvent]) -> RuntimeCompletionEvaluation {
        let orderedEvents = events.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
        let resultEvents = orderedEvents.filter(Self.isActualResultEvent)
        let successfulResults = resultEvents.filter(Self.isSuccessfulResult)
        let successfulRealResults = successfulResults.filter { event in
            guard let command = Self.command(for: event) else { return false }
            if Self.isEcho(command) {
                return kind == .commandExecution && normalizedInput.contains("echo")
            }
            return !Self.isNarrationOnlyCommand(command)
        }
        let inspectionEvents = successfulResults.filter(Self.isInspectionResult)
        let changeEvents = successfulResults.filter(Self.isNonEmptyChangeResult)
        let verificationEvents = successfulResults.filter(Self.isVerificationResult)
        let groundedAnswerEvents = orderedEvents.filter { event in
            event.payload["lifecycle_event"] == "INSPECTION_COMPLETED"
                && event.payload["grounded_answer"] == "true"
                && Self.nonEmpty(event.payload["final_answer"]) != nil
        }
        let mutationEvents = successfulResults.filter { event in
            guard let command = Self.command(for: event)?.lowercased() else { return false }
            return Self.containsAny(command, ["edit_file", "write_file", "create_file", "write_patch", "run_safe_command"])
        }
        let commandResultsWithExit = successfulResults.filter { event in
            guard event.payload["exit_code"] == "0", Self.command(for: event) != nil else {
                return false
            }
            guard let command = Self.command(for: event) else { return false }
            return !Self.isEcho(command) || normalizedInput.contains("echo")
        }
        let unresolved = Self.unresolvedFailures(in: orderedEvents)

        let successfulCommands = Self.unique(successfulRealResults.compactMap { Self.commandDescription(for: $0) })
        let inspectedTargets = Self.unique(inspectionEvents.map { Self.inspectionDetail(for: $0) })
        let changedArtifacts = Self.unique(changeEvents.map { Self.changeDetail(for: $0) })
        let verificationCommands = Self.unique(verificationEvents.compactMap { Self.commandDescription(for: $0) })
        let unresolvedErrors = Self.unique(unresolved.map { event in
            let command = Self.command(for: event).map { " [\($0)]" } ?? ""
            return "\(event.summary)\(command)"
        })

        var missing: [String] = []
        if !unresolvedErrors.isEmpty {
            missing.append("no unresolved tool or policy errors")
        }

        switch kind {
        case .safeSandboxAcceptance:
            let completion = orderedEvents.last { event in
                event.type == .taskCompleted
                    && event.payload["completion_contract"] == RuntimeCompletionContractKind.safeSandboxAcceptance.rawValue
            }
            if completion?.payload["manifest_backed"] != "true" {
                missing.append("a manifest-backed Sandbox acceptance report")
            }
            if completion?.payload["sandbox_destroyed"] != "true" {
                missing.append("confirmed Sandbox destruction")
            }
            if completion?.payload["phase_2d_1_started"] != "false" {
                missing.append("confirmation that Phase 2D.1 was not started")
            }
        case .planOnly:
            missing.append("plan-only work must remain planned and cannot enter completion")
        case .modification:
            if inspectionEvents.isEmpty {
                missing.append("a successful file inspection or code search")
            }
            if successfulRealResults.isEmpty {
                missing.append("a successful real tool result")
            }
            if changeEvents.isEmpty {
                missing.append("a non-empty source diff or created artifact")
            }
            if let firstChange = changeEvents.first,
               !inspectionEvents.contains(where: { $0.sequence < firstChange.sequence }) {
                missing.append("inspection evidence recorded before the change")
            }
            if requiresVerification {
                if verificationEvents.isEmpty {
                    missing.append("a successful build or test result")
                } else if let lastChange = changeEvents.last,
                          !verificationEvents.contains(where: { $0.sequence > lastChange.sequence }) {
                    missing.append("verification recorded after the change")
                }
            }
        case .commandExecution:
            if Self.requestsBuildOrTest(normalizedInput), verificationEvents.isEmpty {
                missing.append("a successful requested build or test result with exit status 0")
            } else if commandResultsWithExit.isEmpty {
                missing.append("a command result with exit status 0")
            }
        case .readOnlyInspection:
            if inspectionEvents.isEmpty {
                missing.append("a successful file read, workspace inspection, or code search result")
            }
            if successfulRealResults.filter({ event in
                guard let command = Self.command(for: event) else { return false }
                return ReadOnlyInspectionPolicy.allowedTools.contains(command)
                    && Self.nonEmpty(event.payload["workspace_identity"]) != nil
            }).isEmpty {
                missing.append("successful allowed read-only evidence associated with a selected workspace")
            }
            if groundedAnswerEvents.isEmpty {
                missing.append("a grounded final assistant answer linked to inspection evidence")
            }
            if !mutationEvents.isEmpty {
                missing.append("no mutating operation")
            }
        case .generalExecution:
            if successfulRealResults.isEmpty {
                missing.append("a successful real tool result")
            }
        }

        let allowed = missing.isEmpty
        let reason: String
        let report: String
        if allowed {
            reason = "Completion contract satisfied for \(kind.rawValue.lowercased())."
            report = Self.successReport(
                kind: kind,
                commands: successfulCommands,
                inspectedTargets: inspectedTargets,
                changedArtifacts: changedArtifacts,
                verificationCommands: verificationCommands
            )
        } else {
            reason = "Missing required completion evidence: \(Self.unique(missing).joined(separator: "; "))."
            report = unresolvedErrors.isEmpty
                ? reason
                : "\(reason) Unresolved errors: \(unresolvedErrors.joined(separator: " | "))."
        }

        return RuntimeCompletionEvaluation(
            allowed: allowed,
            reason: reason,
            report: report,
            successfulCommands: successfulCommands,
            inspectedTargets: inspectedTargets,
            changedArtifacts: changedArtifacts,
            verificationCommands: verificationCommands,
            unresolvedErrors: unresolvedErrors
        )
    }

    private static func isExplicitPlanOnlyRequest(_ input: String) -> Bool {
        let hasPlanDirective = containsAny(
            input,
            [
                "plan only", "planning only", "only plan", "plan how", "create a plan",
                "make a plan", "prepare a plan", "draft a plan", "implementation plan",
                "test plan", "只做计划", "仅做计划", "只制定计划", "只规划", "制定计划",
                "给我一个计划", "只要方案", "仅提供方案", "测试计划", "实施计划"
            ]
        )
        guard hasPlanDirective else { return false }

        let explicitlyForbidsExecution = containsAny(
            input,
            [
                "do not execute", "don't execute", "without executing", "no execution",
                "do not run", "don't run", "do not modify", "don't modify", "plan only",
                "planning only", "only plan", "不要执行", "无需执行", "不用执行", "先不要执行",
                "不要运行", "不要修改", "只做计划", "仅做计划", "只制定计划", "只规划",
                "只要方案", "仅提供方案"
            ]
        )
        if explicitlyForbidsExecution {
            return true
        }

        let beginsAsPlanRequest = [
            "plan ", "create a plan", "make a plan", "prepare a plan", "draft a plan",
            "give me a plan", "write a plan", "create an implementation plan",
            "prepare an implementation plan", "draft an implementation plan",
            "create a test plan", "prepare a test plan", "draft a test plan",
            "please create a plan", "please prepare a plan", "please draft a plan",
            "请制定", "请规划", "制定计划", "制定一个计划", "给我一个计划", "规划一下"
        ].contains { input.hasPrefix($0) }
        guard beginsAsPlanRequest else { return false }

        let requestsImplementation = containsAny(
            input,
            [
                "then execute", "and execute", "then run", "and run", "apply the plan",
                "implement the plan", "execute the plan", "运行这个计划", "执行这个计划",
                "然后执行", "然后运行", "按计划实施", "modify code", "modify the",
                "change code", "edit code", "edit the", "fix code", "fix the", "write code",
                "implement this", "implement the change", "apply the change", "run tests",
                "run swift", "build the project", "deploy", "修改代码", "改代码", "修改标题",
                "修复代码", "实现功能", "运行测试", "执行命令", "部署"
            ]
        )
        return !requestsImplementation
    }

    private static func containsCommandDirective(_ input: String) -> Bool {
        containsAny(
            input,
            [
                "run ", "execute ", "build", "test", "command", "deploy",
                "运行", "执行", "构建", "编译", "测试", "部署"
            ]
        )
    }

    private static func requestsBuildOrTest(_ input: String) -> Bool {
        containsAny(
            input,
            [
                "build", "run test", "run the test", "test suite", "swift test",
                "xcodebuild", "pytest", "npm test", "cargo test", "go test",
                "构建", "编译", "运行测试", "跑测试", "测试套件"
            ]
        )
    }

    private static func isActualResultEvent(_ event: ExecutionEvent) -> Bool {
        guard [
            EventType.stepExecuted,
            .connectorExecuted,
            .nodeExecutionCompleted,
            .executionResponseReceived,
            .workerTaskCompleted
        ].contains(event.type) else {
            return false
        }
        return Self.command(for: event) != nil || Self.nonEmpty(event.payload["tool_call_id"]) != nil
    }

    private static func isSuccessfulResult(_ event: ExecutionEvent) -> Bool {
        guard isActualResultEvent(event) else { return false }
        if let exitCode = event.payload["exit_code"] {
            return exitCode == "0"
        }
        return event.payload["success"] == "true"
    }

    private static func isFailedResult(_ event: ExecutionEvent) -> Bool {
        guard isActualResultEvent(event) else { return false }
        if let exitCode = event.payload["exit_code"] {
            return exitCode != "0"
        }
        return event.payload["success"] == "false"
    }

    private static func isInspectionResult(_ event: ExecutionEvent) -> Bool {
        guard isSuccessfulResult(event), let command = command(for: event)?.lowercased() else {
            return false
        }
        return containsAny(
            command,
            [
                "read_file", "readfile", "search_files", "search_code", "codesearch",
                "inspect_project", "list_directory", "codebaseintelligence.discover",
                "filemanager.readfile", "/usr/bin/head", "/bin/ls"
            ]
        )
    }

    private static func isNonEmptyChangeResult(_ event: ExecutionEvent) -> Bool {
        guard isSuccessfulResult(event), let command = command(for: event)?.lowercased() else {
            return false
        }
        let directDiff = ["diff", "patch", "file_diff", "source_diff"].contains { key in
            nonEmpty(event.payload[key]) != nil
        }
        if directDiff {
            return true
        }
        let isChangeCommand = containsAny(
            command,
            ["write_patch", "apply_patch", "write_file", "create_file", "edit_file"]
        )
        guard isChangeCommand else { return false }
        let typedArtifact = ["created_artifact", "generated_artifact", "artifact_path"].contains { key in
            nonEmpty(event.payload[key]) != nil
        }
        if typedArtifact {
            return true
        }
        if event.payload["diff_nonempty"] == "true" {
            return true
        }
        let observedResult = [event.payload["stdout"], event.payload["actual_result"]]
            .compactMap { nonEmpty($0)?.lowercased() }
            .joined(separator: " ")
        return observedResult.contains("diff_nonempty=true")
    }

    private static func isVerificationResult(_ event: ExecutionEvent) -> Bool {
        guard isSuccessfulResult(event), event.payload["exit_code"] == "0" else {
            return false
        }
        let description = commandDescription(for: event)?.lowercased() ?? ""
        return containsAny(
            description,
            [
                "swift build", "swift test", "xcodebuild", "pytest", "python -m unittest",
                "npm test", "npm run test", "pnpm test", "yarn test", "cargo test",
                "go test", "gradle test", "mvn test", "dotnet test", "build test",
                "typecheck", "lint"
            ]
        )
    }

    private static func unresolvedFailures(in events: [ExecutionEvent]) -> [ExecutionEvent] {
        let failures = events.filter { event in
            [
                EventType.toolFailed,
                .connectorFailed,
                .authorizationDenied,
                .humanRejected,
                .userApprovalRejected,
                .nodeExecutionFailed,
                .workerTaskFailed
            ].contains(event.type) || isFailedResult(event)
        }
        return failures.filter { failure in
            !isResolved(failure, in: events)
        }
    }

    private static func isResolved(_ failure: ExecutionEvent, in events: [ExecutionEvent]) -> Bool {
        if [.authorizationDenied, .humanRejected, .userApprovalRejected].contains(failure.type) {
            return false
        }
        let laterEvents = events.filter { $0.sequence > failure.sequence }
        let toolCallID = nonEmpty(failure.payload["tool_call_id"])
        let stepID = nonEmpty(failure.payload["step_id"])

        if laterEvents.contains(where: { event in
            guard isSuccessfulResult(event) else { return false }
            return (toolCallID != nil && event.payload["tool_call_id"] == toolCallID)
                || (stepID != nil && event.payload["step_id"] == stepID)
        }) {
            return true
        }

        guard let toolCallID else { return false }
        return laterEvents.contains { recovery in
            guard recovery.type == .recoveryAttempted,
                  recovery.payload["failed_tool_call_id"] == toolCallID,
                  let recoveryToolCallID = nonEmpty(recovery.payload["recovery_tool_call_id"]) else {
                return false
            }
            return laterEvents.contains { result in
                result.sequence > recovery.sequence
                    && result.payload["tool_call_id"] == recoveryToolCallID
                    && isSuccessfulResult(result)
            }
        }
    }

    private static func inspectionDetail(for event: ExecutionEvent) -> String {
        let arguments = event.payload["arguments"] ?? ""
        let argumentPath = nonEmpty(value(after: "path=", in: arguments))
            ?? nonEmpty(value(after: "file=", in: arguments))
        return argumentPath
            ?? nonEmpty(event.payload["target_path"])
            ?? command(for: event)
            ?? event.summary
    }

    private static func changeDetail(for event: ExecutionEvent) -> String {
        let arguments = event.payload["arguments"] ?? ""
        return nonEmpty(event.payload["artifact_path"])
            ?? nonEmpty(event.payload["created_artifact"])
            ?? nonEmpty(value(after: "path=", in: arguments))
            ?? nonEmpty(value(after: "file=", in: arguments))
            ?? command(for: event)
            ?? event.summary
    }

    private static func command(for event: ExecutionEvent) -> String? {
        nonEmpty(event.payload["command"]) ?? nonEmpty(event.payload["tool_name"])
    }

    private static func commandDescription(for event: ExecutionEvent) -> String? {
        guard let command = command(for: event) else { return nil }
        guard let arguments = nonEmpty(event.payload["arguments"]) else { return command }
        return "\(command) \(arguments)"
    }

    private static func isEcho(_ command: String) -> Bool {
        let normalized = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "/bin/echo" || normalized == "echo"
    }

    private static func isNarrationOnlyCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("report_validation")
    }

    private static func successReport(
        kind: RuntimeCompletionContractKind,
        commands: [String],
        inspectedTargets: [String],
        changedArtifacts: [String],
        verificationCommands: [String]
    ) -> String {
        let investigated = inspectedTargets.isEmpty
            ? "- No file inspection was required by this completion contract."
            : inspectedTargets.map { "- `\($0)`" }.joined(separator: "\n")
        let changes = changedArtifacts.isEmpty
            ? "- No files or artifacts were modified."
            : changedArtifacts.map { "- `\($0)` (non-empty change recorded)" }.joined(separator: "\n")
        let commandList = commands.isEmpty
            ? "- No command result was required."
            : commands.map { "- `\($0)` — exit status captured as successful" }.joined(separator: "\n")
        let verification = verificationCommands.isEmpty
            ? "- No build or test was requested by this contract."
            : verificationCommands.map { "- `\($0)` passed with exit status 0" }.joined(separator: "\n")
        let outcome: String
        switch kind {
        case .safeSandboxAcceptance:
            outcome = "The isolated Sandbox was created, verified from lifecycle manifests, source integrity was rechecked, and the Sandbox was destroyed without starting Phase 2D.1."
        case .modification:
            outcome = "The requested change is backed by an inspection, a non-empty diff or created artifact, and the requested post-change verification. No separate defect cause was inferred beyond those recorded results."
        case .commandExecution:
            outcome = "The requested command completed and its exit status was captured; no source-code diagnosis was requested."
        case .readOnlyInspection:
            outcome = "This was a read-only investigation. The answer is grounded in file-read/search results and no code change was recorded."
        case .generalExecution:
            outcome = "The requested operation produced a successful real tool result."
        case .planOnly:
            outcome = "Plan-only work is not executable completion."
        }

        return """
        ## Result
        Completion verified for `\(kind.rawValue)` from recorded tool results.

        ## What I investigated
        \(investigated)

        ## Root cause / outcome
        \(outcome)

        ## Files or artifacts changed
        \(changes)

        ## Commands executed
        \(commandList)

        ## Verification
        \(verification)

        ## Remaining risks
        - The completion check validates recorded local results only; planner risk notes and external systems still require separate evidence when relevant.
        """
    }

    private static func value(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker, options: [.caseInsensitive]) else { return nil }
        let suffix = text[range.upperBound...]
        if marker == "path=" || marker == "file=" {
            return suffix.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        }
        return String(suffix)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return false }
            return true
        }
    }
}
