import XCTest
@testable import FDECloudOS

final class EventPersistenceTests: XCTestCase {
    func testConcurrentAppendsInSameWorkspaceReceiveDistinctMonotonicSequences() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let first = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await first.initialize()
        try await first.saveWorkspace(workspace)
        let second = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await second.initialize()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let event = makeEvent(workspaceID: workspace.id, marker: index)
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    _ = try await store.appendEvent(event, mode: .live)
                }
            }
            try await group.waitForAll()
        }

        let events = try await first.loadEvents(workspaceID: workspace.id, taskID: nil)
        XCTAssertEqual(events.map(\.sequence), Array(1...40).map(Int64.init))
        XCTAssertEqual(Set(events.map(\.id)).count, 40)
    }

    func testConcurrentAppendsAcrossWorkspacesRemainIndependent() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstWorkspace = Workspace.default()
        let secondWorkspace = Workspace.default()
        let store = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await store.initialize()
        try await store.saveWorkspace(firstWorkspace)
        try await store.saveWorkspace(secondWorkspace)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let firstEvent = makeEvent(workspaceID: firstWorkspace.id, marker: index)
                let secondEvent = makeEvent(workspaceID: secondWorkspace.id, marker: index)
                group.addTask { _ = try await store.appendEvent(firstEvent, mode: .live) }
                group.addTask { _ = try await store.appendEvent(secondEvent, mode: .live) }
            }
            try await group.waitForAll()
        }

        let firstEvents = try await store.loadEvents(workspaceID: firstWorkspace.id, taskID: nil)
        let secondEvents = try await store.loadEvents(workspaceID: secondWorkspace.id, taskID: nil)
        XCTAssertEqual(firstEvents.map(\.sequence), Array(1...20).map(Int64.init))
        XCTAssertEqual(secondEvents.map(\.sequence), Array(1...20).map(Int64.init))
    }

    func testRestartUsesDatabaseAuthoritativeNextSequence() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let first = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await first.initialize()
        try await first.saveWorkspace(workspace)
        _ = try await first.appendEvent(makeEvent(workspaceID: workspace.id), mode: .live)

        let restarted = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await restarted.initialize()
        let appended = try await restarted.appendEvent(makeEvent(workspaceID: workspace.id), mode: .live)

        XCTAssertEqual(appended.sequence, 2)
    }

    func testStaleWriterStateCannotCauseDuplicateSequence() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let staleWriter = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await staleWriter.initialize()
        try await staleWriter.saveWorkspace(workspace)
        let currentWriter = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await currentWriter.initialize()

        _ = try await currentWriter.appendEvent(makeEvent(workspaceID: workspace.id), mode: .live)
        let second = try await staleWriter.appendEvent(makeEvent(workspaceID: workspace.id), mode: .live)

        XCTAssertEqual(second.sequence, 2)
    }

    func testStaleWorkspaceAndAllocatorMetadataReconcileUpward() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let store = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await store.initialize()
        try await store.saveWorkspace(workspace)
        _ = try await store.appendEvent(
            makeEvent(workspaceID: workspace.id, sequence: 5),
            mode: .historicalReplay
        )
        let connection = try SQLiteConnection(path: fixture.database.path)
        try connection.execute(
            "UPDATE workspaces SET last_event_seq = 1 WHERE id = ?;",
            parameters: [.text(workspace.id.uuidString)]
        )
        try connection.execute(
            "UPDATE event_sequence_allocators SET last_sequence = 1 WHERE workspace_id = ?;",
            parameters: [.text(workspace.id.uuidString)]
        )

        let restarted = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await restarted.initialize()
        let appended = try await restarted.appendEvent(makeEvent(workspaceID: workspace.id), mode: .live)
        let metadata = try sequenceMetadata(database: fixture.database, workspaceID: workspace.id)

        XCTAssertEqual(appended.sequence, 6)
        XCTAssertEqual(metadata.workspace, 6)
        XCTAssertEqual(metadata.allocator, 6)
    }

    func testHistoricalMirrorAndLiveAppendCannotCompeteForSequence() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let first = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await first.initialize()
        try await first.saveWorkspace(workspace)
        let historical = makeEvent(workspaceID: workspace.id, sequence: 1)
        _ = try await first.appendEvent(historical, mode: .historicalReplay)
        let second = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await second.initialize()
        let live = makeEvent(workspaceID: workspace.id)

        async let mirrored = first.appendEvent(historical, mode: .historicalReplay)
        async let appended = second.appendEvent(live, mode: .live)
        let (mirroredEvent, liveEvent) = try await (mirrored, appended)

        XCTAssertEqual(mirroredEvent.id, historical.id)
        XCTAssertEqual(mirroredEvent.sequence, 1)
        XCTAssertEqual(liveEvent.sequence, 2)
    }

    func testMirroringExistingEventIsIdempotent() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let store = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await store.initialize()
        try await store.saveWorkspace(workspace)
        let event = makeEvent(workspaceID: workspace.id, sequence: 1)

        let first = try await store.appendEvent(event, mode: .historicalReplay)
        let mirrored = try await store.appendEvent(event, mode: .historicalReplay)
        let events = try await store.loadEvents(workspaceID: workspace.id, taskID: nil)

        XCTAssertEqual(first, mirrored)
        XCTAssertEqual(events.count, 1)
    }

    func testDuplicateLogicalEventIDDoesNotCreateAnotherRowOrSequence() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let store = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await store.initialize()
        try await store.saveWorkspace(workspace)
        let eventID = UUID()
        let original = makeEvent(id: eventID, workspaceID: workspace.id, marker: 1)
        let retry = makeEvent(id: eventID, workspaceID: workspace.id, marker: 2)

        let persisted = try await store.appendEvent(original, mode: .live)
        let idempotentRetry = try await store.appendEvent(retry, mode: .live)
        let events = try await store.loadEvents(workspaceID: workspace.id, taskID: nil)

        XCTAssertEqual(idempotentRetry.id, persisted.id)
        XCTAssertEqual(idempotentRetry.sequence, persisted.sequence)
        XCTAssertEqual(events.count, 1)
    }

    func testTransactionRollbackLeavesNeitherInitialTaskNorSequenceMetadataPartiallyUpdated() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let store = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await store.initialize()
        try await store.saveWorkspace(workspace)
        _ = try await store.appendEvent(
            makeEvent(workspaceID: workspace.id, sequence: 1),
            mode: .historicalReplay
        )
        let task = makeTask(workspaceID: workspace.id)
        let conflict = makeEvent(workspaceID: workspace.id, taskID: task.id, sequence: 1)

        do {
            _ = try await store.appendEvent(conflict, mode: .historicalReplay, initialTask: task)
            XCTFail("Expected sequence conflict")
        } catch let error as PersistenceError {
            XCTAssertEqual(error.eventStoreFailureCategory?.rawValue, "event_sequence_conflict")
        }

        let tasks = try await store.loadTasks(workspaceID: workspace.id)
        let events = try await store.loadEvents(workspaceID: workspace.id, taskID: nil)
        let metadata = try sequenceMetadata(database: fixture.database, workspaceID: workspace.id)
        XCTAssertFalse(tasks.contains { $0.id == task.id })
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(metadata.workspace, 1)
        XCTAssertEqual(metadata.allocator, 1)
    }

    func testBoundedFreshTransactionRetrySucceedsWithoutDuplicatingLogicalEvent() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let store = try SQLitePersistenceStore(
            databaseURL: fixture.database,
            injectedSequenceConflicts: 1
        )
        try await store.initialize()
        try await store.saveWorkspace(workspace)
        let event = makeEvent(workspaceID: workspace.id)

        let appended = try await store.appendEvent(event, mode: .live)
        let events = try await store.loadEvents(workspaceID: workspace.id, taskID: nil)

        XCTAssertEqual(appended.id, event.id)
        XCTAssertEqual(appended.sequence, 1)
        XCTAssertEqual(events.count, 1)
    }

    func testExistingDatabaseMigrationIsNonDestructiveAndIdempotent() async throws {
        let fixture = try databaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = Workspace.default()
        let original = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await original.initialize()
        try await original.saveWorkspace(workspace)
        let firstID = UUID()
        let secondID = UUID()
        _ = try await original.appendEvent(
            makeEvent(id: firstID, workspaceID: workspace.id, sequence: 1),
            mode: .historicalReplay
        )
        _ = try await original.appendEvent(
            makeEvent(id: secondID, workspaceID: workspace.id, sequence: 2),
            mode: .historicalReplay
        )

        let firstRestart = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await firstRestart.initialize()
        let secondRestart = try SQLitePersistenceStore(databaseURL: fixture.database)
        try await secondRestart.initialize()
        let events = try await secondRestart.loadEvents(workspaceID: workspace.id, taskID: nil)
        let metadata = try sequenceMetadata(database: fixture.database, workspaceID: workspace.id)

        XCTAssertEqual(events.map(\.id), [firstID, secondID])
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        XCTAssertEqual(metadata.workspace, 2)
        XCTAssertEqual(metadata.allocator, 2)
    }

    func testSanitizedEventStoreFailureCategoriesDoNotExposeSQLiteDetails() {
        let failures: [(PersistenceError, String)] = [
            (.eventSequenceConflict, "event_sequence_conflict"),
            (.eventDuplicateID, "event_duplicate_id"),
            (.eventStoreUnavailable, "event_store_unavailable"),
            (.eventStoreCorrupt, "event_store_corrupt"),
            (.eventTransactionFailed, "event_transaction_failed")
        ]

        for (error, category) in failures {
            XCTAssertEqual(error.eventStoreFailureCategory?.rawValue, category)
            XCTAssertEqual(error.localizedDescription, "Event store failure: \(category)")
            XCTAssertFalse(error.localizedDescription.contains("UNIQUE constraint"))
        }
    }

    func testAssessmentDoesNotStartWhenInitialUserEventPersistenceFails() async throws {
        let runtime = InitialEventFailureRuntime()
        let coordinator = AgentRuntimeCoordinator()
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "assessment")
        let prompt = "请只读评估当前 Legacy 项目与 AI Agent 的集成兼容性，不要修改任何文件。"

        do {
            _ = try await coordinator.startMission(
                input: prompt,
                workspace: workspace,
                session: &session,
                runtime: runtime,
                userMessageID: UUID()
            )
            XCTFail("Expected initial persistence failure")
        } catch let error as PersistenceError {
            XCTAssertEqual(error.eventStoreFailureCategory, .eventStoreUnavailable)
        }

        let submissionCount = await runtime.submissionCount()
        XCTAssertEqual(submissionCount, 0)
        XCTAssertNil(session.runtimeTaskID)
    }

    @MainActor
    func testUIProjectsOneStableSanitizedEventStoreFailureCategory() {
        XCTAssertEqual(
            AppStore.eventStoreFailureCategory(for: .eventStoreUnavailable),
            "event_store_unavailable"
        )
        XCTAssertEqual(
            AppStore.eventStoreFailureCategory(for: .eventSequenceConflict),
            "event_sequence_conflict"
        )
    }

    private func databaseFixture() throws -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEEventPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("FDECloudOS.sqlite"))
    }

    private func sequenceMetadata(database: URL, workspaceID: UUID) throws -> (workspace: Int64, allocator: Int64) {
        let connection = try SQLiteConnection(path: database.path)
        let rows = try connection.query(
            """
            SELECT
                COALESCE((SELECT last_event_seq FROM workspaces WHERE id = ?), 0) AS workspace_sequence,
                COALESCE((SELECT last_sequence FROM event_sequence_allocators WHERE workspace_id = ?), 0) AS allocator_sequence;
            """,
            parameters: [.text(workspaceID.uuidString), .text(workspaceID.uuidString)]
        )
        let row = try XCTUnwrap(rows.first)
        let workspaceValue: String? = row["workspace_sequence"] ?? nil
        let allocatorValue: String? = row["allocator_sequence"] ?? nil
        return (
            Int64(workspaceValue ?? "") ?? -1,
            Int64(allocatorValue ?? "") ?? -1
        )
    }

    private func makeTask(workspaceID: UUID) -> FDETask {
        FDETask(
            id: UUID(),
            workspaceID: workspaceID,
            title: "Atomic initial task",
            rawInput: "sanitized",
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func makeEvent(
        id: UUID = UUID(),
        workspaceID: UUID,
        taskID: UUID? = nil,
        sequence: Int64 = 0,
        marker: Int = 0
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: id,
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: .stateUpdated,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(marker + 1)),
            summary: "Sanitized event",
            payload: ["marker": String(marker)]
        )
    }
}

private actor InitialEventFailureRuntime: AgentRuntimeExecuting {
    private var submissions = 0

    func submitTask(input: String, workspace: Workspace) async throws -> FDETask {
        submissions += 1
        return FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: "Unexpected task",
            rawInput: input,
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func requestStepPause(taskID: UUID, reason: String) async {}
    func resumeTask(taskID: UUID, instruction: String?) async {}
    func changeTaskApproach(taskID: UUID, instruction: String) async {}
    func stopTask(taskID: UUID, reason: String) async {}

    func recordAuditEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        throw PersistenceError.eventStoreUnavailable
    }

    func recordUserSubmissionAuditEvent(
        logicalEventID: UUID,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        throw PersistenceError.eventStoreUnavailable
    }

    func submissionCount() -> Int { submissions }
}
