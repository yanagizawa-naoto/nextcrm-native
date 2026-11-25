import AppKit

enum CampaignTemplatePreviewDocument {
    static let sample = ["first_name":"花子","last_name":"山田","email":"sample@example.invalid","company":"サンプル株式会社","position":"営業担当"]
    static func make(html:String,subject:String,check:@escaping ()throws->Void = {}) throws -> NativeMailHTMLDocument {
        try check()
        let resolved=try CampaignMergeTags.resolveBounded(html,target:sample,escaped:true,maximumBytes:CampaignHTML.maximumInputBytes)
        var rendered="",bytes=0
        try CampaignHTML.render(resolved,unsubscribeURL:URL(string:"#")!) { chunk in
            try check();bytes += chunk.utf8.count
            guard bytes <= NativeMailHTMLDocument.maximumBytes else {throw NativeDBError.message("プレビューのHTMLが8 MiBを超えています。本文は変更していません。保存・送信は引き続き利用できます。")}
            rendered += chunk
        }
        try check();return try .init(subject:"プレビュー："+subject,html:rendered)
    }
}

/// Owns only the explicitly requested, disposable preview. Neither a browser
/// nor a database mutation is created by constructing this controller.
final class CampaignTemplatePreview:NSObject {
    typealias Viewer=(NativeMailHTMLDocument,@escaping ()->Void)throws->NativeMailHTMLDrainingViewing
    typealias Render=(String,String,@escaping ()throws->Void)throws->NativeMailHTMLDocument
    let view=NSStackView(), notice=NSTextField(wrappingLabelWithString:"")
    let reload=NSButton(title:"プレビューを再表示",target:nil,action:nil)
    private let factory:Viewer, render:Render, authorize:()throws->Void
    private let queue=MemoryBudget.queue(label:"local.nextcrm.native.template-preview")
    private var viewer:NativeMailHTMLDrainingViewing?, draining:NativeMailHTMLDrainingViewing?
    private var request:(html:String,subject:String)?, cancellation:Cancellation?, generation=0
    private(set) var isPreparing=false
    var isShowing:Bool {viewer != nil}
    var isDraining:Bool {draining != nil}
    private final class Cancellation {
        private let lock=NSLock();private var cancelled=false
        func cancel(){lock.lock();cancelled=true;lock.unlock()}
        func check()throws{lock.lock();defer{lock.unlock()};if cancelled{throw CancellationError()}}
    }
    init(authorize:@escaping ()throws->Void,makeViewer:@escaping Viewer = {try NativeMailHTMLSession(document:$0,onFailure:$1)},render:@escaping Render = {try CampaignTemplatePreviewDocument.make(html:$0,subject:$1,check:$2)}) {
        self.authorize=authorize;factory=makeViewer;self.render=render
        super.init();view.orientation = .vertical;view.alignment = .leading;view.spacing=12
        view.edgeInsets=NSEdgeInsets(top:18,left:18,bottom:18,right:18)
        notice.maximumNumberOfLines=0;notice.setAccessibilityLabel("テンプレートのプレビュー状態")
        reload.target=self;reload.action=#selector(reopen);reload.bezelStyle = .rounded
        view.addArrangedSubview(notice);view.addArrangedSubview(reload)
        view.autoresizingMask = [.width];view.frame=NSRect(x:0,y:0,width:800,height:160)
        notice.widthAnchor.constraint(lessThanOrEqualTo:view.widthAnchor,constant:-36).isActive=true
    }
    func show(html:String,subject:String) {
        dispatchPrecondition(condition:.onQueue(.main))
        generation += 1;cancellation?.cancel()
        request=(html,subject);retire()
        if isPreparing {notice.stringValue="前の処理を終了して、最新のプレビューに更新します…"}
        startIfReady()
    }
    @objc private func reopen(){guard let request else{return};show(html:request.html,subject:request.subject)}
    func close() {
        dispatchPrecondition(condition:.onQueue(.main))
        generation += 1;request=nil;cancellation?.cancel();retire()
    }
    private func retire() {
        guard let old=viewer else{return};viewer=nil;draining=old
        old.closeAndDrain { [weak self,old] in
            guard let self,self.draining === old else{return};self.draining=nil;self.startIfReady()
        }
    }
    private func startIfReady() {
        guard let input=request,!isPreparing,viewer==nil else{return}
        guard draining==nil else{notice.stringValue="前のプレビューを閉じています…";return}
        do {try authorize()} catch {notice.stringValue=error.localizedDescription;return}
        let token=Cancellation(),ticket=generation,render=render
        cancellation=token;isPreparing=true;notice.stringValue="プレビューを作成しています…"
        queue.async { [weak self] in
            let result=Result {try render(input.html,input.subject,{try token.check()})}
            DispatchQueue.main.async { [weak self] in
                guard let self,self.cancellation === token else{return}
                self.isPreparing=false;self.cancellation=nil
                guard self.generation==ticket,self.request != nil else{self.startIfReady();return}
                do {
                    let document=try result.get();try token.check();try self.authorize()
                    self.viewer=try self.factory(document) { [weak self] in
                        guard let self,self.generation==ticket else{return}
                        self.notice.stringValue="プレビューを表示できませんでした。「プレビューを再表示」で再試行できます。"
                    }
                    self.notice.stringValue="別ウィンドウでプレビューを表示しています。外部の画像・スタイルは、表示側で明示的に許可した場合だけ読み込みます。\n編集に戻るとプレビューは閉じます。本文と保存内容は変更していません。"
                } catch is CancellationError {} catch {self.notice.stringValue=error.localizedDescription}
            }
        }
    }
    deinit {cancellation?.cancel();viewer?.close();draining?.close()}
}
