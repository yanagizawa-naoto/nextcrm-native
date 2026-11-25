import Foundation

enum NativePluginLocation {
    case admin
    case account(String)
    case product(String)
    case order(String)
    case page(String)
}

/// Small display values only: provider credentials and raw JSON never reach
/// the native table window. Rows are rendered by a reusable NSTableView.
struct NativePluginPresentation {
    struct RecordTarget { let model: String, id: String }
    struct Cell {
        let text: String
        var url: URL? = nil
        var record: RecordTarget? = nil
        init(_ text: String, url: URL? = nil, record: RecordTarget? = nil) { self.text = text; self.url = url; self.record = record }
    }
    struct Section {
        let title: String, columns: [String], rows: [[Cell]]
        var empty: String = "該当する情報はありません。"
    }
    let title: String, sections: [Section]
}
