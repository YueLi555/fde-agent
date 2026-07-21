import Foundation

actor SQLitePersistenceStore: PersistenceStore {
    private let connection: SQLiteConnection
    private var injectedSequenceConflictsRemaining: Int

    init(databaseURL: URL, injectedSequenceConflicts: Int = 0) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.connection = try SQLiteConnection(path: databaseURL.path)
        self.injectedSequenceConflictsRemaining = max(0, injectedSequenceConflicts)
    }

    func initialize() async throws {
        try connection.execute("""
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            org_id TEXT,
            display_name TEXT,
            role TEXT NOT NULL,
            local_data_namespace TEXT,
            policy_namespace TEXT,
            memory_namespace TEXT,
            event_namespace TEXT,
            local_project_root TEXT,
            local_agent_project_root TEXT,
            last_event_seq INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );
        """)
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN org_id TEXT;")
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN display_name TEXT;")
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN local_data_namespace TEXT;")
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN policy_namespace TEXT;")
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN memory_namespace TEXT;")
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN event_namespace TEXT;")
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN local_project_root TEXT;")
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN local_agent_project_root TEXT;")
        try? connection.execute("ALTER TABLE workspaces ADD COLUMN last_event_seq INTEGER NOT NULL DEFAULT 0;")

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS session_metadata (
            id TEXT PRIMARY KEY,
            user_session_id TEXT NOT NULL,
            subject TEXT NOT NULL,
            provider TEXT NOT NULL,
            user_state TEXT NOT NULL,
            issued_at TEXT NOT NULL,
            expires_at TEXT,
            user_updated_at TEXT NOT NULL,
            workspace_session_id TEXT,
            active_workspace_id TEXT,
            active_org_id TEXT,
            active_role TEXT,
            workspace_state TEXT,
            workspace_started_at TEXT,
            workspace_updated_at TEXT
        );
        """)

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            title TEXT NOT NULL,
            raw_input TEXT NOT NULL,
            state TEXT NOT NULL,
            plan_json TEXT NOT NULL,
            risk_score REAL NOT NULL,
            failure_probability REAL NOT NULL,
            performance_score REAL NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """)

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS execution_plans (
            plan_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            workspace_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            digest TEXT NOT NULL,
            created_at TEXT NOT NULL,
            plan_json TEXT NOT NULL,
            PRIMARY KEY (plan_id, revision)
        );
        """)
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_execution_plans_workspace_task ON execution_plans(workspace_id, task_id, created_at);"
        )

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS events (
            id TEXT PRIMARY KEY,
            parent_event_id TEXT,
            workspace_id TEXT NOT NULL,
            task_id TEXT,
            type TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            timestamp TEXT NOT NULL,
            summary TEXT NOT NULL,
            payload_json TEXT NOT NULL
        );
        """)

        try? connection.execute("ALTER TABLE events ADD COLUMN parent_event_id TEXT;")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_events_task ON events(workspace_id, task_id, sequence);")
        do {
            try connection.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_events_workspace_sequence ON events(workspace_id, sequence);")
        } catch {
            switch connection.failureKind {
            case .constraint, .corrupt:
                throw PersistenceError.eventStoreCorrupt
            case .unavailable:
                throw PersistenceError.eventStoreUnavailable
            case .other:
                throw PersistenceError.eventTransactionFailed
            }
        }
        try backfillEventParents()
        try connection.execute("""
        CREATE TABLE IF NOT EXISTS event_sequence_allocators (
            workspace_id TEXT PRIMARY KEY,
            last_sequence INTEGER NOT NULL
        );
        """)
        try reconcileEventSequences()

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS approval_requests (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            task_id TEXT,
            state TEXT NOT NULL,
            risk_level TEXT NOT NULL,
            target_kind TEXT NOT NULL,
            requested_at TEXT NOT NULL,
            request_json TEXT NOT NULL
        );
        """)

        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_approval_requests_workspace_state ON approval_requests(workspace_id, state, requested_at);"
        )

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS graph_nodes (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            metadata_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """)

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS graph_edges (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            from_node_id TEXT NOT NULL,
            to_node_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            label TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """)

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS outcomes (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            success_rate REAL NOT NULL,
            retry_rate REAL NOT NULL,
            rollback_rate REAL NOT NULL,
            human_intervention_rate REAL NOT NULL,
            integration_success_score REAL NOT NULL,
            fde_performance_score REAL NOT NULL,
            created_at TEXT NOT NULL
        );
        """)

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS feedback (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            task_id TEXT,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        """)

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS policy_deltas (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            source_task_id TEXT,
            parent_event_id TEXT,
            kind TEXT NOT NULL,
            task_fingerprint TEXT NOT NULL,
            failure_signature TEXT,
            avoid_tool_command TEXT,
            replacement_tool_command TEXT,
            retry_budget INTEGER NOT NULL,
            reorder_checkpoint_before_risky_tool INTEGER NOT NULL,
            summary TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        """)

        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_policy_deltas_workspace_fingerprint ON policy_deltas(workspace_id, task_fingerprint, created_at);"
        )

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS task_execution_memory (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            task_id TEXT NOT NULL UNIQUE,
            task_fingerprint TEXT NOT NULL,
            task_type TEXT NOT NULL,
            performance_score REAL NOT NULL,
            failure_count INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            memory_json TEXT NOT NULL
        );
        """)

        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_task_execution_memory_workspace_type ON task_execution_memory(workspace_id, task_type, created_at);"
        )

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS system_failure_profiles (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            generated_at TEXT NOT NULL,
            profile_json TEXT NOT NULL
        );
        """)

        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_system_failure_profiles_workspace ON system_failure_profiles(workspace_id, generated_at);"
        )

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS system_insights (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            task_type TEXT NOT NULL,
            failure_signature TEXT,
            frequency INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            insight_json TEXT NOT NULL
        );
        """)

        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_system_insights_workspace_type ON system_insights(workspace_id, task_type, created_at);"
        )

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS global_execution_policies (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            policy_json TEXT NOT NULL
        );
        """)

        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_global_execution_policies_workspace ON global_execution_policies(workspace_id, created_at);"
        )

        try connection.execute("""
        CREATE TABLE IF NOT EXISTS global_governor_decisions (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            selected_strategy TEXT NOT NULL,
            approved INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            decision_json TEXT NOT NULL
        );
        """)

        try connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_global_governor_decisions_workspace ON global_governor_decisions(workspace_id, created_at);"
        )
    }

    func loadWorkspaces() async throws -> [Workspace] {
        let rows = try connection.query("SELECT * FROM workspaces ORDER BY created_at ASC;")
        return try rows.map { row in
            let id = try requiredUUID(row, "id")
            return Workspace(
                id: id,
                name: try required(row, "name"),
                role: UserRole(rawValue: try required(row, "role")) ?? .fde,
                createdAt: DateCodec.decode(try required(row, "created_at")),
                orgID: optionalUUID(row, "org_id") ?? id,
                displayName: optional(row, "display_name"),
                localDataNamespace: optional(row, "local_data_namespace"),
                policyNamespace: optional(row, "policy_namespace"),
                memoryNamespace: optional(row, "memory_namespace"),
                eventNamespace: optional(row, "event_namespace"),
                localProjectRoot: optional(row, "local_project_root"),
                localAgentProjectRoot: optional(row, "local_agent_project_root")
            )
        }
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        try connection.execute(
            """
            INSERT INTO workspaces (
                id, name, org_id, display_name, role, local_data_namespace,
                policy_namespace, memory_namespace, event_namespace,
                local_project_root, local_agent_project_root, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                org_id = excluded.org_id,
                display_name = excluded.display_name,
                role = excluded.role,
                local_data_namespace = excluded.local_data_namespace,
                policy_namespace = excluded.policy_namespace,
                memory_namespace = excluded.memory_namespace,
                event_namespace = excluded.event_namespace,
                local_project_root = excluded.local_project_root,
                local_agent_project_root = excluded.local_agent_project_root,
                created_at = excluded.created_at;
            """,
            parameters: [
                .text(workspace.id.uuidString),
                .text(workspace.name),
                .text(workspace.orgID.uuidString),
                .text(workspace.displayName),
                .text(workspace.role.rawValue),
                .text(workspace.localDataNamespace),
                .text(workspace.policyNamespace),
                .text(workspace.memoryNamespace),
                .text(workspace.eventNamespace),
                workspace.localProjectRoot.map(SQLiteValue.text) ?? SQLiteValue.null,
                workspace.localAgentProjectRoot.map(SQLiteValue.text) ?? SQLiteValue.null,
                .text(DateCodec.encode(workspace.createdAt))
            ]
        )
    }

    func saveSessionMetadata(_ metadata: SessionMetadata) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO session_metadata (
                id, user_session_id, subject, provider, user_state, issued_at, expires_at,
                user_updated_at, workspace_session_id, active_workspace_id, active_org_id,
                active_role, workspace_state, workspace_started_at, workspace_updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text("active"),
                .text(metadata.userSession.id.uuidString),
                .text(metadata.userSession.subject),
                .text(metadata.userSession.provider),
                .text(metadata.userSession.state.rawValue),
                .text(DateCodec.encode(metadata.userSession.issuedAt)),
                metadata.userSession.expiresAt.map { .text(DateCodec.encode($0)) } ?? .null,
                .text(DateCodec.encode(metadata.userSession.updatedAt)),
                metadata.workspaceSession.map { .text($0.id.uuidString) } ?? .null,
                metadata.workspaceSession.map { .text($0.workspaceID.uuidString) } ?? .null,
                metadata.workspaceSession.map { .text($0.orgID.uuidString) } ?? .null,
                metadata.workspaceSession.map { .text($0.role.rawValue) } ?? .null,
                metadata.workspaceSession.map { .text($0.state.rawValue) } ?? .null,
                metadata.workspaceSession.map { .text(DateCodec.encode($0.startedAt)) } ?? .null,
                metadata.workspaceSession.map { .text(DateCodec.encode($0.updatedAt)) } ?? .null
            ]
        )
    }

    func loadSessionMetadata() async throws -> SessionMetadata? {
        let rows = try connection.query("SELECT * FROM session_metadata WHERE id = 'active' LIMIT 1;")
        guard let row = rows.first else {
            return nil
        }

        let userSession = UserSession(
            id: try requiredUUID(row, "user_session_id"),
            subject: try required(row, "subject"),
            provider: try required(row, "provider"),
            state: SessionState(rawValue: try required(row, "user_state")) ?? .signedOut,
            issuedAt: DateCodec.decode(try required(row, "issued_at")),
            expiresAt: optional(row, "expires_at").map(DateCodec.decode),
            updatedAt: DateCodec.decode(try required(row, "user_updated_at"))
        )

        let workspaceSession: WorkspaceSession?
        if let workspaceSessionID = optionalUUID(row, "workspace_session_id"),
           let workspaceID = optionalUUID(row, "active_workspace_id"),
           let orgID = optionalUUID(row, "active_org_id"),
           let roleValue = optional(row, "active_role"),
           let workspaceState = optional(row, "workspace_state"),
           let startedAt = optional(row, "workspace_started_at"),
           let updatedAt = optional(row, "workspace_updated_at") {
            workspaceSession = WorkspaceSession(
                id: workspaceSessionID,
                userSessionID: userSession.id,
                workspaceID: workspaceID,
                orgID: orgID,
                role: UserRole(rawValue: roleValue) ?? .user,
                state: SessionState(rawValue: workspaceState) ?? .signedOut,
                startedAt: DateCodec.decode(startedAt),
                updatedAt: DateCodec.decode(updatedAt)
            )
        } else {
            workspaceSession = nil
        }

        return SessionMetadata(userSession: userSession, workspaceSession: workspaceSession)
    }

    func clearSessionMetadata() async throws {
        try connection.execute("DELETE FROM session_metadata WHERE id = 'active';")
    }

    func loadTasks(workspaceID: UUID) async throws -> [FDETask] {
        let rows = try connection.query(
            "SELECT * FROM tasks WHERE workspace_id = ? ORDER BY updated_at DESC;",
            parameters: [.text(workspaceID.uuidString)]
        )
        return try rows.map { row in
            FDETask(
                id: try requiredUUID(row, "id"),
                workspaceID: try requiredUUID(row, "workspace_id"),
                title: try required(row, "title"),
                rawInput: try required(row, "raw_input"),
                state: TaskState(rawValue: try required(row, "state")) ?? .created,
                plan: try JSONCoding.decode([PlanStep].self, from: try required(row, "plan_json")),
                riskScore: try requiredDouble(row, "risk_score"),
                failureProbability: try requiredDouble(row, "failure_probability"),
                performanceScore: try requiredDouble(row, "performance_score"),
                createdAt: DateCodec.decode(try required(row, "created_at")),
                updatedAt: DateCodec.decode(try required(row, "updated_at"))
            )
        }
    }

    func saveTask(_ task: FDETask) async throws {
        try upsertTask(task)
    }

    func saveExecutionPlan(_ plan: ExecutionPlan) async throws {
        try plan.validate()
        let existing = try connection.query(
            "SELECT plan_id FROM execution_plans WHERE plan_id = ? AND revision = ? LIMIT 1;",
            parameters: [.text(plan.id.uuidString), .int(Int64(plan.revision.number))]
        )
        guard existing.isEmpty else {
            throw PersistenceError.executionPlanRevisionAlreadyExists(
                planID: plan.id,
                revision: plan.revision.number
            )
        }

        do {
            try connection.execute(
                """
                INSERT INTO execution_plans (
                    plan_id, revision, workspace_id, task_id, digest, created_at, plan_json
                )
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                parameters: [
                    .text(plan.id.uuidString),
                    .int(Int64(plan.revision.number)),
                    .text(plan.workspaceID.uuidString),
                    .text(plan.taskID.uuidString),
                    .text(plan.digest.sha256),
                    .text(DateCodec.encode(plan.createdAt)),
                    .text(try JSONCoding.encode(plan))
                ]
            )
        } catch {
            if case .constraint = connection.failureKind {
                throw PersistenceError.executionPlanRevisionAlreadyExists(
                    planID: plan.id,
                    revision: plan.revision.number
                )
            }
            throw error
        }
    }

    func loadExecutionPlans(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionPlan] {
        let rows: [[String: String?]]
        if let taskID {
            rows = try connection.query(
                "SELECT plan_id, revision, workspace_id, task_id, digest, plan_json FROM execution_plans WHERE workspace_id = ? AND task_id = ? ORDER BY created_at ASC, plan_id ASC, revision ASC;",
                parameters: [.text(workspaceID.uuidString), .text(taskID.uuidString)]
            )
        } else {
            rows = try connection.query(
                "SELECT plan_id, revision, workspace_id, task_id, digest, plan_json FROM execution_plans WHERE workspace_id = ? ORDER BY created_at ASC, plan_id ASC, revision ASC;",
                parameters: [.text(workspaceID.uuidString)]
            )
        }
        return try rows.map { row in
            let plan = try JSONCoding.decode(ExecutionPlan.self, from: try required(row, "plan_json"))
            let persistedPlanID = try requiredUUID(row, "plan_id")
            let persistedRevision = Int(try requiredInt(row, "revision"))
            let persistedWorkspaceID = try requiredUUID(row, "workspace_id")
            let persistedTaskID = try requiredUUID(row, "task_id")
            let persistedDigest = try required(row, "digest")
            let recomputedDigest = try PlanDigest.compute(plan)
            guard plan.id == persistedPlanID,
                  plan.revision.number == persistedRevision,
                  plan.workspaceID == persistedWorkspaceID,
                  plan.taskID == persistedTaskID,
                  plan.digest.sha256 == persistedDigest,
                  recomputedDigest == plan.digest else {
                throw ExecutionPlanValidationError.digestMismatch
            }
            try plan.validate()
            return plan
        }
    }

    private func upsertTask(_ task: FDETask) throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO tasks (
                id, workspace_id, title, raw_input, state, plan_json, risk_score,
                failure_probability, performance_score, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(task.id.uuidString),
                .text(task.workspaceID.uuidString),
                .text(task.title),
                .text(task.rawInput),
                .text(task.state.rawValue),
                .text(try JSONCoding.encode(task.plan)),
                .double(task.riskScore),
                .double(task.failureProbability),
                .double(task.performanceScore),
                .text(DateCodec.encode(task.createdAt)),
                .text(DateCodec.encode(task.updatedAt))
            ]
        )
    }

    func appendEvent(
        _ event: ExecutionEvent,
        mode: EventAppendMode,
        initialTask: FDETask?
    ) async throws -> ExecutionEvent {
        let maximumAttempts = mode == .live ? 2 : 1
        var attempt = 0
        while attempt < maximumAttempts {
            attempt += 1
            do {
                return try appendEventTransaction(event, mode: mode, initialTask: initialTask)
            } catch PersistenceError.eventSequenceConflict where mode == .live && attempt < maximumAttempts {
                continue
            }
        }
        throw PersistenceError.eventSequenceConflict
    }

    private func appendEventTransaction(
        _ event: ExecutionEvent,
        mode: EventAppendMode,
        initialTask: FDETask?
    ) throws -> ExecutionEvent {
        do {
            try connection.execute("BEGIN IMMEDIATE TRANSACTION;")
        } catch {
            throw categorizedTransactionError(kind: connection.failureKind)
        }

        do {
            if let existing = try loadEvent(id: event.id) {
                guard existing.workspaceID == event.workspaceID else {
                    throw PersistenceError.eventDuplicateID
                }
                try connection.execute("COMMIT;")
                return existing
            }

            let occupiedSequence = mode == .historicalReplay
                ? try connection.query(
                    "SELECT id FROM events WHERE workspace_id = ? AND sequence = ? LIMIT 1;",
                    parameters: [.text(event.workspaceID.uuidString), .int(event.sequence)]
                ).first
                : nil
            if occupiedSequence != nil {
                throw PersistenceError.eventSequenceConflict
            }

            let storedSequence: Int64
            switch mode {
            case .live:
                let current = try authoritativeSequence(workspaceID: event.workspaceID)
                guard current < Int64.max else {
                    throw PersistenceError.eventTransactionFailed
                }
                storedSequence = current + 1
            case .historicalReplay:
                guard event.sequence > 0 else {
                    throw PersistenceError.eventTransactionFailed
                }
                storedSequence = event.sequence
            }

            if injectedSequenceConflictsRemaining > 0 {
                injectedSequenceConflictsRemaining -= 1
                throw PersistenceError.eventSequenceConflict
            }

            var storedEvent = event
            storedEvent.sequence = storedSequence
            if let initialTask {
                guard initialTask.id == storedEvent.taskID,
                      initialTask.workspaceID == storedEvent.workspaceID else {
                    throw PersistenceError.eventTransactionFailed
                }
                try upsertTask(initialTask)
            }
            try insertEvent(storedEvent)
            let authoritative = max(
                storedSequence,
                try authoritativeSequence(workspaceID: storedEvent.workspaceID)
            )
            try persistSequenceMetadata(workspaceID: storedEvent.workspaceID, sequence: authoritative)
            try connection.execute("COMMIT;")
            return storedEvent
        } catch {
            let kind = connection.failureKind
            try? connection.execute("ROLLBACK;")
            if let persistenceError = error as? PersistenceError,
               persistenceError.isSanitizedEventStoreFailure {
                throw persistenceError
            }
            throw categorizedTransactionError(kind: kind)
        }
    }

    private func insertEvent(_ event: ExecutionEvent) throws {
        try connection.execute(
            """
            INSERT INTO events (
                id, parent_event_id, workspace_id, task_id, type, sequence, timestamp, summary, payload_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(event.id.uuidString),
                event.parentEventID.map { .text($0.uuidString) } ?? .null,
                .text(event.workspaceID.uuidString),
                event.taskID.map { .text($0.uuidString) } ?? .null,
                .text(event.type.rawValue),
                .int(event.sequence),
                .text(DateCodec.encode(event.timestamp)),
                .text(event.summary),
                .text(try JSONCoding.encode(event.payload))
            ]
        )
    }

    func loadEvents(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionEvent] {
        let rows: [[String: String?]]
        if let taskID {
            rows = try connection.query(
                "SELECT * FROM events WHERE workspace_id = ? AND task_id = ? ORDER BY sequence ASC, id ASC;",
                parameters: [.text(workspaceID.uuidString), .text(taskID.uuidString)]
            )
        } else {
            rows = try connection.query(
                "SELECT * FROM events WHERE workspace_id = ? ORDER BY sequence ASC, id ASC;",
                parameters: [.text(workspaceID.uuidString)]
            )
        }

        return try rows.map { row in
            let taskValue = row["task_id"] ?? nil
            let parentValue = row["parent_event_id"] ?? nil
            return ExecutionEvent(
                id: try requiredUUID(row, "id"),
                parentEventID: parentValue.flatMap(UUID.init(uuidString:)),
                workspaceID: try requiredUUID(row, "workspace_id"),
                taskID: taskValue.flatMap(UUID.init(uuidString:)),
                type: EventType(rawValue: try required(row, "type")) ?? .stateUpdated,
                sequence: try requiredInt(row, "sequence"),
                timestamp: DateCodec.decode(try required(row, "timestamp")),
                summary: try required(row, "summary"),
                payload: try JSONCoding.decode([String: String].self, from: try required(row, "payload_json"))
            )
        }
    }

    func saveApprovalRequest(_ request: ApprovalRequest) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO approval_requests (
                id, workspace_id, task_id, state, risk_level, target_kind, requested_at, request_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(request.id.uuidString),
                .text(request.workspaceID.uuidString),
                request.taskID.map { .text($0.uuidString) } ?? .null,
                .text(request.state.rawValue),
                .text(request.riskLevel.rawValue),
                .text(request.targetKind.rawValue),
                .text(DateCodec.encode(request.requestedAt)),
                .text(try JSONCoding.encode(request))
            ]
        )
    }

    func loadApprovalRequest(id: UUID) async throws -> ApprovalRequest? {
        let rows = try connection.query(
            "SELECT request_json FROM approval_requests WHERE id = ? LIMIT 1;",
            parameters: [.text(id.uuidString)]
        )
        guard let row = rows.first else {
            return nil
        }
        return try JSONCoding.decode(ApprovalRequest.self, from: try required(row, "request_json"))
    }

    func loadApprovalRequests(workspaceID: UUID?, state: ApprovalState?) async throws -> [ApprovalRequest] {
        var conditions: [String] = []
        var parameters: [SQLiteValue] = []

        if let workspaceID {
            conditions.append("workspace_id = ?")
            parameters.append(.text(workspaceID.uuidString))
        }
        if let state {
            conditions.append("state = ?")
            parameters.append(.text(state.rawValue))
        }

        let whereClause = conditions.isEmpty ? "" : " WHERE \(conditions.joined(separator: " AND "))"
        let rows = try connection.query(
            "SELECT request_json FROM approval_requests\(whereClause) ORDER BY requested_at ASC;",
            parameters: parameters
        )
        return try rows.map { row in
            try JSONCoding.decode(ApprovalRequest.self, from: try required(row, "request_json"))
        }
    }

    func saveGraph(nodes: [SystemGraphNode], edges: [SystemGraphEdge]) async throws {
        for node in nodes {
            try connection.execute(
                """
                INSERT OR REPLACE INTO graph_nodes (
                    id, workspace_id, type, title, subtitle, metadata_json, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                parameters: [
                    .text(node.id),
                    .text(node.workspaceID.uuidString),
                    .text(node.type.rawValue),
                    .text(node.title),
                    .text(node.subtitle),
                    .text(try JSONCoding.encode(node.metadata)),
                    .text(DateCodec.encode(node.updatedAt))
                ]
            )
        }

        for edge in edges {
            try connection.execute(
                """
                INSERT OR REPLACE INTO graph_edges (
                    id, workspace_id, from_node_id, to_node_id, kind, label, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                parameters: [
                    .text(edge.id),
                    .text(edge.workspaceID.uuidString),
                    .text(edge.fromNodeID),
                    .text(edge.toNodeID),
                    .text(edge.kind.rawValue),
                    .text(edge.label),
                    .text(DateCodec.encode(edge.updatedAt))
                ]
            )
        }
    }

    func loadGraph(workspaceID: UUID) async throws -> ([SystemGraphNode], [SystemGraphEdge]) {
        let nodeRows = try connection.query(
            "SELECT * FROM graph_nodes WHERE workspace_id = ? ORDER BY updated_at DESC;",
            parameters: [.text(workspaceID.uuidString)]
        )
        let edgeRows = try connection.query(
            "SELECT * FROM graph_edges WHERE workspace_id = ? ORDER BY updated_at DESC;",
            parameters: [.text(workspaceID.uuidString)]
        )

        let nodes = try nodeRows.map { row in
            SystemGraphNode(
                id: try required(row, "id"),
                workspaceID: try requiredUUID(row, "workspace_id"),
                type: GraphNodeType(rawValue: try required(row, "type")) ?? .task,
                title: try required(row, "title"),
                subtitle: try required(row, "subtitle"),
                metadata: try JSONCoding.decode([String: String].self, from: try required(row, "metadata_json")),
                updatedAt: DateCodec.decode(try required(row, "updated_at"))
            )
        }

        let edges = try edgeRows.map { row in
            SystemGraphEdge(
                id: try required(row, "id"),
                workspaceID: try requiredUUID(row, "workspace_id"),
                fromNodeID: try required(row, "from_node_id"),
                toNodeID: try required(row, "to_node_id"),
                kind: GraphEdgeKind(rawValue: try required(row, "kind")) ?? .executionFlow,
                label: try required(row, "label"),
                updatedAt: DateCodec.decode(try required(row, "updated_at"))
            )
        }

        return (nodes, edges)
    }

    func saveOutcome(_ outcome: OutcomeMetrics) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO outcomes (
                id, workspace_id, task_id, success_rate, retry_rate, rollback_rate,
                human_intervention_rate, integration_success_score, fde_performance_score, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(outcome.id.uuidString),
                .text(outcome.workspaceID.uuidString),
                .text(outcome.taskID.uuidString),
                .double(outcome.taskSuccessRate),
                .double(outcome.retryRate),
                .double(outcome.rollbackRate),
                .double(outcome.humanInterventionRate),
                .double(outcome.integrationSuccessScore),
                .double(outcome.fdePerformanceScore),
                .text(DateCodec.encode(outcome.createdAt))
            ]
        )
    }

    func loadLatestOutcome(workspaceID: UUID) async throws -> OutcomeMetrics? {
        let rows = try connection.query(
            "SELECT * FROM outcomes WHERE workspace_id = ? ORDER BY created_at DESC LIMIT 1;",
            parameters: [.text(workspaceID.uuidString)]
        )
        guard let row = rows.first else {
            return nil
        }

        return OutcomeMetrics(
            id: try requiredUUID(row, "id"),
            workspaceID: try requiredUUID(row, "workspace_id"),
            taskID: try requiredUUID(row, "task_id"),
            taskSuccessRate: try requiredDouble(row, "success_rate"),
            retryRate: try requiredDouble(row, "retry_rate"),
            rollbackRate: try requiredDouble(row, "rollback_rate"),
            humanInterventionRate: try requiredDouble(row, "human_intervention_rate"),
            integrationSuccessScore: try requiredDouble(row, "integration_success_score"),
            fdePerformanceScore: try requiredDouble(row, "fde_performance_score"),
            createdAt: DateCodec.decode(try required(row, "created_at"))
        )
    }

    func saveFeedback(_ feedback: FeedbackInsight) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO feedback (
                id, workspace_id, task_id, kind, title, detail, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(feedback.id.uuidString),
                .text(feedback.workspaceID.uuidString),
                feedback.taskID.map { .text($0.uuidString) } ?? .null,
                .text(feedback.kind.rawValue),
                .text(feedback.title),
                .text(feedback.detail),
                .text(DateCodec.encode(feedback.createdAt))
            ]
        )
    }

    func loadFeedback(workspaceID: UUID) async throws -> [FeedbackInsight] {
        let rows = try connection.query(
            "SELECT * FROM feedback WHERE workspace_id = ? ORDER BY created_at DESC;",
            parameters: [.text(workspaceID.uuidString)]
        )
        return try rows.map { row in
            let taskValue = row["task_id"] ?? nil
            return FeedbackInsight(
                id: try requiredUUID(row, "id"),
                workspaceID: try requiredUUID(row, "workspace_id"),
                taskID: taskValue.flatMap(UUID.init(uuidString:)),
                kind: FeedbackKind(rawValue: try required(row, "kind")) ?? .roadmapSuggestion,
                title: try required(row, "title"),
                detail: try required(row, "detail"),
                createdAt: DateCodec.decode(try required(row, "created_at"))
            )
        }
    }

    func savePolicyDelta(_ delta: ExecutionPolicyDelta) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO policy_deltas (
                id, workspace_id, source_task_id, parent_event_id, kind, task_fingerprint,
                failure_signature, avoid_tool_command, replacement_tool_command, retry_budget,
                reorder_checkpoint_before_risky_tool, summary, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(delta.id.uuidString),
                .text(delta.workspaceID.uuidString),
                delta.sourceTaskID.map { .text($0.uuidString) } ?? .null,
                delta.parentEventID.map { .text($0.uuidString) } ?? .null,
                .text(delta.kind.rawValue),
                .text(delta.taskFingerprint),
                delta.failureSignature.map { .text($0) } ?? .null,
                delta.avoidToolCommand.map { .text($0) } ?? .null,
                delta.replacementToolCommand.map { .text($0) } ?? .null,
                .int(Int64(delta.retryBudget)),
                .int(delta.reorderCheckpointBeforeRiskyTool ? 1 : 0),
                .text(delta.summary),
                .text(DateCodec.encode(delta.createdAt))
            ]
        )
    }

    func loadPolicyDeltas(workspaceID: UUID) async throws -> [ExecutionPolicyDelta] {
        let rows = try connection.query(
            "SELECT * FROM policy_deltas WHERE workspace_id = ? ORDER BY created_at DESC;",
            parameters: [.text(workspaceID.uuidString)]
        )

        return try rows.map { row in
            let sourceTaskValue = row["source_task_id"] ?? nil
            let parentEventValue = row["parent_event_id"] ?? nil
            let failureValue = row["failure_signature"] ?? nil
            let avoidValue = row["avoid_tool_command"] ?? nil
            let replacementValue = row["replacement_tool_command"] ?? nil

            return ExecutionPolicyDelta(
                id: try requiredUUID(row, "id"),
                workspaceID: try requiredUUID(row, "workspace_id"),
                sourceTaskID: sourceTaskValue.flatMap(UUID.init(uuidString:)),
                parentEventID: parentEventValue.flatMap(UUID.init(uuidString:)),
                kind: PolicyAdjustmentKind(rawValue: try required(row, "kind")) ?? .stabilizeSuccessfulPlan,
                taskFingerprint: try required(row, "task_fingerprint"),
                failureSignature: failureValue,
                avoidToolCommand: avoidValue,
                replacementToolCommand: replacementValue,
                retryBudget: Int(try requiredInt(row, "retry_budget")),
                reorderCheckpointBeforeRiskyTool: try requiredInt(row, "reorder_checkpoint_before_risky_tool") == 1,
                summary: try required(row, "summary"),
                createdAt: DateCodec.decode(try required(row, "created_at"))
            )
        }
    }

    func saveTaskExecutionMemory(_ memory: TaskExecutionMemory) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO task_execution_memory (
                id, workspace_id, task_id, task_fingerprint, task_type, performance_score,
                failure_count, created_at, memory_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(memory.id.uuidString),
                .text(memory.workspaceID.uuidString),
                .text(memory.taskID.uuidString),
                .text(memory.taskFingerprint),
                .text(memory.taskType),
                .double(memory.performanceScore),
                .int(Int64(memory.failureSignatures.count)),
                .text(DateCodec.encode(memory.createdAt)),
                .text(try JSONCoding.encode(memory))
            ]
        )
    }

    func loadTaskExecutionMemory(workspaceID: UUID) async throws -> [TaskExecutionMemory] {
        let rows = try connection.query(
            "SELECT memory_json FROM task_execution_memory WHERE workspace_id = ? ORDER BY created_at ASC;",
            parameters: [.text(workspaceID.uuidString)]
        )
        return try rows.map { row in
            try JSONCoding.decode(TaskExecutionMemory.self, from: try required(row, "memory_json"))
        }
    }

    func saveSystemFailureProfile(_ profile: SystemFailureProfile) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO system_failure_profiles (
                id, workspace_id, generated_at, profile_json
            )
            VALUES (?, ?, ?, ?);
            """,
            parameters: [
                .text(profile.id.uuidString),
                .text(profile.workspaceID.uuidString),
                .text(DateCodec.encode(profile.generatedAt)),
                .text(try JSONCoding.encode(profile))
            ]
        )
    }

    func loadLatestSystemFailureProfile(workspaceID: UUID) async throws -> SystemFailureProfile? {
        let rows = try connection.query(
            "SELECT profile_json FROM system_failure_profiles WHERE workspace_id = ? ORDER BY generated_at DESC LIMIT 1;",
            parameters: [.text(workspaceID.uuidString)]
        )
        guard let row = rows.first else {
            return nil
        }
        return try JSONCoding.decode(SystemFailureProfile.self, from: try required(row, "profile_json"))
    }

    func saveSystemInsight(_ insight: SystemLevelInsight) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO system_insights (
                id, workspace_id, kind, task_type, failure_signature, frequency, created_at, insight_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(insight.id.uuidString),
                .text(insight.workspaceID.uuidString),
                .text(insight.kind.rawValue),
                .text(insight.taskType),
                insight.failureSignature.map { .text($0) } ?? .null,
                .int(Int64(insight.frequency)),
                .text(DateCodec.encode(insight.createdAt)),
                .text(try JSONCoding.encode(insight))
            ]
        )
    }

    func loadSystemInsights(workspaceID: UUID) async throws -> [SystemLevelInsight] {
        let rows = try connection.query(
            "SELECT insight_json FROM system_insights WHERE workspace_id = ? ORDER BY created_at DESC;",
            parameters: [.text(workspaceID.uuidString)]
        )
        return try rows.map { row in
            try JSONCoding.decode(SystemLevelInsight.self, from: try required(row, "insight_json"))
        }
    }

    func saveGlobalExecutionPolicy(_ policy: GlobalExecutionPolicy) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO global_execution_policies (
                id, workspace_id, created_at, policy_json
            )
            VALUES (?, ?, ?, ?);
            """,
            parameters: [
                .text(policy.id.uuidString),
                .text(policy.workspaceID.uuidString),
                .text(DateCodec.encode(policy.createdAt)),
                .text(try JSONCoding.encode(policy))
            ]
        )
    }

    func loadLatestGlobalExecutionPolicy(workspaceID: UUID) async throws -> GlobalExecutionPolicy? {
        let rows = try connection.query(
            "SELECT policy_json FROM global_execution_policies WHERE workspace_id = ? ORDER BY created_at DESC LIMIT 1;",
            parameters: [.text(workspaceID.uuidString)]
        )
        guard let row = rows.first else {
            return nil
        }
        return try JSONCoding.decode(GlobalExecutionPolicy.self, from: try required(row, "policy_json"))
    }

    func saveGlobalGovernorDecision(_ decision: GlobalGovernorDecision) async throws {
        try connection.execute(
            """
            INSERT OR REPLACE INTO global_governor_decisions (
                id, workspace_id, task_id, selected_strategy, approved, created_at, decision_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            parameters: [
                .text(decision.id.uuidString),
                .text(decision.workspaceID.uuidString),
                .text(decision.taskID.uuidString),
                .text(decision.selectedStrategy.rawValue),
                .int(decision.approved ? 1 : 0),
                .text(DateCodec.encode(decision.createdAt)),
                .text(try JSONCoding.encode(decision))
            ]
        )
    }

    func loadGlobalGovernorDecisions(workspaceID: UUID) async throws -> [GlobalGovernorDecision] {
        let rows = try connection.query(
            "SELECT decision_json FROM global_governor_decisions WHERE workspace_id = ? ORDER BY created_at DESC;",
            parameters: [.text(workspaceID.uuidString)]
        )
        return try rows.map { row in
            try JSONCoding.decode(GlobalGovernorDecision.self, from: try required(row, "decision_json"))
        }
    }

    private func loadEvent(id: UUID) throws -> ExecutionEvent? {
        let rows = try connection.query(
            "SELECT * FROM events WHERE id = ? LIMIT 1;",
            parameters: [.text(id.uuidString)]
        )
        guard let row = rows.first else { return nil }
        return try decodeEvent(row)
    }

    private func decodeEvent(_ row: [String: String?]) throws -> ExecutionEvent {
        let taskValue = row["task_id"] ?? nil
        let parentValue = row["parent_event_id"] ?? nil
        return ExecutionEvent(
            id: try requiredUUID(row, "id"),
            parentEventID: parentValue.flatMap(UUID.init(uuidString:)),
            workspaceID: try requiredUUID(row, "workspace_id"),
            taskID: taskValue.flatMap(UUID.init(uuidString:)),
            type: EventType(rawValue: try required(row, "type")) ?? .stateUpdated,
            sequence: try requiredInt(row, "sequence"),
            timestamp: DateCodec.decode(try required(row, "timestamp")),
            summary: try required(row, "summary"),
            payload: try JSONCoding.decode([String: String].self, from: try required(row, "payload_json"))
        )
    }

    private func authoritativeSequence(workspaceID: UUID) throws -> Int64 {
        let rows = try connection.query(
            """
            SELECT MAX(
                COALESCE((SELECT MAX(sequence) FROM events WHERE workspace_id = ?), 0),
                COALESCE((SELECT last_event_seq FROM workspaces WHERE id = ?), 0),
                COALESCE((SELECT last_sequence FROM event_sequence_allocators WHERE workspace_id = ?), 0)
            ) AS current_sequence;
            """,
            parameters: [
                .text(workspaceID.uuidString),
                .text(workspaceID.uuidString),
                .text(workspaceID.uuidString)
            ]
        )
        guard let row = rows.first else { return 0 }
        let sequence = try requiredInt(row, "current_sequence")
        guard sequence >= 0 else { throw PersistenceError.eventStoreCorrupt }
        return sequence
    }

    private func persistSequenceMetadata(workspaceID: UUID, sequence: Int64) throws {
        try connection.execute(
            """
            INSERT INTO event_sequence_allocators (workspace_id, last_sequence)
            VALUES (?, ?)
            ON CONFLICT(workspace_id) DO UPDATE SET
                last_sequence = MAX(event_sequence_allocators.last_sequence, excluded.last_sequence);
            """,
            parameters: [.text(workspaceID.uuidString), .int(sequence)]
        )
        try connection.execute(
            "UPDATE workspaces SET last_event_seq = MAX(last_event_seq, ?) WHERE id = ?;",
            parameters: [.int(sequence), .text(workspaceID.uuidString)]
        )
    }

    private func reconcileEventSequences() throws {
        do {
            try connection.execute("BEGIN IMMEDIATE TRANSACTION;")
        } catch {
            throw categorizedTransactionError(kind: connection.failureKind)
        }

        do {
            let integrityRows = try connection.query("PRAGMA quick_check;")
            guard integrityRows.count == 1,
                  (integrityRows.first?["quick_check"] ?? nil) == "ok" else {
                throw PersistenceError.eventStoreCorrupt
            }
            let invalidEventCount = try requiredInt(
                try connection.query("SELECT COUNT(*) AS invalid_count FROM events WHERE sequence < 1;").first ?? [:],
                "invalid_count"
            )
            let duplicateSequenceCount = try requiredInt(
                try connection.query(
                    """
                    SELECT COUNT(*) AS duplicate_count FROM (
                        SELECT workspace_id, sequence
                        FROM events
                        GROUP BY workspace_id, sequence
                        HAVING COUNT(*) > 1
                    );
                    """
                ).first ?? [:],
                "duplicate_count"
            )
            let invalidMetadataCount = try requiredInt(
                try connection.query(
                    """
                    SELECT
                        (SELECT COUNT(*) FROM workspaces WHERE last_event_seq < 0)
                        + (SELECT COUNT(*) FROM event_sequence_allocators WHERE last_sequence < 0)
                        AS invalid_count;
                    """
                ).first ?? [:],
                "invalid_count"
            )
            guard invalidEventCount == 0,
                  duplicateSequenceCount == 0,
                  invalidMetadataCount == 0 else {
                throw PersistenceError.eventStoreCorrupt
            }

            let workspaceRows = try connection.query(
                """
                SELECT id AS workspace_id FROM workspaces
                UNION
                SELECT workspace_id FROM events
                UNION
                SELECT workspace_id FROM event_sequence_allocators;
                """
            )
            for row in workspaceRows {
                guard let workspaceID = UUID(uuidString: try required(row, "workspace_id")) else {
                    throw PersistenceError.eventStoreCorrupt
                }
                let sequence = try authoritativeSequence(workspaceID: workspaceID)
                try persistSequenceMetadata(workspaceID: workspaceID, sequence: sequence)
            }
            try connection.execute("COMMIT;")
        } catch {
            let kind = connection.failureKind
            try? connection.execute("ROLLBACK;")
            if let persistenceError = error as? PersistenceError,
               persistenceError.isSanitizedEventStoreFailure {
                throw persistenceError
            }
            throw categorizedTransactionError(kind: kind)
        }
    }

    private func categorizedTransactionError(kind: SQLiteFailureKind) -> PersistenceError {
        switch kind {
        case .constraint:
            return .eventSequenceConflict
        case .unavailable:
            return .eventStoreUnavailable
        case .corrupt:
            return .eventStoreCorrupt
        case .other:
            return .eventTransactionFailed
        }
    }

    private func required(_ row: [String: String?], _ key: String) throws -> String {
        guard let value = row[key] ?? nil else {
            throw PersistenceError.decodingFailed("Missing \(key)")
        }
        return value
    }

    private func optional(_ row: [String: String?], _ key: String) -> String? {
        row[key] ?? nil
    }

    private func requiredUUID(_ row: [String: String?], _ key: String) throws -> UUID {
        guard let uuid = UUID(uuidString: try required(row, key)) else {
            throw PersistenceError.decodingFailed("Invalid UUID for \(key)")
        }
        return uuid
    }

    private func optionalUUID(_ row: [String: String?], _ key: String) -> UUID? {
        guard let value = optional(row, key) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private func requiredDouble(_ row: [String: String?], _ key: String) throws -> Double {
        guard let value = Double(try required(row, key)) else {
            throw PersistenceError.decodingFailed("Invalid Double for \(key)")
        }
        return value
    }

    private func requiredInt(_ row: [String: String?], _ key: String) throws -> Int64 {
        guard let value = Int64(try required(row, key)) else {
            throw PersistenceError.decodingFailed("Invalid Int for \(key)")
        }
        return value
    }

    private func backfillEventParents() throws {
        let rows = try connection.query(
            "SELECT id, workspace_id, task_id, parent_event_id FROM events ORDER BY workspace_id ASC, task_id ASC, sequence ASC, id ASC;"
        )
        var lastEventIDByChain: [String: String] = [:]

        for row in rows {
            let id = try required(row, "id")
            let workspaceID = try required(row, "workspace_id")
            let taskID = row["task_id"] ?? nil
            let existingParent = row["parent_event_id"] ?? nil
            let chainKey = "\(workspaceID)|\(taskID ?? "workspace")"

            if existingParent == nil, let parent = lastEventIDByChain[chainKey] {
                try connection.execute(
                    "UPDATE events SET parent_event_id = ? WHERE id = ?;",
                    parameters: [.text(parent), .text(id)]
                )
            }

            lastEventIDByChain[chainKey] = id
        }
    }
}
