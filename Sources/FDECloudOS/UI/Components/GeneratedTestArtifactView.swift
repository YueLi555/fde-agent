import AppKit
import SwiftUI

struct GeneratedTestArtifactCard: View {
    let artifact: GeneratedTestArtifact
    let onRequestChanges: ((GeneratedTestArtifact, String) -> Void)?
    let onReject: ((GeneratedTestArtifact) -> Void)?
    let onApprove: ((GeneratedTestArtifact) -> Void)?
    let reviewEligibility: GeneratedTestArtifactReviewEligibility

    @State private var selectedFile: GeneratedTestVirtualFile?
    @State private var changeInstructions = ""
    @State private var showsApprovalConfirmation = false

    private var revision: GeneratedTestArtifactRevision? { artifact.currentRevision }
    private var reviewState: GeneratedTestArtifactReviewState {
        revision.map { artifact.reviewState(for: $0.revision) } ?? .awaitingReview
    }

    var body: some View {
        card
            .sheet(item: $selectedFile) { file in
                GeneratedTestVirtualFilePreview(
                    file: file,
                    revision: revision,
                    artifact: artifact
                )
            }
            .sheet(isPresented: $showsApprovalConfirmation) {
                GeneratedTestArtifactApprovalSheet(
                    artifact: artifact,
                    revision: revision,
                    onConfirm: {
                        showsApprovalConfirmation = false
                        onApprove?(artifact)
                    },
                    onCancel: { showsApprovalConfirmation = false }
                )
                .interactiveDismissDisabled()
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let revision {
                revisionSections(revision)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generatedTests.artifact.card")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Virtual Generated Test File Artifact", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            Spacer()
            Text(reviewState.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(reviewColor)
        }
    }

    @ViewBuilder
    private func revisionSections(_ revision: GeneratedTestArtifactRevision) -> some View {
        summaryGrid(revision)
        statusBadges
        fileList(revision)
        exactBindingDetails(revision)
        generationLifecycle(revision)

        reviewControls

        phase2D3UnavailableMessage
    }

    private func summaryGrid(_ revision: GeneratedTestArtifactRevision) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: 9)],
            alignment: .leading,
            spacing: 9
        ) {
            metric("Status", revision.lifecycleStatus.rawValue)
            metric("Candidate Patch", short(artifact.sourceBinding.generatedTestSourceBinding.patchID.rawValue))
            metric("Framework", revision.framework.displayName)
            metric("Test location", revision.groundedTestLocation)
            metric("Files", String(revision.virtualFiles.count))
            metric("Scenarios", String(revision.scenarioBindings.count))
            metric("Plan coverage", coverage(revision))
            metric("Risk", revision.risk.rawValue)
            metric("Source integrity", "SHA-256 BOUND")
            metric("Approval", reviewState.rawValue)
            metric("Revision", String(revision.revision))
            metric("Phase 2D.3", "UNAVAILABLE")
        }
    }

    private func fileList(_ revision: GeneratedTestArtifactRevision) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Files")
                .font(.subheadline.weight(.semibold))
            ForEach(revision.virtualFiles) { file in
                Button {
                    selectedFile = file
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.plaintext")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.proposedRelativePath)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                            Text("\(file.operation.rawValue.uppercased()) · \(file.scenarioIDs.count) scenarios · \(reviewState.rawValue)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Open")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(9)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("generatedTests.artifact.file.open")
            }
        }
        .accessibilityIdentifier("generatedTests.artifact.fileList")
    }

    private func exactBindingDetails(_ revision: GeneratedTestArtifactRevision) -> some View {
        DisclosureGroup("Exact binding details") {
            VStack(alignment: .leading, spacing: 7) {
                artifactBindingRows(revision)
                candidatePatchBindingRows
                sourceAuthorityBindingRows
            }
            .padding(.top, 5)
        }
        .font(.caption)
    }

    private func artifactBindingRows(_ revision: GeneratedTestArtifactRevision) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            exact("Artifact ID", artifact.artifactID.uuidString.lowercased())
            exact("Artifact revision", String(revision.revision))
            exact("Artifact SHA-256", revision.digest.sha256)
            exact("Review session ID", revision.reviewSessionID?.uuidString.lowercased() ?? "UNAVAILABLE")
            exact("Generated Test Plan ID", artifact.sourceBinding.generatedTestPlanID.uuidString.lowercased())
            exact("Generated Test Plan revision", String(artifact.sourceBinding.generatedTestPlanRevision))
            exact("Generated Test Plan SHA-256", artifact.sourceBinding.generatedTestPlanSHA256)
        }
    }

    private var candidatePatchBindingRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            exact("Workspace ID", artifact.sourceBinding.generatedTestSourceBinding.workspaceID.uuidString.lowercased())
            exact("Source Candidate Patch task ID", artifact.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID.uuidString.lowercased())
            exact("Candidate Patch ID", artifact.sourceBinding.generatedTestSourceBinding.patchID.rawValue)
            exact("Candidate Patch plan ID", artifact.sourceBinding.generatedTestSourceBinding.candidatePatchPlanID.uuidString.lowercased())
            exact("Candidate Patch plan revision", String(artifact.sourceBinding.generatedTestSourceBinding.candidatePatchPlanRevision))
            exact("Candidate Patch manifest", artifact.sourceBinding.generatedTestSourceBinding.candidatePatchManifestID)
            exact("Candidate Patch artifact", artifact.sourceBinding.generatedTestSourceBinding.candidatePatchArtifactSHA256)
        }
    }

    private var sourceAuthorityBindingRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            exact("Sandbox ID", artifact.sourceBinding.generatedTestSourceBinding.sandboxID.rawValue)
            exact("Source snapshot", artifact.sourceBinding.generatedTestSourceBinding.sourceSnapshotID)
            exact("Canonical Legacy root", artifact.sourceBinding.generatedTestSourceBinding.canonicalLegacyRoot)
            exact("Capability ID", artifact.sourceBinding.generatedTestSourceBinding.normalizedCapabilityID)
            exact("Capability label", artifact.sourceBinding.generatedTestSourceBinding.capabilityDisplayLabel ?? "—")
            exact("Assessment ID", artifact.sourceBinding.generatedTestSourceBinding.validatedAssessmentID)
            exact("Validation-plan digest", artifact.sourceBinding.generatedTestSourceBinding.validationTestPlanSHA256)
            exact("Unified Diff digest", artifact.sourceBinding.generatedTestSourceBinding.unifiedDiffSHA256)
        }
    }

    private func generationLifecycle(_ revision: GeneratedTestArtifactRevision) -> some View {
        DisclosureGroup("Generation lifecycle") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(revision.generationProvenance, id: \.self) { value in
                    Text(value).font(.caption.monospaced())
                }
            }
            .padding(.top, 5)
        }
    }

    private var reviewControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Describe the exact changes needed", text: $changeInstructions, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .disabled(!reviewEligibility.isAvailable)
            HStack {
                Button("Request Changes") {
                    onRequestChanges?(artifact, changeInstructions)
                    changeInstructions = ""
                }
                .disabled(
                    !reviewEligibility.isAvailable
                        || changeInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || onRequestChanges == nil
                )
                .accessibilityIdentifier("generatedTests.artifact.requestChanges")

                Button("Reject Artifact", role: .destructive) {
                    onReject?(artifact)
                }
                .disabled(!reviewEligibility.isAvailable || onReject == nil)
                .accessibilityIdentifier("generatedTests.artifact.reject")

                Spacer()

                Button("Approve Test Artifact") {
                    showsApprovalConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!reviewEligibility.isAvailable || onApprove == nil)
                .accessibilityIdentifier("generatedTests.artifact.approve.openConfirmation")
            }
            if let unavailableReason = reviewEligibility.unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("generatedTests.artifact.review.unavailableReason")
            }
        }
    }

    private var phase2D3UnavailableMessage: some View {
        Text("Approval does not create or execute test files. Phase 2D.3 is unavailable.")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
    }

    private var statusBadges: some View {
        HStack(spacing: 6) {
            badge(GeneratedTestVirtualFile.notWritten)
            badge(GeneratedTestVirtualFile.notCompiled)
            badge(GeneratedTestVirtualFile.notExecuted)
            badge(GeneratedTestVirtualFile.behaviorNotVerified)
        }
    }

    private var reviewColor: Color {
        switch reviewState {
        case .approved: .green
        case .rejected, .changeRequested: .orange
        case .awaitingReview: .accentColor
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private func coverage(_ revision: GeneratedTestArtifactRevision) -> String {
        let total = max(artifact.sourceBinding.generatedTestSourceBinding.changedRelativePaths.count, 1)
        return "\(revision.validationPlanItemIDs.count) items · \(total) patch scope"
    }

    private func badge(_ value: String) -> some View {
        Text(value)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .foregroundStyle(.orange)
    }

    private func short(_ value: String) -> String {
        value.count > 12 ? "\(value.prefix(12))…" : value
    }

    private func exact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 176, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                copy(value)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy full \(label)")
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct GeneratedTestVirtualFilePreview: View {
    enum Section: String, CaseIterable, Identifiable {
        case content = "Content"
        case scenarios = "Scenarios"
        case evidence = "Evidence"
        case binding = "Exact Binding"

        var id: String { rawValue }
    }

    let file: GeneratedTestVirtualFile
    let revision: GeneratedTestArtifactRevision?
    let artifact: GeneratedTestArtifact
    @State private var section: Section = .content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.proposedRelativePath)
                        .font(.headline.monospaced())
                    HStack(spacing: 6) {
                        previewBadge(file.writtenStatus)
                        previewBadge(file.compiledStatus)
                        previewBadge(file.executedStatus)
                        previewBadge(file.behaviorVerificationStatus)
                    }
                }
                Spacer()
                Button("Copy Path") { copy(file.proposedRelativePath) }
                Button("Copy Source") { copy(file.sourceText) }
                Button("Done") { dismiss() }
            }

            Picker("Artifact file section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch section {
                case .content: content
                case .scenarios: scenarios
                case .evidence: evidence
                case .binding: binding
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .accessibilityIdentifier("generatedTests.artifact.file.preview")
    }

    private var content: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.sourceText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(index + 1))
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                        Text(String(line).isEmpty ? " " : String(line))
                            .foregroundStyle(sourceColor(String(line)))
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("generatedTests.artifact.file.content")
    }

    private var scenarios: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(revision?.scenarioBindings.filter { file.scenarioIDs.contains($0.scenarioID) } ?? []) { scenario in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(scenario.title).font(.headline)
                        Text(scenario.behaviorUnderTest).foregroundStyle(.secondary)
                        Text("Validation: \(scenario.validationPlanItemIDs.joined(separator: ", "))")
                            .font(.caption.monospaced())
                        Text("Blockers: \(scenario.blockerClaimIDs.joined(separator: ", "))")
                            .font(.caption.monospaced())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .accessibilityIdentifier("generatedTests.artifact.file.scenarios")
    }

    private var evidence: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(revision?.evidenceBindings.filter { file.evidencePaths.contains($0.relativePath) } ?? []) { item in
                    DisclosureGroup(item.relativePath) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.safeClaim)
                            Text("Kind: \(item.kind.rawValue)")
                            Text("SHA-256: \(item.sourceSHA256)").font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding(.top, 5)
                    }
                }
            }
        }
        .accessibilityIdentifier("generatedTests.artifact.file.evidence")
    }

    private var binding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                bindingRow("Virtual file ID", file.stableID)
                bindingRow("Source SHA-256", file.sourceSHA256)
                bindingRow("Artifact ID", artifact.artifactID.uuidString.lowercased())
                bindingRow("Artifact revision", revision.map { String($0.revision) } ?? "—")
                bindingRow("Artifact SHA-256", revision?.digest.sha256 ?? "—")
                bindingRow("Generated Test Plan ID", artifact.sourceBinding.generatedTestPlanID.uuidString.lowercased())
                bindingRow("Generated Test Plan SHA-256", artifact.sourceBinding.generatedTestPlanSHA256)
                bindingRow("Candidate Patch binding", file.candidatePatchBindingSHA256)
                bindingRow("Candidate Patch ID", artifact.sourceBinding.generatedTestSourceBinding.patchID.rawValue)
                bindingRow("Sandbox ID", artifact.sourceBinding.generatedTestSourceBinding.sandboxID.rawValue)
            }
        }
        .accessibilityIdentifier("generatedTests.artifact.file.binding")
    }

    private func bindingRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospaced()).textSelection(.enabled)
        }
    }

    private func previewBadge(_ value: String) -> some View {
        Text(value)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
    }

    private func sourceColor(_ line: String) -> Color {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("import ") || trimmed.hasPrefix("const ") || trimmed.hasPrefix("describe(") || trimmed.hasPrefix("it(") {
            return .accentColor
        }
        if trimmed.hasPrefix("//") { return .secondary }
        return .primary
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct GeneratedTestArtifactApprovalSheet: View {
    let artifact: GeneratedTestArtifact
    let revision: GeneratedTestArtifactRevision?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Approve Virtual Test Artifact", systemImage: "checkmark.shield")
                .font(.title3.weight(.semibold))
            Text("This marks only the exact immutable artifact revision for a future workflow.")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow { Text("Artifact").foregroundStyle(.secondary); Text(short(artifact.artifactID.uuidString)) }
                GridRow { Text("Revision").foregroundStyle(.secondary); Text(revision.map { String($0.revision) } ?? "—") }
                GridRow { Text("Digest").foregroundStyle(.secondary); Text(short(revision?.digest.sha256 ?? "—")) }
                GridRow { Text("Files").foregroundStyle(.secondary); Text(String(revision?.virtualFiles.count ?? 0)) }
            }
            Text("Approval does not create or execute test files. It does not run syntax checks, Build, Tests, Shell, Git, package managers, or deployment. Phase 2D.3 is unavailable.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("generatedTests.artifact.approve.cancel")
                Button("Approve Exact Artifact", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("generatedTests.artifact.approve.confirm")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func short(_ value: String) -> String {
        value.count > 12 ? "\(value.prefix(12))…" : value
    }
}
