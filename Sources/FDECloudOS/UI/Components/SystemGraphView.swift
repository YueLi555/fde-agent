import SwiftUI

struct SystemGraphView: View {
    let nodes: [SystemGraphNode]
    let edges: [SystemGraphEdge]
    let events: [ExecutionEvent]

    @State private var selectedNodeID: String?
    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero

    private var selectedNode: SystemGraphNode? {
        guard let selectedNodeID else { return nil }
        return nodes.first { $0.id == selectedNodeID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if nodes.isEmpty {
                ContentUnavailableView(
                    "Graph Empty",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Run a task to materialize apps, agents, tools, events, and data-flow edges.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    graphCanvas
                        .frame(minWidth: 360, minHeight: 460)

                    GraphNodeDetailPanel(
                        node: selectedNode,
                        edges: edges,
                        events: events
                    )
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                }
            }
        }
        .padding(.top, 10)
        .onChange(of: nodes.map(\.id)) { _, nodeIDs in
            if selectedNodeID == nil || !nodeIDs.contains(selectedNodeID ?? "") {
                selectedNodeID = preferredInitialSelectionID(from: nodeIDs)
            }
        }
        .onAppear {
            selectedNodeID = selectedNodeID ?? preferredInitialSelectionID(from: nodes.map(\.id))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("System Graph")
                .font(.headline)
            Spacer()
            Label("\(nodes.count)", systemImage: "circle.hexagongrid")
            Label("\(edges.count)", systemImage: "arrow.triangle.branch")

            Divider()
                .frame(height: 16)

            Button {
                zoom = max(0.65, zoom - 0.15)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out")

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)

            Button {
                zoom = min(1.8, zoom + 0.15)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in")

            Button {
                zoom = 1
                panOffset = .zero
                dragStartOffset = .zero
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset graph viewport")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
    }

    private var graphCanvas: some View {
        GeometryReader { proxy in
            let layout = GraphLayout(nodes: nodes, viewportSize: proxy.size)

            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)

                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in edges {
                            guard let start = layout.positions[edge.fromNodeID],
                                  let end = layout.positions[edge.toNodeID] else {
                                continue
                            }
                            let isSelected = selectedNodeID.map { edge.fromNodeID == $0 || edge.toNodeID == $0 } ?? false
                            let controlX = (start.x + end.x) / 2
                            var path = Path()
                            path.move(to: start)
                            path.addCurve(
                                to: end,
                                control1: CGPoint(x: controlX, y: start.y),
                                control2: CGPoint(x: controlX, y: end.y)
                            )
                            context.stroke(
                                path,
                                with: .color(edgeColor(edge, isSelected: isSelected)),
                                lineWidth: isSelected ? 2.2 : 1.1
                            )
                        }
                    }
                    .frame(width: layout.size.width, height: layout.size.height)

                    ForEach(nodes) { node in
                        if let point = layout.positions[node.id] {
                            GraphNodeBubble(
                                node: node,
                                kind: graphDisplayKind(for: node),
                                isSelected: node.id == selectedNodeID,
                                connectedEdgeCount: connectedEdges(for: node).count
                            )
                            .position(point)
                            .onTapGesture {
                                selectedNodeID = node.id
                            }
                        }
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(panOffset)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        panOffset = CGSize(
                            width: dragStartOffset.width + value.translation.width,
                            height: dragStartOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        dragStartOffset = panOffset
                    }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func preferredInitialSelectionID(from nodeIDs: [String]) -> String? {
        nodeIDs.first { $0.hasPrefix("task:") } ?? nodeIDs.first
    }

    private func connectedEdges(for node: SystemGraphNode) -> [SystemGraphEdge] {
        edges.filter { $0.fromNodeID == node.id || $0.toNodeID == node.id }
    }

    private func edgeColor(_ edge: SystemGraphEdge, isSelected: Bool) -> Color {
        let base: Color
        switch edge.kind {
        case .dependency:
            base = .secondary
        case .executionFlow:
            base = .blue
        case .dataFlow:
            base = .green
        }
        return base.opacity(isSelected ? 0.82 : 0.28)
    }
}

private struct GraphLayout {
    let size: CGSize
    let positions: [String: CGPoint]

    init(nodes: [SystemGraphNode], viewportSize: CGSize) {
        let kinds = GraphNodeDisplayKind.allCases
        let grouped = Dictionary(grouping: nodes, by: graphDisplayKind(for:))
        let maxColumnCount = max(1, grouped.values.map(\.count).max() ?? 1)
        let width = max(viewportSize.width, CGFloat(kinds.count - 1) * 190 + 180)
        let height = max(viewportSize.height, CGFloat(maxColumnCount) * 106 + 120)
        let topMargin: CGFloat = 62
        let bottomMargin: CGFloat = 62
        let xMargin: CGFloat = 84
        let availableWidth = max(1, width - xMargin * 2)

        var positions: [String: CGPoint] = [:]
        for (columnIndex, kind) in kinds.enumerated() {
            let columnNodes = (grouped[kind] ?? []).sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title < rhs.title
                }
                return lhs.updatedAt < rhs.updatedAt
            }
            let x = xMargin + CGFloat(columnIndex) * availableWidth / CGFloat(max(1, kinds.count - 1))

            for (index, node) in columnNodes.enumerated() {
                let y: CGFloat
                if columnNodes.count == 1 {
                    y = height / 2
                } else {
                    y = topMargin + CGFloat(index) * max(1, height - topMargin - bottomMargin) / CGFloat(columnNodes.count - 1)
                }
                positions[node.id] = CGPoint(x: x, y: y)
            }
        }

        self.size = CGSize(width: width, height: height)
        self.positions = positions
    }
}

private enum GraphNodeDisplayKind: String, CaseIterable {
    case workspace = "Workspace"
    case agent = "Agent"
    case task = "Task"
    case tool = "Tool"
    case policy = "Policy/Governor"
    case event = "Event"

    var symbol: String {
        switch self {
        case .workspace: return "building.2"
        case .agent: return "person.wave.2"
        case .task: return "checklist"
        case .tool: return "terminal"
        case .policy: return "shield.lefthalf.filled"
        case .event: return "record.circle"
        }
    }

    var color: Color {
        switch self {
        case .workspace: return .teal
        case .agent: return .orange
        case .task: return .green
        case .tool: return .blue
        case .policy: return .purple
        case .event: return .secondary
        }
    }

    var width: CGFloat {
        switch self {
        case .event: return 118
        case .policy: return 150
        default: return 138
        }
    }
}

private func graphDisplayKind(for node: SystemGraphNode) -> GraphNodeDisplayKind {
    if node.id.hasPrefix("workspace:") || node.metadata["kind"] == "workspace" {
        return .workspace
    }
    if node.id.hasPrefix("tool:") {
        return .tool
    }
    if node.id.hasPrefix("agent:") {
        return node.title.localizedCaseInsensitiveContains("Policy") ? .policy : .agent
    }
    if node.id.hasPrefix("event:") {
        return isPolicyOrGovernorEvent(node) ? .policy : .event
    }
    if node.id.hasPrefix("task:") || node.type == .task {
        return .task
    }
    if node.type == .api || node.type == .app {
        return .tool
    }
    return .event
}

private func isPolicyOrGovernorEvent(_ node: SystemGraphNode) -> Bool {
    node.title.contains("POLICY")
        || node.title.contains("GOVERNOR")
        || node.metadata["governor_decision_id"] != nil
        || node.metadata["policy_delta_id"] != nil
}

private struct GraphNodeBubble: View {
    let node: SystemGraphNode
    let kind: GraphNodeDisplayKind
    let isSelected: Bool
    let connectedEdgeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .frame(width: 14)
                Text(kind.rawValue)
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 4)
                Text("\(connectedEdgeCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(shortLabel(node.title))
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.primary)
        .frame(width: kind.width, alignment: .leading)
        .frame(minHeight: 54, alignment: .leading)
        .padding(8)
        .background(kind.color.opacity(isSelected ? 0.26 : 0.13), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(kind.color.opacity(isSelected ? 0.92 : 0.48), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.16 : 0.05), radius: isSelected ? 8 : 3, y: 2)
    }

