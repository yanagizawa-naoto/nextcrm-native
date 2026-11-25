import Foundation
import Darwin

@main
struct StoreTool {
    static func main() {
        umask(0o077)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 3, args[0] == "import" else { throw StoreError.message("Usage: NativeStoreTool import source.jsonl destination.sqlite") }
            let store = try AccountStore(url: URL(fileURLWithPath: args[2]))
            let imported = try store.importJSONLines(URL(fileURLWithPath: args[1]))
            let total = try store.page().total
            let data = try JSONSerialization.data(withJSONObject: ["imported": imported, "total": total], options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
}
