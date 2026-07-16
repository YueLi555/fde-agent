import Foundation

struct SystemLearningEngine: Sendable {
    private let memoryIndexer: TaskMemoryIndexer
    private let miner: FailurePatternMiner
    private let compiler: GlobalPolicyCompiler

    init(
        memoryIndexer: TaskMemoryIndexer = TaskMemoryIndexer(),
        miner: FailurePatternMiner = FailurePatternMiner(),
        compiler: GlobalPolicyCompiler = GlobalPolicyCompiler()
    ) {
        self.memoryIndexer = memoryIndexer
        self.miner = miner
        self.compiler = compiler
    }

    func learn(
        task: FDETask,
        events: [ExecutionEvent],
        localPolicyDeltas: [ExecutionPolicyDelta],
        persistence: any PersistenceStore
    ) async throws -> GlobalExecutionPolicy {
        let memory = memoryIndexer.memory(for: task, events: events)
        try await persistence.saveTaskExecutionMemory(memory)

        let memories = try await persistence.loadTaskExecutionMemory(workspaceID: task.workspaceID)
        let profile = miner.profile(workspaceID: task.workspaceID, memories: memories)
        try await persistence.saveSystemFailureProfile(profile)

        let insights = miner.insights(workspaceID: task.workspaceID, profile: profile)
        for insight in insights {
            try await persistence.saveSystemInsight(insight)
        }

        let policy = compiler.compile(
            workspaceID: task.workspaceID,
            localPolicyDeltas: localPolicyDeltas,
            memories: memories,
            profile: profile,
            insights: insights
        )
        try await persistence.saveGlobalExecutionPolicy(policy)
        return policy
    }
}