    private func shortLabel(_ value: String) -> String {
        value.count > 36 ? String(value.prefix(33)) + "..." : value
    }
}

private struct GraphNodeDetailPanel: View {
    let node: SystemGraphNode?
    let edges: [SystemGraphEdge]
    let events: [ExecutionEvent]

    private var connectedEdges: [SystemGraphEdge] {
        guard let node else { return [] }
        return edges.filter { $0.fromNodeID == node.id || $0.toNodeID == node.id }
    }

    private var relatedEventIDs: [String] {
        guard let node else { return [] }
        var ids = Set<String>()

        if node.id.hasPrefix("event:") {
            ids.insert(String(node.id.dropFirst("event:".count)))
        }

        for edge in connectedEdges {
            for nodeID in [edge.fromNodeID, edge.toNodeID] where nodeID.hasPrefix("event:") {
                ids.insert(String(nodeID.dropFirst("event:".count)))
            }
        }

        for event in events where isEvent(event, relatedTo: node) {
            ids.insert(event.id.uuidString)
        }

        return Array(ids).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Node Details")
                .font(.headline)

            if let node {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailRow(label: "Node ID", value: node.id)
                        DetailRow(label: "Node Type", value: graphDisplayKind(for: node).rawValue)
                        DetailRow(label: "Label", value: node.title)
                        DetailRow(label: "Subtitle", value: node.subtitle.isEmpty ? "none" : node.subtitle)

                        Divider()

                        Text("Related Event IDs")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if relatedEventIDs.isEmpty {
                            Text("none")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(relatedEventIDs.prefix(16), id: \.self) { eventID in
                                Text(eventID)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                        }

                        Divider()

                        Text("Connected Edges")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if connectedEdges.isEmpty {
                            Text("none")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(connectedEdges.prefix(12)) { edge in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(edge.label) · \(edge.kind.rawValue)")
                                        .font(.caption.weight(.medium))
                                    Text("\(edge.fromNodeID) → \(edge.toNodeID)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select Node", systemImage: "cursorarrow.click")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func isEvent(_ event: ExecutionEvent, relatedTo node: SystemGraphNode) -> Bool {
        let kind = graphDisplayKind(for: node)

        switch kind {
        case .workspace:
            return true
        case .task:
            guard node.id.hasPrefix("task:") else { return false }
            return event.taskID?.uuidString == String(node.id.dropFirst("task:".count))
        case .tool:
            let toolID = node.id.hasPrefix("tool:") ? String(node.id.dropFirst("tool:".count)) : node.id
            let payload = event.payload
            return payload["tool_call_id"] == toolID
                || payload["failed_tool_call_id"] == toolID
                || payload["recovery_tool_call_id"] == toolID
                || payload["command"] == node.title
                || payload["failed_command"] == node.title
                || payload["recovery_command"] == node.title
        case .policy:
            return event.type == .planGenerated
                || event.type == .policyUpdated
                || event.payload["governor_decision_id"] != nil
                || event.payload["policy_delta_id"] != nil
        case .agent:
            if node.title.localizedCaseInsensitiveContains("Recovery") {
                return event.type == .recoveryAttempted || event.type == .toolFailed
            }
            if node.title.localizedCaseInsensitiveContains("Planner") {
                return event.type == .planGenerated
            }
            return false
        case .event:
            return node.id == "event:\(event.id.uuidString)"
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
