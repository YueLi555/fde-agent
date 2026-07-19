import AppKit
import SwiftUI

struct ControlledEvalAuthorizationWorkspace: View {
    let proposal: ControlledEvalExecutionProposal
    let isReauthorization: Bool
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isReauthorization ? "Reauthorize controlled eval execution" : "Review controlled eval authorization")
                        .font(.title3.weight(.semibold))
                    Text("Creates one current-session authorization only · Does not create or execute an Eval Run")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
            }
            .padding(16)
            Divider()
            ControlledEvalScopeReview(proposal: proposal, authorization: nil)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Artifact provenance remains immutable.")
                        .font(.caption.weight(.semibold))
                    Text("Confirmation creates a 15-minute, current-app-session, single-use authorization. Final execution confirmation is still required.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isReauthorization ? "Confirm reauthorization" : "Confirm authorization review", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mission.controlledEval.reauthorize.confirm")
            }
            .padding(12)
        }
        .frame(minWidth: 1180, minHeight: 760)
        .accessibilityIdentifier("mission.controlledEval.authorization.workspace")
    }
}

struct ControlledEvalAuthorizedExecutionReviewWorkspace: View {
    let proposal: ControlledEvalExecutionProposal
    let authorization: ControlledEvalExecutionAuthorization
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review controlled eval execution")
                        .font(.title3.weight(.semibold))
                    Text("Final confirmation · Exact single-use authorization \(authorization.authorizationID.uuidString.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
            }
            .padding(16)
            Divider()
            ControlledEvalScopeReview(proposal: proposal, authorization: authorization)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Final confirmation creates and executes one exact deterministic Eval Run.")
                        .font(.caption.weight(.semibold))
                    Text("The authorization is consumed once. Duplicate or stale activation fails closed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Confirm exact Eval Run", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mission.controlledEval.authorized.confirm")
            }
            .padding(12)
        }
        .frame(minWidth: 1180, minHeight: 760)
        .accessibilityIdentifier("mission.controlledEval.authorizedExecution.workspace")
    }
}

struct ControlledEvalResultReviewAuthorizationWorkspace: View {
    let run: EvalRun
    let proposal: ControlledEvalResultReviewProposal
    let isReauthorization: Bool
    let onConfirm: () -> Void
    let onClose: () -> Void

