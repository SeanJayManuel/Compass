// compass-mcp: the bridge Claude desktop launches. It passes each JSON-RPC
// line from stdin to Compass's endpoint on 127.0.0.1 and writes the answer
// to stdout, one line each. If Compass isn't running, it opens the copy it
// lives in, in the background (no window, no Touch ID), and tries again.
// Every minute it asks for the tool list, and tells Claude when it changed
// (a newer Compass was installed), so Claude needn't be restarted.
//
// Settings come from the environment Claude desktop's config gives it:
// COMPASS_PORT, COMPASS_KEY and COMPASS_BUNDLE_ID. Stdout carries only
// JSON-RPC; anything else goes to stderr.

import Foundation

let environment = ProcessInfo.processInfo.environment
guard let port = environment["COMPASS_PORT"], let key = environment["COMPASS_KEY"] else {
    FileHandle.standardError.write(Data("compass-mcp: COMPASS_PORT and COMPASS_KEY must be set\n".utf8))
    exit(1)
}
let bundleID = environment["COMPASS_BUNDLE_ID"] ?? "com.seanjaymanuel.Compass"
let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!

func log(_ message: String) {
    FileHandle.standardError.write(Data("compass-mcp: \(message)\n".utf8))
}

func post(_ body: Data) async throws -> (Data, Int) {
    var request = URLRequest(url: endpoint, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
}

/// The Compass this bridge is inside (…/Compass.app/Contents/MacOS/compass-mcp).
/// Opened by path: by bundle ID, macOS once picked an old copy left in a
/// build folder, and it dropped data it didn't know.
let appURL: URL? = {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}()

func openCompass() {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = (appURL.map { ["-g", "-a", $0.path] } ?? ["-g", "-b", bundleID]) + ["--args", "--background"]
    try? open.run()
    open.waitUntilExit()
}

/// Stdout, one whole line at a time from the reader and the watcher.
actor Output {
    func write(_ line: Data) { FileHandle.standardOutput.write(line + Data("\n".utf8)) }
}

/// The tool names Claude was last given, once it has initialized.
actor ToolWatch {
    private var names: [String]?
    private var initialized = false

    func sawInitialized() { initialized = true }

    /// Records a tools/list answer; true when Claude should hear it changed.
    func saw(_ answer: Data) -> Bool {
        guard let message = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
            let result = message["result"] as? [String: Any], let tools = result["tools"] as? [[String: Any]]
        else { return false }
        let new = tools.compactMap { $0["name"] as? String }.sorted()
        defer { names = new }
        return initialized && names != nil && names != new
    }

    var watching: Bool { initialized && names != nil }
}

let output = Output()
let watch = ToolWatch()

/// Every minute, while Compass answers: has the tool list changed?
Task.detached {
    let ask = Data(#"{"jsonrpc":"2.0","id":"compass-mcp-watch","method":"tools/list"}"#.utf8)
    while true {
        try? await Task.sleep(for: .seconds(60))
        guard await watch.watching, let (data, status) = try? await post(ask), status == 200 else { continue }
        if await watch.saw(data) {
            await output.write(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))
        }
    }
}

/// Sends one line, opening Compass and retrying for about 15 seconds if
/// nothing is listening. Nil for a notification; an error reply when
/// Compass can't answer a request, so Claude isn't left waiting.
func forward(_ line: Data) async -> Data? {
    var opened = false
    for _ in 0..<30 {
        do {
            let (data, status) = try await post(line)
            switch status {
            case 200: return data
            case 202: return nil
            case 403: return failure(for: line, "Compass refused the key. Copy the Claude setup again from Compass's Settings > Security.")
            default: return failure(for: line, "Compass answered with HTTP \(status).")
            }
        } catch {
            if !opened {
                log("Compass isn't answering; opening it in the background")
                openCompass()
                opened = true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    return failure(for: line, "Compass isn't answering. Is \"Allow Claude access\" on in its Settings > Security?")
}

/// A JSON-RPC error for a request Compass couldn't answer, so Claude isn't left waiting.
func failure(for line: Data, _ text: String) -> Data? {
    log(text)
    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] else { return nil }
    let reply: [String: Any] = [
        "jsonrpc": "2.0", "id": id,
        "error": ["code": -32000, "message": text]
    ]
    return try? JSONSerialization.data(withJSONObject: reply)
}

/// Compass's initialize answer, saying its tool list can change (the watcher tells).
func listChanging(_ answer: Data) -> Data {
    guard var message = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
        var result = message["result"] as? [String: Any]
    else { return answer }
    var capabilities = result["capabilities"] as? [String: Any] ?? [:]
    var tools = capabilities["tools"] as? [String: Any] ?? [:]
    tools["listChanged"] = true
    capabilities["tools"] = tools
    result["capabilities"] = capabilities
    message["result"] = result
    return (try? JSONSerialization.data(withJSONObject: message)) ?? answer
}

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let body = Data(line.utf8)
    let method = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["method"] as? String
    if method == "notifications/initialized" { await watch.sawInitialized() }
    guard var answer = await forward(body) else { continue }
    if method == "initialize" { answer = listChanging(answer) }
    if method == "tools/list" { _ = await watch.saw(answer) }
    await output.write(answer)
}
