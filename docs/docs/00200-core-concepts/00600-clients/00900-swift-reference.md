---
title: Swift Reference
toc_max_heading_level: 6
slug: /clients/swift
---

:::caution Early Development
The Swift SDK is in early development. APIs may change between releases. Please report issues on [GitHub](https://github.com/clockworklabs/SpacetimeDB).
:::

The SpacetimeDB client SDK for Swift provides native Apple platform support for building clients that connect to SpacetimeDB modules. It supports macOS 13+ and iOS 16+.

Before diving into the reference, you may want to review:

- [Generating Client Bindings](./00200-codegen.md) - How to generate Swift bindings from your module
- [Connecting to SpacetimeDB](./00300-connection.md) - Establishing and managing connections
- [SDK API Reference](./00400-sdk-api.md) - Core concepts that apply across all SDKs

## Project setup

Add the SpacetimeDB Swift SDK to your project using Swift Package Manager. In your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/clockworklabs/SpacetimeDB", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "SpacetimeDBSwift", package: "SpacetimeDB"),
        ]
    ),
]
```

Or add it via Xcode: **File > Add Package Dependencies** and enter the repository URL.

## Generate module bindings

Generate Swift bindings from your module:

```bash
mkdir -p Sources/module_bindings
spacetime generate --lang swift --out-dir Sources/module_bindings --module-path PATH-TO-MODULE-DIRECTORY
```

Replace **PATH-TO-MODULE-DIRECTORY** with the path to your module's directory.

## Type mapping

The following table shows how SpacetimeDB types map to Swift types in generated code:

| SpacetimeDB Type | Swift Type |
|------------------|------------|
| `bool` | `Bool` |
| `u8` | `UInt8` |
| `u16` | `UInt16` |
| `u32` | `UInt32` |
| `u64` | `UInt64` |
| `u128` | `UInt128` |
| `u256` | `U256` |
| `i8` | `Int8` |
| `i16` | `Int16` |
| `i32` | `Int32` |
| `i64` | `Int64` |
| `i128` | `Int128` |
| `i256` | `I256` |
| `f32` | `Float` |
| `f64` | `Double` |
| `String` | `String` |
| `Identity` | `Identity` |
| `ConnectionId` | `ConnectionId` |
| `Timestamp` | `Timestamp` |
| `TimeDuration` | `TimeDuration` |
| `ScheduleAt` | `ScheduleAt` |
| `Vec<T>` | `[T]` |
| `Option<T>` | `T?` |
| `Map<K, V>` | `[K: V]` |
| enum types | `enum` |
| struct types | `struct` |

## Connecting to a database

```swift
import SpacetimeDBSwift

let url = URL(string: "ws://localhost:3000")!
let connection = DbConnection(url: url)
try await connection.connect()
```

## Table protocol

Generated table types conform to the `SpacetimeDBTable` protocol:

```swift
// Generated code
struct User: SpacetimeDBTable {
    static var tableName: String { "user" }
    static var primaryKey: String? { "id" }

    var id: UInt64
    var name: String
    var email: String
}
```

## Invoking reducers

Reducers are generated as methods on the connection's reducer interface:

```swift
// Call a reducer
try await connection.reducers.createUser(name: "Alice", email: "alice@example.com")
```

## Next steps

- Follow a quickstart guide to build your first SpacetimeDB application
- Learn about [Databases](../00100-databases.md) to understand what you're connecting to
- Explore [Subscriptions](../00400-subscriptions.md) for efficient data synchronization
- Review [Reducers](../00200-functions/00300-reducers/00300-reducers.md) to understand server-side state changes
