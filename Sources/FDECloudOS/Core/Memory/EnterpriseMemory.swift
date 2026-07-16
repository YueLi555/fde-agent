import Foundation

struct EnterpriseMemoryQuery: Sendable {
    var workspaceID: UUID
    var taskFingerprint: String?
    var text: String
    var types: Set<EnterpriseMemoryType>
    var limit: Int

    init(
        workspaceID: UUID,
        taskFingerprint: String? = nil,
        text: String = "",
        types: Set<EnterpriseMemoryType> = Set(EnterpriseMemoryType.allCases),
        limit: Int = 12
    ) {
        self.workspaceID = workspaceID
        self.taskFingerprint = taskFingerprint
        self.text = text
        self.types = types
        self.limit = limit
    }
}

protocol EnterpriseMemoryStoring: Sendable {
    func initialize() async throws
    func save(_ entry: MemoryEntry) async throws
    func retrieve(_ query: EnterpriseMemoryQuery) async throws -> [MemoryEntry]
}

actor InMemoryEnterpriseMemoryStore: EnterpriseMemoryStoring {
    private var entries: [UUID: MemoryEntry] = [:]

    func initialize() async throws {}

    func save(_ entry: MemoryEntry) async throws {
        entries[entry.id] = entry
    }

    func retrieve(_ query: EnterpriseMemoryQuery) async throws -> [MemoryEntry] {
        entries.values
            .filter { entry in
                entry.workspaceID == query.workspaceID
                    && query.types.contains(entry.type)
                    && matches(entry, query: query)
            }
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.confidence > rhs.confidence
            }
            .prefix(max(0, query.limit))
            .map { $0 }
    }

    private func matches(_ entry: MemoryEntry, query: EnterpriseMemoryQuery) -> Bool {
        if let taskFingerprint = query.taskFingerprint,
           entry.relatedTaskFingerprint == taskFingerprint {
            return true
        }

        let tokens = normalizedTokens(query.text)
        guard !tokens.isEmpty else { return true }

        let searchable = normalizedTokens(
            ([entry.title, entry.summary, entry.detail, entry.relatedTaskFingerprint ?? "", entry.connectorID ?? ""] + entry.tags)
                .joined(separator: " ")
        )
        return !tokens.isDisjoint(with: searchable)
    }

    private func normalizedTokens(_ value: String) -> Set<String> {
        Set(
            value
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }
}

struct PostgreSQLMemoryConfiguration: Codable, Hashable, Sendable {
    var connectionString: String
    var tableName: String

    init(connectionString: String, tableName: String = "enterprise_memory") {
        self.connectionString = connectionString
        self.tableName = tableName
    }
}

protocol PostgreSQLMemoryDatabase: Sendable {
    func initializeEnterpriseMemorySchema(tableName: String) async throws
    func upsertMemoryEntry(_ entry: MemoryEntry, tableName: String) async throws
    func queryMemory(_ query: EnterpriseMemoryQuery, tableName: String) async throws -> [MemoryEntry]
}

actor PostgreSQLEnterpriseMemoryStore: EnterpriseMemoryStoring {
    let configuration: PostgreSQLMemoryConfiguration
    private let database: any PostgreSQLMemoryDatabase

    init(configuration: PostgreSQLMemoryConfiguration, database: any PostgreSQLMemoryDatabase) {
        self.configuration = configuration
        self.database = database
    }

    func initialize() async throws {
        try await database.initializeEnterpriseMemorySchema(tableName: configuration.tableName)
    }

    func save(_ entry: MemoryEntry) async throws {
        try await database.upsertMemoryEntry(entry, tableName: configuration.tableName)
    }

    func retrieve(_ query: EnterpriseMemoryQuery) async throws -> [MemoryEntry] {
        try await database.queryMemory(query, tableName: configuration.tableName)
    }
}

enum PostgreSQLEnterpriseMemorySchema {
    static func createTableSQL(tableName: String = "enterprise_memory") -> String {
        """
        CREATE TABLE IF NOT EXISTS \(tableName) (
            id UUID PRIMARY KEY,
            workspace_id UUID NOT NULL,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            detail TEXT NOT NULL,
            tags TEXT[] NOT NULL DEFAULT '{}',
            related_task_fingerprint TEXT,
            connector_id TEXT,
            source_task_id UUID,
            confidence DOUBLE PRECISION NOT NULL,
            created_at TIMESTAMPTZ NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_\(tableName)_workspace_type
            ON \(tableName)(workspace_id, type, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_\(tableName)_fingerprint
            ON \(tableName)(workspace_id, related_task_fingerprint);
        """
    }

    static func upsertSQL(tableName: String = "enterprise_memory") -> String {
        """
        INSERT INTO \(tableName) (
            id, workspace_id, type, title, summary, detail, tags,
            related_task_fingerprint, connector_id, source_task_id,
            confidence, created_at, updated_at
        )
        VALUES (
            $1, $2, $3, $4, $5, $6, $7,
            $8, $9, $10, $11, $12, $13
        )
        ON CONFLICT (id) DO UPDATE SET
            type = EXCLUDED.type,
            title = EXCLUDED.title,
            summary = EXCLUDED.summary,
            detail = EXCLUDED.detail,
            tags = EXCLUDED.tags,
            related_task_fingerprint = EXCLUDED.related_task_fingerprint,
            connector_id = EXCLUDED.connector_id,
            source_task_id = EXCLUDED.source_task_id,
            confidence = EXCLUDED.confidence,
            updated_at = EXCLUDED.updated_at;
        """
    }
}
