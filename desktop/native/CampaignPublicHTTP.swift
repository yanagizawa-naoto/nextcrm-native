import Foundation

/// Transport-independent public routes. A public receiver/relay must provide
/// durable availability; merely constructing this adapter does not enable mail.
struct CampaignPublicHTTP {
    struct Response { let status: Int; let headers: [String:String]; let body: Data }
    let db: NativeDatabase
    let configuration: CampaignMailConfiguration
    let webhookSecret: () throws -> String
    let clock: () -> Date
    init(db: NativeDatabase, configuration: CampaignMailConfiguration, webhookSecret: @escaping () throws -> String, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.configuration = configuration; self.webhookSecret = webhookSecret; self.clock = clock
    }
    private func response(_ status: Int,_ text: String, html: Bool = false, allow: String? = nil) -> Response {
        var headers = ["Content-Type":html ? "text/html; charset=utf-8" : "text/plain; charset=utf-8","Cache-Control":"no-store","Referrer-Policy":"no-referrer","X-Content-Type-Options":"nosniff","Content-Security-Policy":"default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"]
        if let allow { headers["Allow"] = allow }
        return Response(status:status,headers:headers,body:Data(text.utf8))
    }
    func handle(method: String, target: String, headers: [String:String] = [:], body: Data = Data()) -> Response {
        guard target.utf8.count <= 4096, target.hasPrefix("/"),
              let url = URLComponents(string:target), url.scheme == nil, url.host == nil, url.fragment == nil else { return response(400,"リンクが不正です。") }
        let prefix = configuration.publicURL.path
        if url.path == prefix+"/api/campaigns/unsubscribe" {
            guard method == "GET" else { return response(405,"この操作は利用できません。",allow:"GET") }
            let tokens = url.queryItems?.filter{$0.name == "token"} ?? []
            guard tokens.count == 1, let token = tokens[0].value, UUID(uuidString:token) != nil else { return response(400,"配信停止リンクが不正です。") }
            do {
                guard try db.unsubscribeCampaign(token:token,now:clock()) != nil else { return response(404,"配信停止リンクが見つかりません。") }
                return response(200,"<!doctype html><html lang=\"ja\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>配信停止</title></head><body style=\"font-family:sans-serif;text-align:center;padding:40px\"><h1>配信停止を受け付けました</h1><p>この送信元からの案内メールの配信を停止しました。</p></body></html>",html:true)
            } catch { return response(503,"配信停止を保存できませんでした。時間をおいて、同じリンクからもう一度お試しください。") }
        }
        if url.path == prefix+"/api/campaigns/webhooks/resend" {
            guard method == "POST" else { return response(405,"この操作は利用できません。",allow:"POST") }
            guard body.count <= CampaignWebhook.maximumBodyBytes else { return response(413,"受信内容が大きすぎます。") }
            do {
                _ = try CampaignWebhook.receive(db:db,body:body,headers:headers,secret:webhookSecret(),now:clock())
                return response(200,"ok")
            } catch CampaignWebhook.Failure.unauthorized { return response(401,"署名を確認できません。") }
            catch CampaignWebhook.Failure.invalid { return response(400,"配信結果の形式が不正です。") }
            catch { return response(503,"配信結果を保存できませんでした。") }
        }
        return response(404,"ページが見つかりません。")
    }
}
