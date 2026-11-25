import Foundation

struct LineContext {
    let parentModel: String; let field: String; let totalField: String?
    static func forModel(_ model: String) -> LineContext? {
        switch model {
        case "crm_AccountProducts": return LineContext(parentModel:"crm_Accounts",field:"accountId",totalField:nil)
        case "crm_OpportunityLineItems": return LineContext(parentModel:"crm_Opportunities",field:"opportunityId",totalField:"expected_revenue")
        case "crm_ContractLineItems": return LineContext(parentModel:"crm_Contracts",field:"contractId",totalField:"value")
        default: return nil
        }
    }
    static func childModel(_ parent: String) -> String? {
        ["crm_Accounts":"crm_AccountProducts","crm_Opportunities":"crm_OpportunityLineItems","crm_Contracts":"crm_ContractLineItems"][parent]
    }
}

extension CRMModule {
    static let assignment = CRMModule(model:"crm_AccountProducts",title:"商品割当",singular:"商品割当",entity:"account_product",nameFields:[],
        columns:[CRMColumn("取引先","accountId",0.25,relation:"crm_Accounts"),CRMColumn("商品","productId",0.27,relation:"crm_Products"),CRMColumn("数量","quantity",0.08),CRMColumn("特別単価","custom_price+currency",0.18),CRMColumn("状態","status",0.12),CRMColumn("開始日","start_date",0.10)],
        fields:[EditorField("productId","商品",.relation("crm_Products"),required:true),EditorField("quantity","数量",.number,required:true),EditorField("custom_price","特別単価（任意）",.number),EditorField("currency","通貨",.relation("Currency"),required:true),EditorField("status","状態",.choice([("ACTIVE","有効"),("PENDING","確認待ち"),("EXPIRED","期限切れ"),("CANCELLED","取消済み")])),EditorField("start_date","開始日",.date,required:true),EditorField("end_date","終了日",.date),EditorField("renewal_date","更新日",.date),EditorField("notes","メモ",.multiline)])
    static let lineModules = [assignment, makeLines(contract:false), makeLines(contract:true)]
    private static func makeLines(contract: Bool) -> CRMModule {
        CRMModule(model:contract ? "crm_ContractLineItems" : "crm_OpportunityLineItems",title:contract ? "契約明細" : "商談明細",singular:"明細",entity:contract ? "contract_line_item" : "opportunity_line_item",nameFields:["name"],
            columns:[CRMColumn("名称","name",0.31),CRMColumn("商品コード","sku",0.15),CRMColumn("数量","quantity",0.08),CRMColumn("単価","unit_price",0.15),CRMColumn("値引","discount_value+discount_type",0.13),CRMColumn("合計","line_total+currency",0.18)],
            fields:[EditorField("productId","商品（任意）",.relation("crm_Products")),EditorField("name","名称",required:true),EditorField("sku","商品コード"),EditorField("quantity","数量",.number,required:true),EditorField("unit_price","単価",.number,required:true),EditorField("discount_type","値引き方法",.choice([("PERCENTAGE","割合（%）"),("FIXED","定額")])),EditorField("discount_value","値引率・値引額",.number,required:true),description])
    }
}
