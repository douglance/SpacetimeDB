import Foundation

/// Stores raw BSATN row bytes by table name.
/// Supports insert/delete operations and row decoding.
public actor TableCache {
    /// Raw BSATN row data for each table.
    private var tables: [String: [Data]] = [:]

    /// Callbacks for table changes (called after inserts/deletes).
    private var tableUpdateCallbacks: [String: [@Sendable () async -> Void]] = [:]

    public init() {}

    // MARK: - Row operations

    public func applyInserts(table: String, rows: [Data]) async {
        if tables[table] == nil {
            tables[table] = []
        }
        tables[table]!.append(contentsOf: rows)
        await notifyTableUpdate(table)
    }

    public func applyDeletes(table: String, rows: [Data]) async {
        guard var existing = tables[table] else { return }

        for rowToDelete in rows {
            if let index = existing.firstIndex(of: rowToDelete) {
                existing.remove(at: index)
            }
        }
        tables[table] = existing
        await notifyTableUpdate(table)
    }

    public func getRows(table: String) -> [Data] {
        tables[table] ?? []
    }

    public func decodeRows<T: Decodable>(table: String, as type: T.Type) -> [T] {
        let decoder = BSATNDecoder()
        return (tables[table] ?? []).compactMap { rowData in
            try? decoder.decode(type, from: rowData)
        }
    }

    public func clearTable(_ table: String) {
        tables[table] = []
    }

    // MARK: - Callbacks

    public func onTableUpdate(_ table: String, callback: @escaping @Sendable () async -> Void) {
        if tableUpdateCallbacks[table] == nil {
            tableUpdateCallbacks[table] = []
        }
        tableUpdateCallbacks[table]!.append(callback)
    }

    private func notifyTableUpdate(_ table: String) async {
        let callbacks = tableUpdateCallbacks[table] ?? []
        for callback in callbacks {
            await callback()
        }
    }
}
