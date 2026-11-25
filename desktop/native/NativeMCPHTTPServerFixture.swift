import Foundation

/// Test executable only. Never included in the app or its dispatcher.
@main enum NativeMCPHTTPServerFixture {
    actor Metrics {
        var calls = 0, completed = 0, cancelled = 0
        func began() { calls += 1 }
        func finished() { completed += 1 }
        func interrupted() { cancelled += 1 }
        var snapshot: [String: Int] { ["calls": calls, "completed": completed, "cancelled": cancelled] }
    }
    static func emit(_ object: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self)); fflush(stdout)
    }
    static func main() async {
        do { try await run() }
        catch { emit(["fatal": String(describing: error)]); exit(1) }
    }
    static func run() async throws {
        let metrics = Metrics()
        let catalog: [[String: Any]] = [["name": "fixture_echo", "description": "Isolated transport fixture", "inputSchema": ["type": "object", "properties": ["text": ["type": "string"], "delay": ["type": "number"], "size": ["type": "integer"]], "required": ["text"]]]]
        let protocolLayer = try NativeMCPProtocol(tools: catalog) { _, arguments, _ in
            await metrics.began()
            do {
                // Deliberately noncooperative test-only work: a canceled
                // handler must retain its admission slot until it really ends.
                if let hold = arguments["hold"] as? Double, hold > 0 {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + min(hold, 5)) { continuation.resume() }
                    }
                }
                if let delay = arguments["delay"] as? Double, delay > 0 { try await Task.sleep(nanoseconds: UInt64(min(delay, 60) * 1_000_000_000)) }
                try Task.checkCancellation()
                let text: String
                if let size = arguments["size"] as? Int { text = String(repeating: "x", count: min(max(0, size), 8 * 1024 * 1024)) }
                else { text = arguments["text"] as? String ?? "" }
                await metrics.finished()
                return ["content": [["type": "text", "text": text]]]
            } catch { await metrics.interrupted(); throw error }
        }
        let server = try NativeMCPHTTPServer(configuration: .init(maximumConnections: 4, readTimeout: 1.2, requestTimeout: 3.5, sendTimeout: 1.2, heartbeatInterval: 0.08)) { request in
            await protocolLayer.handle(request)
        }
        var url = try await server.start()
        emit(["ready": url.absoluteString, "pid": ProcessInfo.processInfo.processIdentifier])
        while let command = readLine() {
            switch command {
            case "snapshot":
                let stats = await server.snapshot()
                emit(["snapshot": ["connections": stats.connections, "runningRequests": stats.runningRequests, "retainedPeers": stats.retainedPeers, "peakConnections": stats.peakConnections, "peakQueuedWrites": stats.peakQueuedWrites, "accepted": stats.accepted, "rejected": stats.rejected], "metrics": await metrics.snapshot])
            case "restart":
                await server.stop(); url = try await server.start(); emit(["ready": url.absoluteString])
            case "duplicate-start":
                do { _ = try await server.start(); emit(["duplicateRejected": false]) }
                catch { emit(["duplicateRejected": true]) }
            case "bind-conflict":
                let competing = try NativeMCPHTTPServer(configuration: .init(port: UInt16(url.port!))) { _ in .init(status: 200) }
                var rejected = false
                do { _ = try await competing.start() } catch { rejected = true }
                await competing.stop(); emit(["bindConflictRejected": rejected])
            case "cancel-start":
                let temporary = try NativeMCPHTTPServer { _ in .init(status: 200) }
                let startup = Task { try await temporary.start() }; startup.cancel()
                var cancelled = false
                do { _ = try await startup.value } catch { cancelled = true }
                await temporary.stop(); emit(["cancelledStartup": cancelled])
            case "fixed-restart":
                await server.stop()
                let fixed = try NativeMCPHTTPServer(configuration: .init(port: UInt16(url.port!))) { _ in .init(status: 200) }
                let first = try await fixed.start(); await fixed.stop()
                let second = try await fixed.start(); await fixed.stop()
                url = try await server.start(); emit(["fixedPortReused": first.port == second.port, "ready": url.absoluteString])
            case "concurrent-stop":
                async let one: Void = server.stop()
                async let two: Void = server.stop()
                _ = await (one, two); emit(["stopped": true])
            case "stop":
                await server.stop(); emit(["stopped": true])
            case "quit":
                await server.stop(); emit(["stopped": true]); return
            default: emit(["unknownCommand": true])
            }
        }
        await server.stop()
    }
}
