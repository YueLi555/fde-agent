import Foundation

struct GraphSnapshot: Sendable {
    var nodes: [SystemGraphNode]
    var edges: [SystemGraphEdge]
}

struct GraphDiff: Sendable {
    var addedNodeIDs: [String]
    var addedEdgeIDs: [String]
}

struct SystemGraphEngine: Sendable {
    func buildSnapshot(workspace: Workspace, task: FDETask, output: StructuredAgentOutput, events: [ExecutionEvent]) -> GraphSnapshot {
        let now = Date()
        let taskNodeID = "task:\(task.id.uuidString)"
        var nodes: [SystemGraphNode] = [
            SystemGraphNode(
                id: "workspace:\(workspace.id.uuidString)",
                workspaceID: workspace.id,
                type: .app,
                title: workspace.name,
                subtitle: "Role: \(workspace.role.rawValue)",
                metadata: ["kind": "workspace"],
                updatedAt: now
            ),
            SystemGraphNode(
                id: taskNodeID,
                workspaceID: workspace.id,
                type: .task,
                title: task.title,
                subtitle: task.state.rawValue,
                metadata: ["risk": String(format: "%.0f", task.riskScore)],
                updatedAt: now
            )
        ]

        var edges: [SystemGraphEdge] = [
            SystemGraphEdge(
                id: "edge.workspace.\(task.id.uuidString)",
                workspaceID: workspace.id,
                fromNodeID: "workspace:\(workspace.id.uuidString)",
                toNodeID: taskNodeID,
                kind: .dependency,
                label: "owns",
                updatedAt: now
            )
        ]

        for agent in AgentKind.allCases {
            let agentID = "agent:\(agent.rawValue.replacingOccurrences(of: " ", with: "-"))"
            nodes.append(
                SystemGraphNode(
                    id: agentID,
                    workspaceID: workspace.id,
                    type: .agent,
                    title: agent.rawValue,
                    subtitle: "Runtime participant",
                    metadata: ["state": task.state.rawValue],
                    updatedAt: now
                )
            )
            edges.append(
                SystemGraphEdge(
                    id: "edge.\(agentID).\(task.id.uuidString)",
                    workspaceID: workspace.id,
                    fromNodeID: agentID,
                    toNodeID: taskNodeID,
                    kind: .executionFlow,
                    label: "acts_on",
                    updatedAt: now
                )
            )
        }

        for call in output.toolCalls {
            let toolID = "tool:\(call.id)"
            nodes.append(
                SystemGraphNode(
                    id: toolID,
                    workspaceID: workspace.id,
                    type: call.type == .shell || call.type == .appleScript ? .app : .api,
                    title: call.command,
                    subtitle: call.type.rawValue,
                    metadata: ["arguments": call.arguments.joined(separator: " ")],
                    updatedAt: now
                )
            )
            edges.append(
                SystemGraphEdge(
                    id: "edge.\(task.id.uuidString).\(call.id)",
                    workspaceID: workspace.id,
                    fromNodeID: taskNodeID,
                    toNodeID: toolID,
                    kind: .executionFlow,
                    label: "invokes",
                    updatedAt: now
                )
            )
        }

        for event in events.suffix(6) {
            let eventNodeID = "event:\(event.id.uuidString)"
            nodes.append(
                SystemGraphNode(
                    id: eventNodeID,
                    workspaceID: workspace.id,
                    type: .task,
                    title: event.type.rawValue,
                    subtitle: event.summary,
                    metadata: event.payload,
                    updatedAt: event.timestamp
                )
            )
            edges.append(
                SystemGraphEdge(
                    id: "edge.\(task.id.uuidString).event.\(event.id.uuidString)",
                    workspaceID: workspace.id,
                    fromNodeID: taskNodeID,
                    toNodeID: eventNodeID,
                    kind: .dataFlow,
                    label: "emits",
                    updatedAt: event.timestamp
                )
            )
        }

        return GraphSnapshot(nodes: nodes, edges: edges)
    }

    func diff(previous: GraphSnapshot, next: GraphSnapshot) -> GraphDiff {
        let previousNodes = Set(previous.nodes.map(\.id))
        let previousEdges = Set(previous.edges.map(\.id))
        return GraphDiff(
            addedNodeIDs: next.nodes.map(\.id).filter { !previousNodes.contains($0) },
            addedEdgeIDs: next.edges.map(\.id).filter { !previousEdges.contains($0) }
        )
    }
}
