import Foundation

@main struct NativeMailMIMEBoundaryTests {
    struct Fixture: Decodable {
        struct Case: Decodable { let name: String, input: String, expected: String, subject: String, fromName: String }
        let cases: [Case]
    }
    static func main() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var checks = 0, differences: [[String: String]] = []
        func check(_ actual: String, _ expected: String, _ name: String) {
            checks += 1
            if !actual.utf16.elementsEqual(expected.utf16) { differences.append(["name": name, "actual": actual, "expected": expected]) }
        }
        for sample in fixture.cases {
            check(NativeMailMIME.decodedWords(sample.input), sample.expected, sample.name + "/words")
            let raw = "From: \(sample.input) <sender@example.test>\r\nTo: receiver@example.test\r\nSubject: \(sample.input)\r\n\r\nbody"
            let headers = try NativeMailMIME.headers(Data(raw.utf8))
            check(headers.subject ?? "", sample.subject, sample.name + "/subject")
            check(NativeMailMIME.addresses(headers["from"]).first?.name ?? "", sample.fromName, sample.name + "/name")
        }
        check(NativeMailMIME.decodedWords("prefix =?UTF-8?B?invalid!?= suffix"), "prefix =?UTF-8?B?invalid!?= suffix", "existing-malformed-preservation")
        check(NativeMailMIME.decodedWords(String(repeating: "x", count: NativeMailMIME.maximumHeaderBytes + 1)), "", "existing-input-cap")
        let pair = "=?UTF-8?B?5g==?= =?UTF-8?B?l6U=?="
        let repeats = NativeMailMIME.maximumHeaderBytes / (pair.utf8.count + 1)
        let large = Array(repeating: pair, count: repeats).joined(separator: " ")
        check(NativeMailMIME.decodedWords(large), String(repeating: "日", count: repeats), "near-cap-many-split-words")
        let malformed = "=?UTF-8?B?5pel?= =?UTF-8?B?invalid!?= =?UTF-8?B?5pys?="
        check(NativeMailMIME.decodedWords(malformed), "日 =?UTF-8?B?invalid!?= 本", "invalid-token-keeps-group-boundaries")
        check(NativeMailMIME.decodedWords("=?UTF-8?Q?=ZX?="), "=?UTF-8?Q?=ZX?=", "invalid-Q-remains-visible")
        let output: [String: Any] = ["checks": checks, "cases": fixture.cases.count, "differences": differences, "differenceCount": differences.count]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        if !differences.isEmpty { exit(1) }
    }
}
