import Foundation
import SQLite3

/// A small SQLite connection for the artifact store. Not thread-safe on its own: only the store's
/// actor touches it.
final class SQLiteDatabase {
    enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    private var handle: OpaquePointer?

    /// Opens (or creates) the database at `url`; nil opens a private in-memory database.
    init(url: URL?) throws {
        let path = url?.path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            handle = nil
            throw Failure(code: result, message: message)
        }
        try execute("PRAGMA foreign_keys = ON")
        if url != nil { try execute("PRAGMA journal_mode = WAL") }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "failed"
            sqlite3_free(error)
            throw Failure(code: result, message: message)
        }
    }

    /// Runs one statement with its bound values and returns every row.
    @discardableResult
    func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastFailure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data): data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            }
            guard result == SQLITE_OK else { throw lastFailure() }
        }
        var rows: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastFailure() }
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), count > 0 { row.append(.blob(Data(bytes: bytes, count: count))) }
                    else { row.append(.blob(Data())) }
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs `body` in one transaction: all of it lands, or none of it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func lastFailure() -> Failure {
        Failure(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}

extension SQLiteDatabase.Value {
    var text: String? { if case .text(let value) = self { value } else { nil } }
    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var real: Double? { if case .real(let value) = self { value } else if case .integer(let value) = self { Double(value) } else { nil } }
    var blob: Data? { if case .blob(let value) = self { value } else { nil } }
}
