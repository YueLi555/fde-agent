import Foundation

struct MemoryRetrievalRequest: Sendable {
    var workspace: Workspace
    var taskInput: String
    var taskFingerprint: String
    var recentEvents: [ExecutionEvent]

    init(
        workspace: Workspace,
        taskInput: String,
        taskFingerprint: String,
        recentEvents: [ExecutionEvent] = []
    ) {
        self.workspace = workspace
        self.taskInput = taskInput
        self.taskFingerprint = taskFingerprint
        self.recentEvents = recentEvents
    }
}

protocol MemoryRetrieving: Sendable {
    func retrieveContext(for request: MemoryRetrievalRequest) async -> EnterpriseMemoryContext
}

struct EnterpriseMemoryRetriever: MemoryRetrieving {
    var store: any EnterpriseMemoryStoring
    var limitPerBucket: Int

    init(store: any EnterpriseMemoryStoring, limitPerBucket: Int = 4) {
        self.store = store
        self.limitPerBucket = limitPerBucket
    }

    func retrieveContext(for request: MemoryRetrievalRequest) async -> EnterpriseMemoryContext {
        do {
            try await store.initialize()
            async let failures = retrieve(
                types: [.failureMemory],
                request: request,
                limit: limitPerBucket
            )
            async let fixes = retrieve(
                types: [.solutionMemory],
                request: request,
                limit: limitPerBucket
            )
            async let systemContext = retrieve(
                types: [.customerMemory, .systemMemory],
                request: request,
                limit: limitPerBucket
            )
            async let connectorHistory = retrieve(
                types: [.executionMemory],
                request: request,
                limit: limitPerBucket
            )

            return EnterpriseMemoryContext(
                previousFailures: await failures,
                successfulFixes: await fixes,
                customerSystemContext: await systemContext,
                connectorHistory: await connectorHistory
            )
        } catch {
            return .empty
        }
    }

    private func retrieve(
        types: Set<EnterpriseMemoryType>,
        request: MemoryRetrievalRequest,
        limit: Int
    ) async -> [MemoryEntry] {
        let text = [
            request.taskInput,
            request.recentEvents.compactMap { $0.payload["command"] }.joined(separator: " ")
        ]
        .joined(separator: " ")

        return (try? await store.retrieve(
            EnterpriseMemoryQuery(
                workspaceID: request.workspace.id,
                taskFingerprint: request.taskFingerprint,
                text: text,
                types: types,
                limit: limit
            )
        )) ?? []
    }
}