    private var revision: EvalRunRevision? { run.currentRevision }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isReauthorization ? "Reauthorize eval result review" : "Authorize eval result review")
                        .font(.title3.weight(.semibold))
                    Text("Creates one expiring current-session review authorization · Executes zero scenarios")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        scope("Immutable result") {
                            exact("Run ID", proposal.runID.uuidString.lowercased())
                            exact("Result revision", String(proposal.resultRevision))
                            exact("Result SHA-256", proposal.resultSHA256)
                            exact("Overall result", proposal.overallResult.rawValue)
                            exact("Attempt", String(proposal.attempt))
                            exact("Metrics", String(revision?.metricResults.count ?? 0))
                            exact("Evidence records", String(revision?.evidence.count ?? 0))
                            exact("Failures", String(revision?.failures.count ?? 0))
                        }
                        scope("Execution provenance") {
                            exact("Execution authorization", proposal.executionAuthorizationID.uuidString.lowercased())
                            exact("Execution app session", proposal.executionAuthority.appSessionID.uuidString.lowercased())
                            exact("Policy SHA-256", proposal.executionPolicySHA256)
                            exact("Dataset SHA-256", proposal.datasetManifestSHA256)
                            exact("Evaluator", "\(proposal.evaluatorID) · \(proposal.evaluatorVersion)")
                            exact("Model/version", proposal.modelVersion)
                        }
                        scope("Disabled authority") {
                            Text("No Eval execution, new Run, metric change, evidence change, tools, network, credentials, production, Shell, Git, Build, Test, packages, deployment, infrastructure, or Phase 3B authority.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("EXACT LINEAGE AND CURRENT AUTHORITY")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        exact("Current app session", proposal.currentSessionAuthority.appSessionID.uuidString.lowercased())
                        exact("Authenticated local session", proposal.currentSessionAuthority.authenticatedLocalSessionID.uuidString.lowercased())
                        exact("Workspace session", proposal.currentSessionAuthority.workspaceSessionID.uuidString.lowercased())
                        exact("Workspace", proposal.executionAuthority.workspaceID.uuidString.lowercased())
                        exact("Mission Run", proposal.executionAuthority.missionRunID.uuidString.lowercased())
                        exact("Readiness Report", "\(proposal.executionAuthority.productionReadinessReportID.uuidString.lowercased()) · r\(proposal.executionAuthority.productionReadinessReportRevision)")
                        exact("Readiness SHA-256", proposal.executionAuthority.productionReadinessReportSHA256)
                        exact("AI Eval Plan", "\(proposal.executionAuthority.aiEvalPlanID.uuidString.lowercased()) · r\(proposal.executionAuthority.aiEvalPlanRevision)")
                        exact("AI Eval SHA-256", proposal.executionAuthority.aiEvalPlanSHA256)
                        exact("Candidate Patch", "\(proposal.executionAuthority.candidatePatchID.rawValue) · \(proposal.executionAuthority.readinessSourceBinding.candidatePatchArtifactSHA256)")
                        exact("Generated Test Plan", "\(proposal.executionAuthority.readinessSourceBinding.generatedTestPlanID.uuidString.lowercased()) · \(proposal.executionAuthority.readinessSourceBinding.generatedTestPlanSHA256)")
                        exact("Generated Test Artifact", "\(proposal.executionAuthority.readinessSourceBinding.generatedTestArtifactID.uuidString.lowercased()) · \(proposal.executionAuthority.readinessSourceBinding.generatedTestArtifactSHA256)")
                        exact("Review challenge", proposal.reviewChallengeID.uuidString.lowercased())
                        exact("Proposal SHA-256", proposal.proposalSHA256)
                    }
                    .padding(14)
                }
                .frame(width: 430)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Explicit confirmation creates authorization only.")
                        .font(.caption.weight(.semibold))
                    Text("A separate final decision is still required. INCONCLUSIVE remains INCONCLUSIVE.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isReauthorization ? "Confirm result-review reauthorization" : "Confirm result-review authorization", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mission.evalResults.reauthorize.confirm")
            }
            .padding(12)
        }
        .frame(minWidth: 1120, minHeight: 720)
        .accessibilityIdentifier("mission.evalResults.authorization.workspace")
    }

    private func scope<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func exact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption.weight(.semibold))
            Text(value).font(.caption2.monospaced()).textSelection(.enabled)
        }
    }
}

struct ControlledEvalBlockerWorkspace: View {
    let reason: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Controlled eval blocker").font(.title3.weight(.semibold))
                Spacer()
                Button("Close", action: onClose)
            }
            Text(reason).font(.body).textSelection(.enabled)
            Text("No Eval Run or execution authorization was created. Phase 3B and deployment remain unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 280)
        .accessibilityIdentifier("mission.controlledEval.blocker.workspace")
    }
}

