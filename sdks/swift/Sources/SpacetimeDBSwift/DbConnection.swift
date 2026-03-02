import Foundation

/// A connection to a SpacetimeDB module.
public actor DbConnection {
    // Connection config
    private let host: URL
    private let nameOrAddress: String

    // WebSocket state
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?

    // Identity
    private(set) public var identity: Identity?
    private(set) public var connectionId: ConnectionId?
    private var token: String?

    // Request tracking
    private var nextRequestId: UInt32 = 1

    // Client cache
    public let tableCache: TableCache

    // Callbacks
    private var onConnectHandler: ((Identity, ConnectionId) -> Void)?
    private var onDisconnectHandler: (() -> Void)?
    private var onErrorHandler: ((Error) -> Void)?

    // Receive task
    private var receiveTask: Task<Void, Never>?

    init(
        host: URL,
        nameOrAddress: String,
        onConnect: ((Identity, ConnectionId) -> Void)? = nil,
        onDisconnect: (() -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        self.host = host
        self.nameOrAddress = nameOrAddress
        self.tableCache = TableCache()
        self.onConnectHandler = onConnect
        self.onDisconnectHandler = onDisconnect
        self.onErrorHandler = onError
    }

    // MARK: - Connect

    func connect() async throws {
        // Build WebSocket URL
        let scheme = host.scheme == "https" ? "wss" : "ws"
        let hostString = host.host ?? "127.0.0.1"
        let port = host.port ?? 3000
        let wsURL = URL(string: "\(scheme)://\(hostString):\(port)/v1/database/\(nameOrAddress)/subscribe?compression=None")!

        var request = URLRequest(url: wsURL)
        request.setValue("v2.bsatn.spacetimedb", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let session = URLSession(configuration: .default)
        self.session = session

        let task = session.webSocketTask(with: request)
        self.webSocket = task
        task.resume()

        // Start receive loop
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    // MARK: - Disconnect

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        onDisconnectHandler?()
    }

    // MARK: - Subscribe

    public func subscribe(queries: [String], querySetId: UInt32) async {
        let requestId = nextRequestId
        nextRequestId += 1

        let msg = ClientMessage.subscribe(Subscribe(
            requestId: requestId,
            querySetId: QuerySetId(id: querySetId),
            queryStrings: queries
        ))

        await sendMessage(msg)
    }

    // MARK: - Call reducer

    public func callReducer(name: String, args: Data) async {
        let requestId = nextRequestId
        nextRequestId += 1

        let msg = ClientMessage.callReducer(CallReducer(
            requestId: requestId,
            flags: 0,
            reducer: name,
            args: args
        ))

        await sendMessage(msg)
    }

    // MARK: - Table update callback

    public func onTableUpdate(_ table: String, callback: @escaping @Sendable () async -> Void) async {
        await tableCache.onTableUpdate(table, callback: callback)
    }

    // MARK: - Send

    private func sendMessage(_ message: ClientMessage) async {
        do {
            let data = try BSATN.encode(message)
            try await webSocket?.send(.data(data))
        } catch {
            onErrorHandler?(error)
        }
    }

    // MARK: - Receive loop

    private func receiveLoop() async {
        guard let ws = webSocket else { return }

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case .data(let data):
                    await handleBinaryMessage(data)
                case .string:
                    break // Ignore text messages
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    onErrorHandler?(error)
                    onDisconnectHandler?()
                }
                break
            }
        }
    }

    private func handleBinaryMessage(_ data: Data) async {
        guard data.count >= 1 else { return }

        // First byte is compression tag
        let compressionTag = data[data.startIndex]
        guard compressionTag == 0 else {
            onErrorHandler?(BSATNDecodeError.custom("Unsupported compression tag: \(compressionTag)"))
            return
        }

        // Remaining bytes are the BSATN-encoded ServerMessage
        let messageData = data.suffix(from: data.startIndex + 1)

        do {
            let serverMsg = try BSATN.decode(ServerMessage.self, from: Data(messageData))
            await handleServerMessage(serverMsg)
        } catch {
            onErrorHandler?(error)
        }
    }

    // MARK: - Message handlers

    private func handleServerMessage(_ msg: ServerMessage) async {
        switch msg {
        case .initialConnection(let ic):
            await handleInitialConnection(ic)
        case .subscribeApplied(let sa):
            await handleSubscribeApplied(sa)
        case .unsubscribeApplied:
            break // MVP: not handled
        case .subscriptionError(let err):
            onErrorHandler?(BSATNDecodeError.custom("Subscription error: \(err.error)"))
        case .transactionUpdate(let tu):
            await handleTransactionUpdate(tu)
        case .oneOffQueryResult:
            break // MVP: not handled
        case .reducerResult(let rr):
            await handleReducerResult(rr)
        case .procedureResult:
            break // MVP: not handled
        }
    }

    private func handleInitialConnection(_ msg: InitialConnection) async {
        identity = msg.identity
        connectionId = msg.connectionId
        token = msg.token
        onConnectHandler?(msg.identity, msg.connectionId)
    }

    private func handleSubscribeApplied(_ msg: SubscribeApplied) async {
        for tableRows in msg.rows.tables {
            let rows = tableRows.rows.splitRows()
            await tableCache.applyInserts(table: tableRows.table, rows: rows)
        }
    }

    private func handleTransactionUpdate(_ msg: TransactionUpdate) async {
        for querySetUpdate in msg.querySets {
            for tableUpdate in querySetUpdate.tables {
                for tableUpdateRows in tableUpdate.rows {
                    switch tableUpdateRows {
                    case .persistentTable(let persistent):
                        let inserts = persistent.inserts.splitRows()
                        let deletes = persistent.deletes.splitRows()
                        if !deletes.isEmpty {
                            await tableCache.applyDeletes(table: tableUpdate.tableName, rows: deletes)
                        }
                        if !inserts.isEmpty {
                            await tableCache.applyInserts(table: tableUpdate.tableName, rows: inserts)
                        }
                    case .eventTable:
                        break // MVP: event tables not handled
                    }
                }
            }
        }
    }

    private func handleReducerResult(_ msg: ReducerResult) async {
        switch msg.result {
        case .ok(let ok):
            await handleTransactionUpdate(ok.transactionUpdate)
        case .okEmpty:
            break // No updates
        case .err:
            break // Reducer error, no rollback needed
        case .internalError(let error):
            onErrorHandler?(BSATNDecodeError.custom("Reducer error: \(error)"))
        }
    }
}

