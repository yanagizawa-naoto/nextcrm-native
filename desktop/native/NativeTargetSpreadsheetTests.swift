import AppKit
@main @MainActor enum NativeTargetSpreadsheetTests {
    static func main() async throws {
        try NativeTargetSpreadsheetParserTests.main()
        try NativeTargetSpreadsheetServiceTests.main()
        try await NativeTargetSpreadsheetControllerTests.main()
        try await NativeTargetSpreadsheetUITests.main()
    }
}