private struct ControlledEvalScopeReview: View {
    let proposal: ControlledEvalExecutionProposal
    let authorization: ControlledEvalExecutionAuthorization?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text("APPROVED SCENARIOS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(proposal.requestedScenarioIDs, id: \.self) { scenarioID in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(scenarioID).font(.caption.weight(.semibold))
                            Text("\(proposal.dataset.cases.filter { $0.scenarioID == scenarioID }.count) deterministic fixture case(s)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Text("APPROVED METRICS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    ForEach(proposal.requestedMetricIDs, id: \.self) { metricID in
                        Text(metricID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .padding(12)
            }
            .frame(width: 285)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopeGroup("Dataset") {
                        row("Dataset ID", proposal.dataset.datasetID)
                        row("Manifest SHA-256", proposal.dataset.manifestSHA256)
                        row("Source", proposal.dataset.sourceKind.rawValue)
                        row("Cases", String(proposal.dataset.caseCount))
                        row("Read-only / deterministic", "Yes / Yes")
                        row("Production data / secrets", "None / None")
                    }
                    scopeGroup("Evaluator, model, and bounded limits") {
                        row("Evaluator", proposal.policy.evaluatorID)
                        row("Evaluator version", proposal.policy.evaluatorVersion)
                        row("Model/version", proposal.policy.modelVersion)
                        row("Maximum cases", String(proposal.policy.maximumCases))
                        row("Attempts per case", String(proposal.policy.maximumAttemptsPerCase))
                        row("Runtime", "\(proposal.policy.maximumRuntimeDurationMilliseconds) ms")
                        row("Token limit", String(proposal.policy.maximumTokenEstimate))
                        row("Cost limit", String(format: "%.4f", proposal.policy.maximumEstimatedCost))
                    }
                    scopeGroup("Disabled authority") {
                        row("Allowed tools", proposal.policy.allowedTools.isEmpty ? "None" : proposal.policy.allowedTools.joined(separator: ", "))
                        row("Network", proposal.policy.networkAccessAllowed ? "Enabled" : "Disabled")
                        row("Credentials", proposal.policy.credentialAccessAllowed ? "Enabled" : "Disabled")
                        row("Production", proposal.policy.productionAccessAllowed ? "Enabled" : "Disabled")
                        row("Shell / Git / Build / Test", "Disabled / Disabled / Disabled / Disabled")
                        row("Packages / deployment", "Disabled / Disabled")
                    }
                    Text("Estimated exact run: \(proposal.estimatedTokenCount) tokens · \(String(format: "%.4f", proposal.estimatedCost)) estimated cost")
                        .font(.callout.weight(.semibold))
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("EXACT IMMUTABLE PROVENANCE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    inspector("Originating Artifact app session", proposal.originatingArtifactAppSessionID.uuidString.lowercased())
                    inspector("Current action app session", proposal.currentActionAppSessionID.uuidString.lowercased())
                    inspector("Authenticated local session", proposal.authority.authenticatedLocalSessionID.uuidString.lowercased())
                    inspector("Workspace session", proposal.authority.workspaceSessionID.uuidString.lowercased())
                    inspector("Mission Run", proposal.authority.missionRunID.uuidString.lowercased())
                    inspector("Report", "\(proposal.authority.productionReadinessReportID.uuidString.lowercased()) · r\(proposal.authority.productionReadinessReportRevision)")
                    inspector("Report SHA-256", proposal.authority.productionReadinessReportSHA256)
                    inspector("Report decision", "\(proposal.authority.productionReadinessReviewDecisionID.uuidString.lowercased()) · \(proposal.authority.productionReadinessReviewDecisionSHA256)")
                    inspector("AI Eval Plan", "\(proposal.authority.aiEvalPlanID.uuidString.lowercased()) · r\(proposal.authority.aiEvalPlanRevision)")
                    inspector("AI Eval SHA-256", proposal.authority.aiEvalPlanSHA256)
                    inspector("AI Eval decision", "\(proposal.authority.aiEvalPlanReviewDecisionID.uuidString.lowercased()) · \(proposal.authority.aiEvalPlanReviewDecisionSHA256)")
                    inspector("Candidate Patch", "\(proposal.authority.candidatePatchID.rawValue) · \(proposal.authority.readinessSourceBinding.candidatePatchArtifactSHA256)")
                    inspector("Generated Test Plan", "\(proposal.authority.readinessSourceBinding.generatedTestPlanID.uuidString.lowercased()) · \(proposal.authority.readinessSourceBinding.generatedTestPlanSHA256)")
                    inspector("Generated Test Artifact", "\(proposal.authority.readinessSourceBinding.generatedTestArtifactID.uuidString.lowercased()) · \(proposal.authority.readinessSourceBinding.generatedTestArtifactSHA256)")
                    inspector("Policy SHA-256", proposal.policy.policySHA256)
                    inspector("Proposal SHA-256", proposal.proposalSHA256)
                    inspector("Authorization challenge", proposal.authorizationChallengeID.uuidString.lowercased())
                    if let authorization {
                        inspector("Authorization ID", authorization.authorizationID.uuidString.lowercased())
                        inspector("Confirmation ID", authorization.confirmationID.uuidString.lowercased())
                        inspector("Authorization SHA-256", authorization.authorizationSHA256)
                        inspector("Created", authorization.createdAt.formatted(.iso8601))
                        inspector("Expires", authorization.expiresAt.formatted(.iso8601))
                        inspector("Single-use state", authorization.isConsumed ? "Consumed" : "Available")
                    }
                }
                .padding(12)
            }
            .frame(width: 360)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        }
    }

