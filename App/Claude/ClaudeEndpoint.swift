import Foundation
import Network
import Observation

/// Compass's MCP endpoint: JSON-RPC over HTTP on 127.0.0.1 only, for Claude
/// Code directly and Claude desktop through the `compass-mcp` bridge. Every
/// request must carry the key from Settings. It runs only while "Allow
/// Claude access" is on, whether or not the window is locked.
///
/// The listener runs on the main queue, so tools read the store's main
/// context directly; requests are small and rare.
@Observable
final class ClaudeEndpoint {
    private(set) var isRunning = false
    /// Set when the port couldn't be opened, in words for Settings.
    private(set) var failure: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored let tools: ClaudeTools

    init(tools: ClaudeTools) {
        self.tools = tools
        if ClaudeAccess.isEnabled { start() }
    }

    /// Follows the Settings switch.
    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard listener == nil else { return }
        failure = nil
        let parameters = NWParameters.tcp
        // Loopback only: without this it listens on every interface, the local network included.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ClaudeAccess.port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed(let error):
                        self?.failure = "Couldn't open port \(ClaudeAccess.port) for Claude (\(error.localizedDescription))."
                        self?.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            failure = "Couldn't open port \(ClaudeAccess.port) for Claude (\(error.localizedDescription))."
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    /// Reads until the headers and `Content-Length` bytes of body are in;
    /// one callback isn't one request.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    self.reply(to: request, on: connection)
                } else if isComplete || error != nil || buffer.count > 1_000_000 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    /// Tools that read years of balances do so off the main thread, so the
    /// answer is sent when it's ready.
    private func reply(to request: HTTPRequest, on connection: NWConnection) {
        let tools = tools
        Task {
            let response: HTTPResponse
            if ClaudeAccess.key.map({ request.headers["authorization"] != "Bearer \($0)" }) ?? true {
                // 403, not 401: a 401 sends some clients looking for OAuth.
                response = HTTPResponse(status: 403, reason: "Forbidden")
            } else if request.method != "POST" {
                response = HTTPResponse(status: 405, reason: "Method Not Allowed")
            } else if let body = await MCPProtocol.handle(request.body, tools: tools) {
                response = HTTPResponse(status: 200, reason: "OK", body: body)
            } else {
                // A notification: nothing to answer.
                response = HTTPResponse(status: 202, reason: "Accepted")
            }
            connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Just enough HTTP/1.1 for one request per connection.
private struct HTTPRequest {
    var method: String
    var headers: [String: String]
    var body: Data

    /// Nil until the whole request is in.
    init?(_ data: Data) {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)),
            let head = String(data: data[..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
        headers = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
    }
}

private struct HTTPResponse {
    var status: Int
    var reason: String
    var body = Data()

    var data: Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// MCP's JSON-RPC: initialize, ping, tools/list and tools/call. Answers are
/// plain JSON (no event stream).
enum MCPProtocol {
    /// Nil for a notification, which gets no answer.
    static func handle(_ body: Data, tools: ClaudeTools) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let method = message["method"] as? String
        else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Couldn't read the request."]])
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            reply["result"] = [
                // Whatever version the client speaks; nothing here depends on one.
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "compass", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"],
                "instructions": ClaudeTools.instructions(for: Profile.name)
            ]
        case "ping":
            reply["result"] = [:] as [String: Any]
        case "tools/list":
            reply["result"] = ["tools": tools.list]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if let answer = await tools.call(name, arguments: arguments) {
                reply["result"] = ["content": [["type": "text", "text": answer.text]], "isError": answer.isError]
            } else {
                reply["error"] = ["code": -32602, "message": "No tool called \(name)."]
            }
        default:
            reply["error"] = ["code": -32601, "message": "Compass doesn't handle \(method)."]
        }
        return encode(reply)
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
