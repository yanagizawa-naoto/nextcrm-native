import Foundation

/// The one-slot baseline intentionally uses the generic transport directly;
/// the production settings will refuse it after the compatibility fix.
@main enum NativeMCPSDKAdmissionFixture {
    static func emit(_ value: [String:Any]) throws { print(String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)); fflush(stdout) }
    static func main() async {
        do { try await run() } catch { print("{\"failed\":true}"); exit(1) }
    }
    static func run() async throws {
            let maximum = Int(CommandLine.arguments[1])!
            let protocolLayer = try NativeMCPProtocol(tools:[["name":"fixture_echo","description":"isolated admission test","inputSchema":["type":"object"]]]) { _,_,_ in ["content":[["type":"text","text":"{\"ok\":true}"]]] }
            let server = try NativeMCPHTTPServer(configuration:.init(maximumConnections:maximum,heartbeatInterval:0.1)) { await protocolLayer.handle($0) }
            let url = try await server.start(); try emit(["ready":url.absoluteString,"maximum":maximum,"tool":"fixture_echo"])
            while let line = readLine() {
                if line == "quit" { await server.stop(); try emit(["stopped":true]); return }
                let s = await server.snapshot(); try emit(["connections":s.connections,"retained":s.retainedPeers,"rejected":s.rejected])
            }
            await server.stop()
    }
}
