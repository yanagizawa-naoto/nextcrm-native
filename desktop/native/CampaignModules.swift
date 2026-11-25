import Foundation

extension CRMModule {
    static let campaignHeader = CRMModule(model:"crm_campaigns",title:"キャンペーン",singular:"キャンペーン",entity:"campaign",nameFields:["name"],columns:[],fields:[
        EditorField("name","キャンペーン名",required:true),EditorField("description","説明",.multiline),EditorField("from_name","差出人名"),EditorField("reply_to","返信先メールアドレス"),EditorField("template_id","標準テンプレート",.relation("crm_campaign_templates"))
    ])
    static let campaignStep = CRMModule(model:"crm_campaign_steps",title:"配信手順",singular:"配信手順",entity:"campaignStep",nameFields:["subject"],columns:[],fields:[
        EditorField("order","順番（初回は0）",.number,required:true),EditorField("template_id","メールテンプレート",.relation("crm_campaign_templates"),required:true),EditorField("subject","件名",required:true),EditorField("delay_days","初回配信からの日数",.number,required:true),EditorField("send_to","送信先",.choice([("all","すべての送信先"),("non_openers","初回が未開封の送信先")]))
    ])
}
