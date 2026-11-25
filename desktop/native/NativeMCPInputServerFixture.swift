import Foundation

/// Full source catalog over real TCP, with synthetic effects only.
/// This executable is never included in the application.
@main enum NativeMCPInputServerFixture {
    actor Calls {
        var count = 0
        func called() { count += 1 }
    }
    static func emit(_ object: [String: Any]) {
        print(String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout)
    }
    static func main() async {
        do { try await run() }
        catch { emit(["fatal": String(describing: error)]); exit(1) }
    }
    // Keep the blocking test control pipe off async main's MainActor. Network
    // callbacks must not inherit an actor blocked inside readLine().
    static func run() async throws {
            let catalog = try NativeMCPInputCatalog(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let calls = Calls()
            let protocolLayer = try NativeMCPProtocol(tools: catalog.tools) { name, input, id in
                try await catalog.dispatch(tool: name, arguments: input, id: id) { _, normalized, _ in
                    await calls.called()
                    let bytes = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
                    return ["content": [["type": "text", "text": String(decoding: bytes, as: UTF8.self)]]]
                }
            }
            let server = try NativeMCPHTTPServer(configuration: .init(heartbeatInterval: 0.1)) { request in await protocolLayer.handle(request) }
            let url = try await server.start(); emit(["ready": url.absoluteString])
            while let command = readLine() {
                if command == "stats" { emit(["effects": await calls.count]) }
                if command == "quit" { break }
            }
            await server.stop(); emit(["stopped": true])
    }
}
