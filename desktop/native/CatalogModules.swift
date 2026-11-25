import Foundation

extension CRMModule {
    static let catalog: [CRMModule] = [
        CRMModule(model:"crm_Products",title:"商品・サービス",singular:"商品",entity:"product",nameFields:["name"],
                  columns:[CRMColumn("商品名","name",0.32),CRMColumn("コード","sku",0.18),CRMColumn("単価","unit_price+currency",0.22),CRMColumn("状態","status",0.13),CRMColumn("管理元","source",0.15)],
                  fields:[EditorField("name","商品名",required:true),EditorField("sku","商品コード"),EditorField("type","種別",.choice([("PRODUCT","商品"),("SERVICE","サービス")])),EditorField("status","状態",.choice([("DRAFT","下書き"),("ACTIVE","有効"),("ARCHIVED","アーカイブ")])),EditorField("unit_price","販売単価",.number,required:true),EditorField("unit_cost","原価",.number),EditorField("currency","通貨",.relation("Currency"),required:true),EditorField("tax_rate","税率（%）",.number),EditorField("unit","単位"),EditorField("categoryId","カテゴリ",.relation("crm_ProductCategories")),EditorField("is_recurring","継続課金",.toggle),EditorField("billing_period","請求周期",.choice([("MONTHLY","毎月"),("QUARTERLY","3か月ごと"),("ANNUALLY","毎年"),("ONE_TIME","一括")])),description]),
        CRMModule(model:"crm_ProductCategories",title:"商品カテゴリ",singular:"カテゴリ",entity:"product_category",nameFields:["name"],
                  columns:[CRMColumn("カテゴリ名","name",0.4),CRMColumn("親カテゴリ","parentId",0.3,relation:"crm_ProductCategories"),CRMColumn("有効","isActive",0.1),CRMColumn("管理元","source",0.2)],
                  fields:[EditorField("name","カテゴリ名",required:true),EditorField("parentId","親カテゴリ",.relation("crm_ProductCategories")),EditorField("isActive","有効",.toggle),EditorField("order","表示順",.number),description]),
        CRMModule(model:"crm_PriceLists",title:"価格表",singular:"価格表",entity:"price_list",nameFields:["name"],
                  columns:[CRMColumn("価格表名","name",0.5),CRMColumn("通貨","currency",0.15),CRMColumn("有効","isActive",0.15),CRMColumn("管理元","source",0.2)],
                  fields:[EditorField("name","価格表名",required:true),EditorField("currency","通貨",.relation("Currency"),required:true),EditorField("isActive","有効",.toggle)]),
        CRMModule(model:"ExchangeRate",title:"通貨レート",singular:"通貨レート",entity:"exchange_rate",nameFields:["fromCurrency","toCurrency"],
                  columns:[CRMColumn("元通貨","fromCurrency",0.2),CRMColumn("換算先","toCurrency",0.2),CRMColumn("レート","rate",0.3),CRMColumn("適用日","effectiveDate",0.3)],
                  fields:[EditorField("fromCurrency","元通貨",.relation("Currency"),required:true),EditorField("toCurrency","換算先通貨",.relation("Currency"),required:true),EditorField("rate","元通貨1単位の換算額",.number,required:true),EditorField("effectiveDate","適用日時",.dateTime,required:true)])
    ]
    static let priceRule = CRMModule(model:"crm_PriceListRules",title:"価格ルール",singular:"価格ルール",entity:"price_rule",nameFields:["appliesTo","computePrice"],
        columns:[CRMColumn("対象","appliesTo",0.15),CRMColumn("商品","productId",0.25,relation:"crm_Products"),CRMColumn("カテゴリ","categoryId",0.2,relation:"crm_ProductCategories"),CRMColumn("最低数量","minQuantity",0.15),CRMColumn("計算方法","computePrice",0.25)],
        fields:[EditorField("appliesTo","適用対象",.choice([("ALL","全商品"),("CATEGORY","カテゴリ"),("PRODUCT","商品")])),EditorField("productId","対象商品",.relation("crm_Products")),EditorField("categoryId","対象カテゴリ",.relation("crm_ProductCategories")),EditorField("minQuantity","最低数量",.number,required:true),EditorField("dateStart","適用開始日（UTC）",.date),EditorField("dateEnd","適用終了日（UTC）",.date),EditorField("computePrice","計算方法",.choice([("FIXED","固定単価"),("PERCENTAGE","割引率"),("FORMULA","計算式")])),EditorField("fixedPrice","固定単価",.signedNumber),EditorField("percentPrice","割引率（%）",.number),EditorField("base","基準価格",.choice([("LIST_PRICE","販売単価"),("COST","原価"),("PRICE_LIST","別の価格表")])),EditorField("basePriceListId","基準の価格表",.relation("crm_PriceLists")),EditorField("priceDiscount","計算式：割引率（%）",.signedNumber),EditorField("priceRound","計算式：丸め幅",.number),EditorField("priceSurcharge","計算式：加算額",.signedNumber),EditorField("priceMinMargin","計算式：下限加算額",.signedNumber),EditorField("priceMaxMargin","計算式：上限加算額",.signedNumber)])
}
