import Foundation

extension InvoiceMailTests {
    static func deepLinkTests(admin: CRMService, owner: CRMService, stranger: CRMService, order: NativeRecord) throws {
        let start = checks
        let id = order["id"].string
        let link = try owner.orderLink(order)
        try check(link.string == "nextcrm-native://orders/"+id,"canonical order link")
        try check(try NativeDeepLink(text:" \n"+link.string+"\t ") == link,"pasted surrounding whitespace is accepted")
        try check(try NativeDeepLink(text:"NEXTCRM-NATIVE://ORDERS/"+id.uppercased()) == link,"scheme/host/UUID casing is normalized")
        try check(try owner.orderFromLink(link)["id"] == order["id"],"creator opens same linked order")
        try check(try admin.orderFromLink(link)["id"] == order["id"],"administrator opens linked order")
        try rejects("link grants no access to an unrelated user") { _ = try stranger.orderFromLink(link) }
        try rejects("unrelated user cannot create a share link") { _ = try stranger.orderLink(order) }
        try rejects("missing local record") { _ = try admin.orderFromLink(NativeDeepLink(orderID:UUID().uuidString)) }
        let user = try admin.db.get("Users",key:["id":.text(owner.identity.id)])!
        let banned = try admin.db.update(user,changes:["banned":.integer(1)],actor:admin.identity.id)
        try rejects("recipient deactivated after email cannot open link") { _ = try owner.orderFromLink(link) }
        _ = try admin.db.update(banned,changes:["banned":.integer(0)],actor:admin.identity.id)
        for invalid in [
            "", "https://example.invalid/crm/orders/"+id, "file:///tmp/"+id,
            "nextcrm-native://invoices/"+id, "nextcrm-native://orders", "nextcrm-native://orders/",
            "nextcrm-native://orders/"+id+"/", "nextcrm-native://orders/"+id+"/approve",
            "nextcrm-native://orders/../"+id, "nextcrm-native://orders//"+id,
            "nextcrm-native://orders/"+id+"?action=approve", "nextcrm-native://orders/"+id+"?",
            "nextcrm-native://orders/"+id+"#fragment", "nextcrm-native://orders/"+id+"#",
            "nextcrm-native://name:password@orders/"+id, "nextcrm-native://orders:80/"+id,
            "nextcrm-native://orders:invalid/"+id, "nextcrm-native://orders/%"+"61"+id.dropFirst(),
            "nextcrm-native://orders/"+id+"%00", "nextcrm-native://orders/"+id+"%2Fapprove",
            "nextcrm-native://orders/{"+id+"}", "nextcrm-native://orders/"+id.replacingOccurrences(of:"-",with:""),
            "nextcrm-native://orders/';DROP TABLE Users;--", "nextcrm-native://orders/"+id+"\nother",
            String(repeating:"x",count:4097)
        ] { try rejects("malformed/read-only link validation") { _ = try NativeDeepLink(text:invalid) } }
        var inbox = NativeLinkInbox()
        inbox.receive(link.string)
        try check(try inbox.take(ready:false) == nil && inbox.hasPending,"startup or editing defers link without consuming it")
        try check(try inbox.take(ready:true) == link && !inbox.hasPending,"closing sheet releases pending navigation once")
        try check(try inbox.take(ready:true) == nil,"navigation is not replayed on later sheet events")
        let other = try NativeDeepLink(orderID:UUID().uuidString)
        inbox.receive(link.string); inbox.receive(other.string)
        try check(try inbox.take(ready:true) == other,"multiple arrivals bound queue to latest intent")
        inbox.receive("nextcrm-native://orders/no-secret-in-error?token=FAKE_SECRET")
        try check(try inbox.take(ready:false) == nil && inbox.hasPending,"invalid link does not interrupt editing")
        var failure: Error?
        do { _ = try inbox.take(ready:true) } catch { failure = error }
        try check(failure != nil && !inbox.hasPending && !failure!.localizedDescription.contains("FAKE_SECRET"),"invalid link error contains no raw URL and is consumed once")
        let plist = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Info.plist")),format:nil) as! [String:Any]
        let types = plist["CFBundleURLTypes"] as? [[String:Any]] ?? []
        try check(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("nextcrm-native") == true && $0["CFBundleTypeRole"] as? String == "Viewer" },"application declares read-only native URL handler")
        try check(try admin.db.get("crm_Orders",key:["id":order["id"]])?.revision == order.revision,"link operations never modify order")
        print("Native order links: \(checks-start) checks passed")
    }
}
