import Foundation

/// A 256-bit signed integer.
public struct I256: Codable, Equatable, Hashable, Sendable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// A 256-bit unsigned integer.
public struct U256: Codable, Equatable, Hashable, Sendable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}