    private func scopeGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            content()
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }

    private func inspector(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold))
            Text(value).font(.caption2.monospaced()).textSelection(.enabled)
        }
    }
}

struct ControlledEvalExecutionReviewWorkspace: View {
    let run: EvalRun
    let reviewEligibility: ProductionReadinessReviewEligibility
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review controlled eval execution")
                        .font(.title3.weight(.semibold))
                    Text("Exact bounded fixture execution · Explicit confirmation required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                scenarioList
                    .frame(width: 280)
                Divider()
                executionSummary
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                exactInspector
                    .frame(width: 320)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Confirmation authorizes only this exact deterministic Eval Run.")
                        .font(.caption.weight(.semibold))
                    Text("No tools, network, credentials, production, deployment, or customer data are authorized.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Confirm exact Eval Run", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!reviewEligibility.isAvailable)
                    .accessibilityIdentifier("mission.controlledEval.confirm")
            }
            .padding(12)
        }
        .frame(minWidth: 1120, minHeight: 720)
        .accessibilityIdentifier("mission.controlledEval.execution.workspace")
    }

    private var scenarioList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("APPROVED SCENARIOS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(run.request.requestedScenarioIDs, id: \.self) { scenarioID in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(scenarioID)
                            .font(.caption.weight(.semibold))
                        Text("\(run.request.dataset.cases.filter { $0.scenarioID == scenarioID }.count) approved fixture case(s)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var executionSummary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Dataset") {
                    row("Dataset ID", run.request.dataset.datasetID)
                    row("Source", run.request.dataset.sourceKind.rawValue)
                    row("Cases", String(run.request.dataset.caseCount))
                    row("Read-only", run.request.dataset.readOnly ? "Yes" : "No")
                    row("Manifest SHA-256", run.request.dataset.manifestSHA256)
                }
                group("Evaluator and model") {
                    row("Evaluator", run.request.policy.evaluatorID)
                    row("Evaluator version", run.request.policy.evaluatorVersion)
                    row("Model/version", run.request.policy.modelVersion)
                    row("External network", "Disabled")
                }
                group("Bounded limits") {
                    row("Maximum cases", String(run.request.policy.maximumCases))
                    row("Attempts per case", String(run.request.policy.maximumAttemptsPerCase))
                    row("Runtime", "\(run.request.policy.maximumRuntimeDurationMilliseconds) ms")
                    row("Token estimate", String(run.request.policy.maximumTokenEstimate))
                    row("Estimated cost", String(format: "%.4f", run.request.policy.maximumEstimatedCost))
                    row("Allowed tools", run.request.policy.allowedTools.isEmpty ? "None" : run.request.policy.allowedTools.joined(separator: ", "))
                    row("Stop on critical failure", run.request.policy.stopOnCriticalFailure ? "Yes" : "No")
                }
                Text("Estimated exact run: \(run.request.estimatedTokenCount) tokens · \(String(format: "%.4f", run.request.estimatedCost)) estimated cost")
                    .font(.callout.weight(.semibold))
                Text("Approval never means production approved, deployment approved, customer accepted, or rollout authorized.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(18)
        }
    }

    private var exactInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("EXACT BINDING")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                inspector("Mission Run", run.request.authority.missionRunID.uuidString.lowercased())
                inspector("Workspace", run.request.authority.workspaceID.uuidString.lowercased())
                inspector("Report", "\(run.request.authority.productionReadinessReportID.uuidString.lowercased()) · r\(run.request.authority.productionReadinessReportRevision)")
                inspector("AI Eval Plan", "\(run.request.authority.aiEvalPlanID.uuidString.lowercased()) · r\(run.request.authority.aiEvalPlanRevision)")
                inspector("Capability", run.request.authority.capabilityID)
                inspector("Policy SHA-256", run.request.policy.policySHA256)
                inspector("Dataset SHA-256", run.request.dataset.manifestSHA256)
                inspector("Authority SHA-256", run.request.authority.authoritySHA256)
                inspector("Request SHA-256", run.request.requestSHA256)
                inspector("App session", run.request.authority.appSessionID.uuidString.lowercased())
                inspector("Workspace session", run.request.authority.workspaceSessionID.uuidString.lowercased())
                if let reason = reviewEligibility.unavailableReason, !reviewEligibility.isAvailable {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }

    private func inspector(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold))
            Text(value).font(.caption2.monospaced()).textSelection(.enabled)
        }
    }
}

