import AppKit
import SwiftUI

private enum Phase3AArtifactSelection: String, CaseIterable, Identifiable {
    case readiness = "Production Readiness Report"
    case evalPlan = "AI Eval Plan"

    var id: String { rawValue }
}

private enum Phase3AReviewSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case productionReadiness = "Production Readiness"
    case releaseGates = "Release Gates"
    case evalScenarios = "Eval Scenarios"
    case metrics = "Metrics"
    case failureTaxonomy = "Failure Taxonomy"
    case evidence = "Evidence"
    case exactBinding = "Exact Binding"
    case revisionHistory = "Revision History"

    var id: String { rawValue }
}

struct ProductionReadinessReviewWorkspace: View {
    let report: ProductionReadinessReport
    let evalPlan: AIEvalPlan
    let reportReviewEligibility: ProductionReadinessReviewEligibility
    let evalPlanReviewEligibility: ProductionReadinessReviewEligibility
    let onReviewReport: (ProductionReadinessReviewDecisionKind, String?) -> Void
    let onReviewEvalPlan: (ProductionReadinessReviewDecisionKind, String?) -> Void
    let onClose: () -> Void

    @State private var artifactSelection: Phase3AArtifactSelection = .readiness
    @State private var section: Phase3AReviewSection = .overview
    @State private var decision: ProductionReadinessReviewDecisionKind = .approvePlan
    @State private var instructions = ""
    @State private var showsCanonicalJSON = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Production readiness and AI eval plan")
                        .font(.title3.weight(.semibold))
                    Text("Review-only planning · No eval, rollout, or deployment authority")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: onClose)
            }
            .padding(16)

            Divider()

            HStack(spacing: 0) {
                leftSidebar
                    .frame(width: 220)
                Divider()
                centerContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector
                    .frame(width: 280)
            }

            Divider()
            reviewBar
        }
        .frame(minWidth: 1050, minHeight: 700)
        .accessibilityIdentifier("mission.readiness.workspace")
    }

    private var leftSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ARTIFACTS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Phase3AArtifactSelection.allCases) { artifact in
                Button {
                    artifactSelection = artifact
                    section = artifact == .readiness ? .overview : .evalScenarios
                } label: {
                    Label(artifact.rawValue, systemImage: artifact == .readiness ? "checklist" : "testtube.2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(7)
                .background(artifactSelection == artifact ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier(artifact == .readiness ? "mission.readiness.artifact.report" : "mission.readiness.artifact.evalPlan")
            }

            Divider()
            Text("CONTENTS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Phase3AReviewSection.allCases) { item in
                Button(item.rawValue) { section = item }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(section == item ? Color.accentColor : .primary)
                    .padding(.vertical, 3)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var centerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(section.rawValue)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button(showsCanonicalJSON ? "Show structured view" : "Canonical JSON") {
                        showsCanonicalJSON.toggle()
                    }
                    Button("Copy") { copySelectedContent() }
                }
                if showsCanonicalJSON {
                    canonicalJSON
                } else {
                    structuredContent
                }
            }
            .padding(18)
        }
        .accessibilityIdentifier("mission.readiness.content")
    }

    @ViewBuilder
    private var structuredContent: some View {
        switch section {
        case .overview:
            overview
        case .productionReadiness:
            readinessFindings
        case .releaseGates:
            releaseGates
        case .evalScenarios:
            evalScenarios
        case .metrics:
            metrics
        case .failureTaxonomy:
            failureTaxonomy
        case .evidence:
            evidence
        case .exactBinding:
            bindingDetails
        case .revisionHistory:
            revisionHistoryContent
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let revision = report.currentRevision {
                Text(revision.overallResult.rawValue)
                    .font(.title2.weight(.bold))
                Text("\(revision.blockers.count) blockers · \(revision.unknownCount) unknowns · \(revision.requiredActionCount) required actions")
                    .foregroundStyle(.secondary)
                Text("No production deployment or production validation occurred or was authorized.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Divider()
            Text("Eval execution is unavailable in Phase 3A.0. Production rollout remains unavailable.")
                .font(.callout)
            Text("Approval means approved as a future validation plan. It does not mean tests passed, evals passed, customer acceptance, deployment approval, or production approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readinessFindings: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(report.currentRevision?.findings ?? []) { finding in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(finding.area.title).font(.callout.weight(.semibold))
                        Spacer()
                        Text(finding.status.rawValue).font(.caption.weight(.semibold))
                    }
                    Text(finding.summary).font(.caption)
                    Text("Unknown: \(finding.remainingUnknown)").font(.caption).foregroundStyle(.secondary)
                    Text("Next: \(finding.recommendedNextAction)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var releaseGates: some View {
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(report.currentRevision?.releaseGates ?? []) { gate in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(gate.condition).font(.callout.weight(.semibold))
                        Spacer()
                        Text(gate.currentStatus.rawValue).font(.caption2.weight(.semibold))
                    }
                    Text("Owner: \(gate.ownerPlaceholder) · \(gate.classification.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Future verification: \(gate.futureVerificationMethod)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var evalScenarios: some View {
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(evalPlan.currentRevision?.scenarios ?? []) { scenario in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(scenario.title).font(.callout.weight(.semibold))
                        Spacer()
                        Text(scenario.verificationState.rawValue).font(.caption2.weight(.semibold))
                    }
                    Text(scenario.businessPurpose).font(.caption)
                    Text("Metrics: \(scenario.metricBindings.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var metrics: some View {
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(evalPlan.currentRevision?.metrics ?? []) { metric in
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.name).font(.callout.weight(.semibold))
                    Text(metric.definition).font(.caption)
                    Text("Calculation: \(metric.calculationMethod)").font(.caption).foregroundStyle(.secondary)
                    Text("Proposed threshold: \(metric.proposedThreshold)").font(.caption).foregroundStyle(.secondary)
                    Text("Actual result: Unavailable — not executed").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                .padding(9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var failureTaxonomy: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
            ForEach(evalPlan.currentRevision?.failureTaxonomy ?? []) { category in
                Text(category.rawValue)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var evidence: some View {
        let all = report.currentRevision?.findings.flatMap(\.supportingEvidence) ?? []
        let unique = Dictionary(grouping: all, by: \.evidenceID).compactMap(\.value.first).sorted { $0.evidenceID < $1.evidenceID }
        return LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(unique) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.sourceArtifactType).font(.callout.weight(.semibold))
                        Spacer()
                        Text(item.kind.rawValue).font(.caption2.weight(.semibold))
                    }
                    Text(item.claim).font(.caption)
                    Text(item.limitations).font(.caption).foregroundStyle(.secondary)
                    Text(item.sourceSHA256).font(.caption2.monospaced()).textSelection(.enabled)
                }
                .padding(9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var bindingDetails: some View {
        let binding = report.sourceBinding
        return VStack(alignment: .leading, spacing: 7) {
            bindingRow("Mission Run ID", binding.missionRunID.uuidString.lowercased())
            bindingRow("Workspace ID", binding.workspaceID.uuidString.lowercased())
            bindingRow("Canonical Legacy root", binding.canonicalLegacyRoot)
            bindingRow("Source snapshot", binding.sourceSnapshotID)
            bindingRow("Assessment", "\(binding.assessmentID) · \(binding.assessmentSHA256)")
            bindingRow("Candidate Patch", "\(binding.candidatePatchID.rawValue) · r\(binding.candidatePatchPlanRevision) · \(binding.candidatePatchArtifactSHA256)")
            bindingRow("Sandbox", "\(binding.sandboxID.rawValue) · \(binding.sandboxLifecycle)")
            bindingRow("Generated Test Plan", "\(binding.generatedTestPlanID.uuidString.lowercased()) · r\(binding.generatedTestPlanRevision) · \(binding.generatedTestPlanSHA256)")
            bindingRow("Generated Test Artifact", "\(binding.generatedTestArtifactID.uuidString.lowercased()) · r\(binding.generatedTestArtifactRevision) · \(binding.generatedTestArtifactSHA256)")
            bindingRow("Capability", "\(binding.normalizedCapabilityID) · \(binding.capabilityDisplayLabel)")
            bindingRow("Authenticated local session", binding.authenticatedLocalSessionID.uuidString.lowercased())
            bindingRow("App session authority", binding.appSessionID.uuidString.lowercased())
            bindingRow("Source binding SHA-256", binding.sourceBindingSHA256)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorGroup("Evidence", value: "Persisted Assessment, exact Candidate Patch, exact Generated Test Plan, and exact virtual Generated Test Artifact")
                inspectorGroup("Unknowns", value: "Runtime behavior, production traffic, model performance, thresholds, ownership, customer acceptance, and deployment prerequisites remain unverified.")
                inspectorGroup("Exact Binding", value: report.sourceBinding.sourceBindingSHA256)
                inspectorGroup("Revision History", value: revisionHistorySummary)
                inspectorGroup("Phase boundary", value: "Phase 3A.1 Eval Execution: unavailable\nPhase 3B Controlled Rollout: unavailable\nProduction Deployment: unavailable")
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .accessibilityIdentifier("mission.readiness.inspector")
    }

    private var reviewBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("Artifact", selection: $artifactSelection) {
                    ForEach(Phase3AArtifactSelection.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 290)
                Picker("Decision", selection: $decision) {
                    Text("Approve plan").tag(ProductionReadinessReviewDecisionKind.approvePlan)
                    Text("Request changes").tag(ProductionReadinessReviewDecisionKind.requestChanges)
                    Text("Reject").tag(ProductionReadinessReviewDecisionKind.reject)
                }
                .frame(width: 220)
                if decision == .requestChanges {
                    TextField("Required changes", text: $instructions)
                        .accessibilityIdentifier("mission.readiness.review.instructions")
                }
                Spacer()
                Button("Submit review") { submitReview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!reviewAvailable || (decision == .requestChanges && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("mission.readiness.review.submit")
            }
            Text("Approval is plan approval only. It never means production approved, deployment approved, tests passed, evals passed, or customer accepted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var reviewAvailable: Bool {
        artifactSelection == .readiness
            ? reportReviewEligibility.isAvailable
            : evalPlanReviewEligibility.isAvailable
    }

    private var revisionHistorySummary: String {
        let reportHistory = report.revisions.map { "Readiness r\($0.revision) · \($0.digest.sha256)" }
        let evalHistory = evalPlan.revisions.map { "Eval r\($0.revision) · \($0.digest.sha256)" }
        return (reportHistory + evalHistory).joined(separator: "\n")
    }

    private var revisionHistoryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            revisionGroup(
                title: "Production Readiness Report",
                revisions: report.revisions.map { revision in
                    let decision = report.reviewDecision(for: revision.revision)
                    return (
                        revision.revision,
                        revision.digest.sha256,
                        decision?.decision.rawValue,
                        decision?.approvalScope,
                        decision?.reviewerInstructions
                    )
                }
            )
            revisionGroup(
                title: "AI Eval Plan",
                revisions: evalPlan.revisions.map { revision in
                    let decision = evalPlan.reviewDecision(for: revision.revision)
                    return (
                        revision.revision,
                        revision.digest.sha256,
                        decision?.decision.rawValue,
                        decision?.approvalScope,
                        decision?.reviewerInstructions
                    )
                }
            )
        }
    }

    private func revisionGroup(
        title: String,
        revisions: [(Int, String, String?, String?, String?)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(revisions.enumerated()), id: \.offset) { _, revision in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Revision \(revision.0)").font(.callout.weight(.semibold))
                    Text(revision.1).font(.caption2.monospaced()).textSelection(.enabled)
                    Text("Decision: \(revision.2 ?? "Awaiting review")")
                        .font(.caption)
                    if let scope = revision.3 {
                        Text(scope).font(.caption).foregroundStyle(.secondary)
                    }
                    if let instructions = revision.4 {
                        Text("Instructions: \(instructions)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var canonicalJSON: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(canonicalJSONString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canonicalJSONString: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data?
        switch artifactSelection {
        case .readiness: data = try? encoder.encode(report)
        case .evalPlan: data = try? encoder.encode(evalPlan)
        }
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "Canonical JSON unavailable"
    }

    private func bindingRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold))
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func inspectorGroup(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold))
            Text(value).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func submitReview() {
        let note = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = note.isEmpty ? nil : note
        if artifactSelection == .readiness {
            onReviewReport(decision, value)
        } else {
            onReviewEvalPlan(decision, value)
        }
    }

    private func copySelectedContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(canonicalJSONString, forType: .string)
    }
}
