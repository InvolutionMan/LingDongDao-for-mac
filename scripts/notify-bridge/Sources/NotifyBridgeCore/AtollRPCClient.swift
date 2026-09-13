import Foundation

/// The transport Atoll actually answers on.
///
/// `AtollExtensionKit` talks XPC, and in practice that never completes here —
/// its continuations leak ("checkAuthorization() leaked its continuation
/// without resuming it"), so a message was never delivered and the island stayed
/// quiet. Atoll also serves the same extension API as JSON-RPC over a WebSocket
/// bound to loopback (`ExtensionRPCServer`, port 9020), which is what the app's
/// own host uses, so the bridge speaks that instead. The kit is still used to
/// *encode* the descriptor: the app decodes it with the same type, so the JSON
/// shape is exactly right by construction.
struct AtollRPCClient {
    static let defaultEndpoint = URL(string: "ws://127.0.0.1:9020")!

    let bundleIdentifier: String
    let endpoint: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var nextID = 0

    init(bundleIdentifier: String, endpoint: URL = AtollRPCClient.defaultEndpoint) {
        self.bundleIdentifier = bundleIdentifier
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: configuration)
    }

    /// Presents (or replaces) a live activity. Returns the server's reply text
    /// for logging.
    mutating func presentLiveActivity(descriptor: [String: Any]) async throws -> String {
        let result = try await call(
            "atoll.presentLiveActivity",
            params: ["bundleIdentifier": bundleIdentifier, "descriptor": descriptor]
        )
        return Self.describe(result)
    }

    /// The bundle identifiers this endpoint has authorised.
    mutating func checkAuthorization() async throws -> String {
        let result = try await call(
            "atoll.checkAuthorization",
            params: ["bundleIdentifier": bundleIdentifier]
        )
        return Self.describe(result)
    }

    // MARK: - JSON-RPC over WebSocket

    private mutating func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let socket = try await connection()
        nextID += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": String(nextID),
            "method": method,
            "params": params,
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: payload, encoding: .utf8) else {
            throw BridgeError.payload("could not encode \(method)")
        }
        try await socket.send(.string(text))

        let reply = try await socket.receive()
        let data: Data
        switch reply {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: throw BridgeError.payload("unsupported WebSocket frame from Atoll")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.payload("Atoll sent something that is not JSON: \(String(data: data, encoding: .utf8) ?? "<binary>")")
        }
        if let error = object["error"] as? [String: Any] {
            throw BridgeError.payload("Atoll refused \(method): \(error["message"] as? String ?? "\(error)")")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    private mutating func connection() async throws -> URLSessionWebSocketTask {
        if let task { return task }
        let socket = session.webSocketTask(with: endpoint)
        socket.resume()
        task = socket
        return socket
    }

    private static func describe(_ result: [String: Any]) -> String {
        result.isEmpty ? "ok" : "\(result)"
    }
}