// MARK: - DbConnectionBuilder

public class DbConnectionBuilder: @unchecked Sendable {
    private var uri: URL?
    private var moduleName: String?
    private var onConnect: ((Identity, ConnectionId) -> Void)?
    private var onDisconnect: (() -> Void)?
    private var onError: ((Error) -> Void)?

    public init() {}

    public func withUri(_ url: URL) -> Self {
        self.uri = url
        return self
    }

    public func withModuleName(_ name: String) -> Self {
        self.moduleName = name
        return self
    }

    public func onConnect(_ handler: @escaping (Identity, ConnectionId) -> Void) -> Self {
        self.onConnect = handler
        return self
    }

    public func onDisconnect(_ handler: @escaping () -> Void) -> Self {
        self.onDisconnect = handler
        return self
    }

    public func onError(_ handler: @escaping (Error) -> Void) -> Self {
        self.onError = handler
        return self
    }

    public func build() async throws -> DbConnection {
        guard let uri = uri else {
            throw BSATNDecodeError.custom("URI is required")
        }
        guard let moduleName = moduleName else {
            throw BSATNDecodeError.custom("Module name is required")
        }

        let connection = DbConnection(
            host: uri,
            nameOrAddress: moduleName,
            onConnect: onConnect,
            onDisconnect: onDisconnect,
            onError: onError
        )

        try await connection.connect()
        return connection
    }
}