struct EvalResultsWorkspace: View {
    let run: EvalRun
    let reviewEligibility: ProductionReadinessReviewEligibility
    let onReview: (EvalRunReviewDecisionKind, String?) -> Void
    let onClose: () -> Void

    @State private var selectedResultID: String?
    @State private var decision: EvalRunReviewDecisionKind = .approveResults
    @State private var instructions = ""

    private var revision: EvalRunRevision? { run.currentRevision }
    private var results: [EvalScenarioResult] {
        revision?.scenarioExecutions.flatMap(\.results) ?? []
    }
    private var selectedResult: EvalScenarioResult? {
        results.first { $0.id == selectedResultID } ?? results.first
    }
    private var selectedCase: EvalDatasetCase? {
        guard let selectedResult else { return nil }
        return run.request.dataset.cases.first { $0.caseID == selectedResult.caseID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Eval Results")
                        .font(.title3.weight(.semibold))
                    Text("Immutable bounded evidence · \(revision?.overallResult.rawValue ?? EvalOverallResult.notExecuted.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(run.currentState?.displayName ?? "Unavailable")
                    .font(.caption.weight(.semibold))
                Button("Close", action: onClose)
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                resultList.frame(width: 280)
                Divider()
                resultDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                resultInspector.frame(width: 340)
            }
            Divider()
            reviewBar
        }
        .frame(minWidth: 1200, minHeight: 760)
        .onAppear { selectedResultID = selectedResult?.id }
        .accessibilityIdentifier("mission.evalResults.workspace")
    }

