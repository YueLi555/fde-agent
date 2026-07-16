import SwiftUI

struct RuntimeDiagnosticsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if !store.canViewDiagnostics {
            ContentUnavailableView(
                "Diagnostics Restricted",
                systemImage: "lock",
                description: Text("The active workspace role cannot view runtime diagnostics.")
            )
        } else {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DiagnosticsSection(title: "Persistence") {
                    if let workspace = store.selectedWorkspace {
                        DiagnosticRow(label: "Workspace ID", value: workspace.id.uuidString)
                        DiagnosticRow(label: "Org ID", value: workspace.orgID.uuidString)
                        DiagnosticRow(label: "Role", value: workspace.role.rawValue)
                        DiagnosticRow(label: "Legacy Root", value: workspace.localProjectRoot ?? "not selected")
                        DiagnosticRow(label: "AI Agent Root", value: workspace.localAgentProjectRoot ?? "not selected")
                        DiagnosticRow(label: "Policy Namespace", value: workspace.policyNamespace)
                        DiagnosticRow(label: "Memory Namespace", value: workspace.memoryNamespace)
                    }
                    DiagnosticRow(label: "SQLite Status", value: store.persistenceStatus)
                    DiagnosticRow(label: "Event Chain", value: store.eventChainValidationStatus)
                    DiagnosticRow(label: "Replay", value: store.replayValidationStatus)
                    DiagnosticRow(label: "Events", value: "\(store.events.count)")
                    DiagnosticRow(label: "Replay Frames", value: "\(store.replayFrames.count)")
                }

                DiagnosticsSection(title: "Model Provider") {
                    let diagnostics = store.modelProviderDiagnostics
                    DiagnosticRow(label: "Active Provider", value: diagnostics.activeProvider)
                    DiagnosticRow(label: "Fallback Reason", value: diagnostics.fallbackReason)
                    DiagnosticRow(label: "Validation", value: diagnostics.lastValidationResult)
                    DiagnosticRow(
                        label: "Last Latency",
                        value: diagnostics.lastLatencyMilliseconds.map { String(format: "%.1f ms", $0) } ?? "n/a"
                    )
                    DiagnosticRow(label: "Updated", value: diagnostics.updatedAt.formatted(date: .abbreviated, time: .standard))

                    ForEach(diagnostics.liveProviderStates, id: \.provider) { state in
                        DiagnosticRow(
                            label: state.provider,
                            value: state.liveProvider
                                ? "\(state.enabled ? "enabled" : "disabled") · \(state.reason)"
                                : "default offline provider · \(state.reason)"
                        )
                    }
                }

                DiagnosticsSection(title: "Context Compiler") {
                    let diagnostics = store.contextCompilerDiagnostics
                    DiagnosticRow(label: "Files Scanned", value: "\(diagnostics.filesScanned)")
                    DiagnosticRow(label: "Ignored Paths", value: "\(diagnostics.ignoredPathsCount)")
                    DiagnosticRow(label: "Redactions", value: "\(diagnostics.redactionsCount)")
                    DiagnosticRow(label: "Bundle Size", value: "\(diagnostics.contextBundleSizeBytes) bytes")
                    DiagnosticRow(label: "Compile Latency", value: String(format: "%.1f ms", diagnostics.lastCompileLatencyMilliseconds))
                    DiagnosticRow(label: "Passed To Planner", value: diagnostics.contextPassedToPlanner ? "true" : "false")
                    DiagnosticRow(label: "Root Path", value: diagnostics.rootPath.isEmpty ? "not compiled" : diagnostics.rootPath)
                    DiagnosticRow(label: "Compiled At", value: diagnostics.compiledAt.formatted(date: .abbreviated, time: .standard))
                }

                DiagnosticsSection(title: "Governor") {
                    if let decision = store.latestGovernorDecision {
                        DiagnosticRow(label: "Decision ID", value: decision.id.uuidString)
                        DiagnosticRow(label: "Planner Strategy", value: decision.selectedStrategy.rawValue)
                        DiagnosticRow(label: "Approved", value: decision.approved ? "true" : "false")
                        DiagnosticRow(label: "Objective", value: decision.objective.goal.rawValue)
                        DiagnosticRow(label: "Efficiency", value: String(format: "%.1f", decision.efficiencyScore.score))
                        DiagnosticRow(label: "Learning Gradient", value: String(format: "%.2f", decision.learningGradient.value))
                        DiagnosticRow(label: "Overrides", value: "\(decision.overrides.count)")
                        DiagnosticRow(label: "Summary", value: decision.summary)
                    } else {
                        EmptyDiagnosticsState(text: "No governor decision recorded")
                    }
                }

                DiagnosticsSection(title: "Global Policy") {
                    if let policy = store.latestGlobalExecutionPolicy {
                        DiagnosticRow(label: "Policy ID", value: policy.id.uuidString)
                        DiagnosticRow(label: "Retry Budget", value: "\(policy.defaultRetryBudget)")
                        DiagnosticRow(label: "Decomposition Depth", value: "\(policy.decompositionDepth)")
                        DiagnosticRow(label: "Checkpoint Before Inspection", value: policy.checkpointBeforeInspection ? "true" : "false")
                        DiagnosticTokenList(label: "Avoided Tools", values: policy.avoidedToolCommands)
                        DiagnosticMappingList(label: "Fallback Mappings", values: policy.toolPreferences)
                        DiagnosticRow(label: "Summary", value: policy.summary)
                    } else {
                        EmptyDiagnosticsState(text: "No global policy compiled")
                    }
                }

                DiagnosticsSection(title: "Latest Policy Delta") {
                    if let delta = store.latestPolicyDelta {
                        DiagnosticRow(label: "Policy Delta ID", value: delta.id.uuidString)
                        DiagnosticRow(label: "Kind", value: delta.kind.rawValue)
                        DiagnosticRow(label: "Avoid Tool", value: delta.avoidToolCommand ?? "none")
                        DiagnosticRow(label: "Fallback Tool", value: delta.replacementToolCommand ?? "none")
                        DiagnosticRow(label: "Retry Budget", value: "\(delta.retryBudget)")
                        DiagnosticRow(label: "Failure Signature", value: delta.failureSignature ?? "none")
                        DiagnosticRow(label: "Summary", value: delta.summary)
                    } else {
                        EmptyDiagnosticsState(text: "No policy delta recorded")
                    }
                }
            }
            .padding(16)
        }
        }
    }
}

private struct DiagnosticsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DiagnosticTokenList: View {
    let label: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if values.isEmpty {
                Text("none")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct DiagnosticMappingList: View {
    let label: String
    let values: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if values.isEmpty {
                Text("none")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values.keys.sorted(), id: \.self) { key in
                    Text("\(key) → \(values[key] ?? "")")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct EmptyDiagnosticsState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        let rows = rows(in: maxWidth, subviews: subviews)
        return CGSize(
            width: maxWidth,
            height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(in: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(in maxWidth: CGFloat, subviews: Subviews) -> [FlowRow] {
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = currentItems.isEmpty ? size.width : size.width + spacing

            if !currentItems.isEmpty, currentWidth + itemWidth > maxWidth {
                rows.append(FlowRow(items: currentItems, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            currentItems.append(FlowItem(index: index, size: size))
            currentWidth += currentItems.count == 1 ? size.width : size.width + spacing
            currentHeight = max(currentHeight, size.height)
        }

        if !currentItems.isEmpty {
            rows.append(FlowRow(items: currentItems, height: currentHeight))
        }

        return rows
    }

    private struct FlowRow {
        var items: [FlowItem]
        var height: CGFloat
    }

    private struct FlowItem {
        var index: Int
        var size: CGSize
    }
}
