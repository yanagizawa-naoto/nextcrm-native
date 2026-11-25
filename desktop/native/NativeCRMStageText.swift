import Foundation

enum NativeCRMStageText {
    static func render(kind: String, index: Int, settings: NativeCRMAutomationSettings, name: String) -> (title: String, content: String) {
        if kind == "qualified" {
            let titles = ["営業フォロー 1/5：見積もり受領の確認電話", "営業フォロー 2/5：確認メール", "営業フォロー 3/5：メールまたは電話", "営業フォロー 4/5：状況確認の電話", "営業フォロー 5/5：最終確認と見積もり期限の延長提案"]
            let bodies = ["取引先に電話し、見積書・作業範囲の資料が届いているか確認して、不明点を聞いてください。", "提出中の見積もりについて、短い確認メールを送ってください。", "メールまたは電話で懸念点を聞き、説明の機会を提案してください。", "見積もりを提出してから約5週間です。電話で予定時期や進行上の課題を確認してください。", "最終確認のメールを送り、必要であれば見積もりの有効期限を15日延長できることを案内してください。"]
            return (titles[index], bodies[index] + "\n商談：" + name)
        }
        if index == 0 { return ("導入後フォロー：\(settings.careCheckinDays)日後の確認", "導入後の満足度、困りごと、これまでに得られた効果を取引先に確認してください。\n取引先・案件：" + name) }
        if index == 1 { return ("導入後フォロー：紹介の依頼", "導入の成果を確認し、紹介を依頼してください。追加提案の機会も確認してください。\n取引先・案件：" + name) }
        return ("導入後フォロー：定期確認（第\(index - 1)回）", "定期的な関係確認として、満足度、契約更新、利用拡大の機会を話し合ってください。\n取引先・案件：" + name)
    }
}
