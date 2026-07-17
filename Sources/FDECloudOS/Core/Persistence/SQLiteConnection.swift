import Foundation
import SQLiteShim

enum SQLiteValue {
    case text(String)
    case double(Double)
    case int(Int64)
    case null
}

enum SQLiteFailureKind {
    case constraint
    case unavailable
    case corrupt
    case other
}

final class SQLiteConnection {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &database, flags, nil)
        guard status == SQLITE_OK else {
            let detail = SQLiteConnection.message(for: database)
            sqlite3_close(database)
            throw PersistenceError.databaseUnavailable(detail)
        }
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit {
        sqlite3_close(database)
    }

    func execute(_ sql: String, parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(parameters, to: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw PersistenceError.databaseUnavailable(errorMessage)
        }
    }

    func query(_ sql: String, parameters: [SQLiteValue] = []) throws -> [[String: String?]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(parameters, to: statement)
        var rows: [[String: String?]] = []

        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return rows
            }
            guard status == SQLITE_ROW else {
                throw PersistenceError.databaseUnavailable(errorMessage)
            }

            var row: [String: String?] = [:]
            let columnCount = sqlite3_column_count(statement)
            for column in 0..<columnCount {
                guard let namePointer = sqlite3_column_name(statement, column) else {
                    continue
                }
                let name = String(cString: namePointer)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL:
                    row[name] = nil
                case SQLITE_INTEGER:
                    row[name] = String(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    row[name] = String(sqlite3_column_double(statement, column))
                default:
                    if let textPointer = sqlite3_column_text(statement, column) {
                        row[name] = String(cString: textPointer)
                    } else {
                        row[name] = nil
                    }
                }
            }
            rows.append(row)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw PersistenceError.databaseUnavailable(errorMessage)
        }
        return statement
    }

    private func bind(_ parameters: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch parameter {
            case .text(let value):
                status = sqlite3_bind_text(statement, index, value, -1, transient)
            case .double(let value):
                status = sqlite3_bind_double(statement, index, value)
            case .int(let value):
                status = sqlite3_bind_int64(statement, index, value)
            case .null:
                status = sqlite3_bind_null(statement, index)
            }

            guard status == SQLITE_OK else {
                throw PersistenceError.databaseUnavailable(errorMessage)
            }
        }
    }

    private var errorMessage: String {
        SQLiteConnection.message(for: database)
    }

    var failureKind: SQLiteFailureKind {
        switch sqlite3_errcode(database) {
        case SQLITE_CONSTRAINT:
            return .constraint
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_CANTOPEN, SQLITE_IOERR,
             SQLITE_FULL, SQLITE_READONLY, SQLITE_PERM:
            return .unavailable
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corrupt
        default:
            return .other
        }
    }

    private static func message(for database: OpaquePointer?) -> String {
        if let pointer = sqlite3_errmsg(database) {
            return String(cString: pointer)
        }
        return "Unknown SQLite error"
    }
}
