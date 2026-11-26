import Foundation
import CoreFoundation

/// Public app identity supplied by the distributor. User tokens and client
/// secrets never belong in this resource; authorization stays in the Keychain.
enum NativeDistributionConfiguration {
    static let resourceName = "DistributionConfiguration"
    static let maximumBytes = 16_384
    struct GoogleClient: Equatable {
        let clientID: String
        var clientSecret: String { "" }
        init(clientID: String) throws {
            guard clientID.utf8.count <= 512,
                  clientID.range(of:#"^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com\z"#,options:.regularExpression) != nil else { throw Failure.invalid }
            self.clientID = clientID
        }
    }
    enum Failure: LocalizedError {
        case invalid, unreadable
        var errorDescription: String? {
            switch self {
            case .invalid:return "配布版のGoogleログイン設定が不正です。アプリの配布元に確認してください。"
            case .unreadable:return "配布版のGoogleログイン設定を読み込めません。アプリを入れ直すか、配布元に確認してください。"
            }
        }
    }
    static func googleClient(bundle: Bundle = .main) throws -> GoogleClient? {
        guard let url = bundle.url(forResource:resourceName,withExtension:"json") else { return nil }
        do {
            let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
            return try googleClient(data:try file.read(upToCount:maximumBytes+1) ?? Data())
        } catch let error as Failure { throw error }
        catch { throw Failure.unreadable }
    }
    static func googleClient(data: Data) throws -> GoogleClient? {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys) == ["version","google"],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else { throw Failure.invalid }
        if object["google"] is NSNull { return nil }
        guard let google = object["google"] as? [String:Any], Set(google.keys) == ["desktopClientID"],
              let id = google["desktopClientID"] as? String else { throw Failure.invalid }
        return try GoogleClient(clientID:id)
    }
}
