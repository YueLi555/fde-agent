import Foundation

struct AgentConversationAssetProjection: Equatable, Sendable {
    var candidatePatches: [CandidatePatchActivitySnapshot]
    var generatedTestPlans: [GeneratedTestActivitySnapshot]
    var generatedTestArtifacts: [GeneratedTestArtifact]

    static let empty = AgentConversationAssetProjection(
        candidatePatches: [],
        generatedTestPlans: [],
        generatedTestArtifacts: []
    )
}

enum AgentConversationAssetProjector {
    static func project(
        workspaceID: UUID,
        events: [ExecutionEvent],
        candidatePatchManifests: [CandidatePatchManifest] = [],
        generatedTestArtifacts: [GeneratedTestArtifact] = []
    ) -> AgentConversationAssetProjection {
        let orderedEvents = events
            .filter { $0.workspaceID == workspaceID }
            .sorted(by: eventOrder)
        var candidatePatches: [String: CandidatePatchActivitySnapshot] = [:]
        var candidateOrder: [String: Int64] = [:]
        var generatedTests: [String: GeneratedTestActivitySnapshot] = [:]
        var generatedOrder: [String: Int64] = [:]

        for event in orderedEvents {
            if var snapshot = CandidatePatchActivitySnapshot(eventPayload: event.payload),
               let key = candidateKey(snapshot) {
                if snapshot.sourceCandidatePatchTaskID == nil,
                   event.payload["intent_type"] == MissionIntentType.candidatePatchGeneration.rawValue,
                   let taskID = event.taskID {
                    snapshot.sourceCandidatePatchTaskID = taskID.uuidString
                }
                candidatePatches[key] = candidatePatches[key]
                    .map { $0.merged(with: snapshot) }
                    ?? snapshot
                candidateOrder[key] = event.sequence
            }
            if var snapshot = GeneratedTestActivitySnapshot(eventPayload: event.payload) {
                if snapshot.planningTaskID == nil {
                    snapshot.planningTaskID = event.taskID?.uuidString
                }
                let key = snapshot.planningTaskID
                    ?? [snapshot.sourceCandidatePatchTaskID, snapshot.patchID]
                        .compactMap { $0 }
                        .joined(separator: ":")
                guard !key.isEmpty else { continue }
                generatedTests[key] = snapshot
                generatedOrder[key] = event.sequence
            }
        }

        for manifest in candidatePatchManifests {
            let snapshot = CandidatePatchActivitySnapshot(manifest: manifest)
            guard let key = candidateKey(snapshot) else { continue }
            let belongsToWorkspace = manifest.appliedBinding?.workspaceID == workspaceID
                || candidatePatches[key] != nil
            guard belongsToWorkspace else { continue }
            candidatePatches[key] = candidatePatches[key]
                .map { $0.merged(with: snapshot) }
                ?? snapshot
            candidateOrder[key] = max(candidateOrder[key] ?? 0, Int64.max - 1)
        }

        var exactGeneratedTests: [String: GeneratedTestActivitySnapshot] = [:]
        var exactGeneratedOrder: [String: Int64] = [:]
        var exactGeneratedSourceKey: [String: String] = [:]
        for (sourceKey, snapshot) in generatedTests {
            let key = snapshot.stableProjectionKey
            let order = generatedOrder[sourceKey] ?? 0
            let existingOrder = exactGeneratedOrder[key] ?? Int64.min
            let existingSourceKey = exactGeneratedSourceKey[key] ?? ""
            if order > existingOrder || (order == existingOrder && sourceKey > existingSourceKey) {
                exactGeneratedTests[key] = snapshot
                exactGeneratedOrder[key] = order
                exactGeneratedSourceKey[key] = sourceKey
            }
        }

        return AgentConversationAssetProjection(
            candidatePatches: candidatePatches
                .sorted { lhs, rhs in
                    let left = candidateOrder[lhs.key] ?? 0
                    let right = candidateOrder[rhs.key] ?? 0
                    return left == right ? lhs.key < rhs.key : left < right
                }
                .map(\.value),
            generatedTestPlans: exactGeneratedTests
                .sorted { lhs, rhs in
                    let left = exactGeneratedOrder[lhs.key] ?? 0
                    let right = exactGeneratedOrder[rhs.key] ?? 0
                    return left == right ? lhs.key < rhs.key : left < right
                }
                .map(\.value),
            generatedTestArtifacts: generatedTestArtifacts
                .filter { $0.sourceBinding.generatedTestSourceBinding.workspaceID == workspaceID }
                .sorted {
                    if $0.updatedAt == $1.updatedAt {
                        return $0.artifactID.uuidString < $1.artifactID.uuidString
                    }
                    return $0.updatedAt < $1.updatedAt
                }
        )
    }

    private static func candidateKey(_ snapshot: CandidatePatchActivitySnapshot) -> String? {
        guard let patchID = snapshot.patchID, let sandboxID = snapshot.sandboxID else {
            return nil
        }
        return "\(patchID):\(sandboxID)"
    }

    private static func eventOrder(_ lhs: ExecutionEvent, _ rhs: ExecutionEvent) -> Bool {
        if lhs.sequence == rhs.sequence {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.sequence < rhs.sequence
    }
}

extension GeneratedTestActivitySnapshot {
    var assetID: String {
        stableProjectionKey
    }
}
