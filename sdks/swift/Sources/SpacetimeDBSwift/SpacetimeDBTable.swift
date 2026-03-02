/// Protocol for types that represent SpacetimeDB table rows.
public protocol SpacetimeDBTable: Codable, Equatable, Sendable {
    /// The name of the table as defined in the server module.
    static var tableName: String { get }
    /// The name of the primary key column, if any.
    static var primaryKey: String? { get }
}