    private var resultList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("SCENARIOS AND CASES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(revision?.scenarioExecutions ?? []) { execution in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(execution.scenarioID).font(.caption.weight(.semibold))
                            Spacer()
                            Text(execution.outcome.rawValue).font(.caption2.weight(.semibold))
                        }
                        ForEach(execution.results) { result in
                            Button {
                                selectedResultID = result.id
                            } label: {
                                HStack {
                                    Text(result.caseID).lineLimit(2)
                                    Spacer()
                                    Text(result.outcome.rawValue)
                                }
                                .font(.caption2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .background(selectedResultID == result.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                        if !execution.unexecutedCaseIDs.isEmpty {
                            Text("Not executed: \(execution.unexecutedCaseIDs.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                }
                ForEach(revision?.unexecutedScenarioIDs ?? [], id: \.self) { scenarioID in
                    Text("\(scenarioID) · NOT_EXECUTED")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var resultDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detail("Selected input", selectedCase?.input ?? "Not executed")
                detail("Deterministic output", selectedResult?.deterministicOutput ?? "NOT_EXECUTED")
                detail("Expected behavior", selectedResult?.expectedBehavior.joined(separator: "\n") ?? "Unavailable")
                detail("Actual behavior", selectedResult?.actualBehavior ?? "NOT_EXECUTED")
                detail("Evidence", selectedResult?.evidenceReferences.joined(separator: "\n") ?? "Missing")
            }
            .padding(18)
        }
    }

    private var resultInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                metricsInspector
                failuresInspector
                evidenceInspector
                bindingInspector
                revisionInspector
                phaseBoundaryInspector
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var metricsInspector: some View {
        inspectorSection("Metrics") {
            ForEach(revision?.metricResults ?? []) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.metricID).font(.caption.weight(.semibold))
                    Text(metricSummary(metric)).font(.caption2)
                }
            }
        }
    }

    private var failuresInspector: some View {
        inspectorSection("Failures") {
            if revision?.failures.isEmpty != false { Text("None recorded").font(.caption2) }
            ForEach(revision?.failures ?? []) { failure in
                Text("\(failure.kind.rawValue): \(failure.summary)").font(.caption2)
            }
        }
    }

    private var evidenceInspector: some View {
        inspectorSection("Evidence") {
            if revision?.evidence.isEmpty != false { Text("Missing or not executed").font(.caption2) }
            ForEach(revision?.evidence ?? []) { evidence in
                Text("\(evidence.evidenceID) · \(evidence.sourceSHA256)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var bindingInspector: some View {
        inspectorSection("Exact Binding") {
            exact("Run", run.runID.uuidString.lowercased())
            exact("Revision SHA-256", revision?.digest.sha256 ?? "Unavailable")
            exact("Policy SHA-256", run.request.policy.policySHA256)
            exact("Dataset SHA-256", run.request.dataset.manifestSHA256)
            exact("Authority SHA-256", run.request.authority.authoritySHA256)
            exact("Execution authorization", run.request.executionAuthorizationID?.uuidString.lowercased() ?? "Legacy current-session preparation")
            if let decision = revision.flatMap({ run.reviewDecision(stage: .results, attempt: $0.attempt) }) {
                exact("Result review decision", decision.decision.rawValue)
                exact("Result review authorization", decision.resultReviewAuthorizationID?.uuidString.lowercased() ?? "Unavailable")
                exact("Decision SHA-256", decision.decisionSHA256)
            }
        }
    }

    private var revisionInspector: some View {
        inspectorSection("Revision History") {
            ForEach(run.revisions) { item in
                Text("r\(item.revision) · attempt \(item.attempt) · \(item.state.rawValue)\n\(item.digest.sha256)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var phaseBoundaryInspector: some View {
        inspectorSection("Phase boundary") {
            Text("Eval PASS is not production approval or deployment authorization.\nPhase 3B: unavailable\nProduction deployment: unavailable")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func metricSummary(_ metric: EvalMetricResult) -> String {
        let value = metric.observedValue.map { String($0) } ?? "missing"
        return "\(metric.outcome.rawValue) · \(value) · \(metric.proposedThreshold)"
    }

    private var reviewBar: some View {
        HStack {
            Picker("Decision", selection: $decision) {
                Text("Approve results").tag(EvalRunReviewDecisionKind.approveResults)
                Text("Request changes").tag(EvalRunReviewDecisionKind.requestChanges)
                Text("Reject results").tag(EvalRunReviewDecisionKind.rejectResults)
            }
            .frame(width: 220)
            .disabled(!reviewEligibility.isAvailable)
            if decision == .requestChanges {
                TextField("Required changes", text: $instructions)
                    .disabled(!reviewEligibility.isAvailable)
                    .accessibilityIdentifier("mission.evalResults.review.instructions")
            }
            Spacer()
            Text(ControlledEvalExecutionService.resultsApprovalScope)
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: 430, alignment: .trailing)
            Button("Submit result review") {
                let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                onReview(decision, trimmed.isEmpty ? nil : trimmed)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!reviewEligibility.isAvailable || (decision == .requestChanges && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            .accessibilityIdentifier("mission.evalResults.review.submit")
        }
        .padding(12)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(value).font(.callout).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            content()
        }
    }

    private func exact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2.weight(.semibold))
            Text(value).font(.caption2.monospaced()).textSelection(.enabled)
        }
    }
}
