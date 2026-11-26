import Foundation

@main enum DistributionConfigurationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label:String)throws {
        guard try value() else { throw NSError(domain:label,code:1) }; checks += 1
    }
    static func main()throws {
        let casesURL=URL(fileURLWithPath:CommandLine.arguments[1]), fixture=URL(fileURLWithPath:CommandLine.arguments[2])
        let cases=try JSONSerialization.jsonObject(with:Data(contentsOf:casesURL)) as! [[String:Any]]
        for item in cases {
            let data=Data((item["json"] as! String).utf8), valid=item["valid"] as! Bool
            do {
                let result=try NativeDistributionConfiguration.googleClient(data:data)
                try check(valid,"unexpected accepted configuration")
                try check(result?.clientID == item["clientID"] as? String,"client identity / disabled state")
                try check(result == nil || result?.clientSecret == "","no distribution secret")
            } catch is NativeDistributionConfiguration.Failure { try check(!valid,"unexpected rejected configuration") }
        }
        let validJSON="{\"version\":1,\"google\":{\"desktopClientID\":\"1234567890-synthetic.apps.googleusercontent.com\"}}"
        let bodies:[String?]=[nil,"{\"version\":1,\"google\":null}",validJSON,"{}",String(repeating:" ",count:20_000)]
        for (index,body) in bodies.enumerated() {
            let root=fixture.appendingPathComponent("test-\(index).bundle"), resources=root.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
            let plist:[String:Any]=["CFBundleIdentifier":"local.nextcrm.distribution-test-\(index)","CFBundlePackageType":"BNDL","CFBundleVersion":"1"]
            try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
            if let body { try Data(body.utf8).write(to:resources.appendingPathComponent("DistributionConfiguration.json")) }
            let bundle=Bundle(url:root)!
            if index<3 {
                let value=try NativeDistributionConfiguration.googleClient(bundle:bundle)
                try check((index==2) == (value != nil),"real bundle resource / missing / disabled")
            } else {
                do { _ = try NativeDistributionConfiguration.googleClient(bundle:bundle); throw NSError(domain:"bad bundle accepted",code:1) }
                catch is NativeDistributionConfiguration.Failure { checks += 1 }
            }
        }
        print("DistributionConfigurationTests: \(checks) checks passed")
    }
}
