import AppKit

final class NativeAccountCaseStudyWindow: NSObject, NSWindowDelegate {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:620,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    private let service:CRMService,id:String
    private var state:NativeAccountCaseStudyState?
    private var operation:Task<Void,Never>?
    private var closed=false
    private let name=NSTextField(labelWithString:""),status=NSTextField(labelWithString:""),message=NSTextField(wrappingLabelWithString:"")
    private let candidate=NSButton(title:"候補にする",target:nil,action:nil),approval=NSButton(title:"導入事例を承認",target:nil,action:nil)
    private let reloadButton=NSButton(title:"再読込",target:nil,action:nil),closeButton=NSButton(title:"閉じる",target:nil,action:nil)
    var onChanged:(()->Void)?
    var isBusy:Bool {operation != nil}
    init(service:CRMService,accountID:String) throws {
        self.service=service;id=accountID;super.init()
        window.title="導入事例";window.isReleasedWhenClosed=false;window.delegate=self
        name.font = .systemFont(ofSize:20,weight:.semibold);name.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize:14,weight:.semibold)
        let explanation=NSTextField(wrappingLabelWithString:"成果のある顧客を候補として登録します。事例の紹介にはマネージャーの承認が必要です。候補を取り下げると承認も取り消されます。")
        explanation.textColor = .secondaryLabelColor
        candidate.target=self;candidate.action=#selector(changeCandidate);candidate.identifier = .init("case-study-candidate")
        approval.target=self;approval.action=#selector(changeApproval);approval.identifier = .init("case-study-approval")
        reloadButton.target=self;reloadButton.action=#selector(reload);reloadButton.identifier = .init("case-study-reload")
        closeButton.target=self;closeButton.action=#selector(close);closeButton.keyEquivalent="\u{1b}"
        message.setAccessibilityLabel("導入事例の操作結果");message.identifier = .init("case-study-message")
        let actions=NSStackView(views:[candidate,approval,NSView()]);actions.spacing=10
        let footer=NSStackView(views:[reloadButton,NSView(),closeButton]);footer.spacing=8
        let stack=NSStackView(views:[name,status,explanation,actions,message,footer]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=14;stack.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24),stack.bottomAnchor.constraint(lessThanOrEqualTo:window.contentView!.bottomAnchor,constant:-20),name.widthAnchor.constraint(equalTo:stack.widthAnchor),explanation.widthAnchor.constraint(equalTo:stack.widthAnchor),actions.widthAnchor.constraint(equalTo:stack.widthAnchor),message.widthAnchor.constraint(equalTo:stack.widthAnchor),footer.widthAnchor.constraint(equalTo:stack.widthAnchor)])
        state=try service.accountCaseStudy(id);render()
    }
    private func render() {
        name.stringValue=state.map{CRMModule.displayName($0.account)} ?? "取引先"
        status.stringValue=state.map{"状態："+$0.label} ?? "最新の状態を確認してください"
        candidate.title=state?.candidate == true ? "候補を取り下げる":"候補にする"
        approval.title=state?.approved == true ? "承認を取り消す":"導入事例を承認"
        candidate.isEnabled = !isBusy && !closed && state?.canSetCandidate == true
        approval.isHidden = !(state?.canApprove == true && (state?.candidate == true || state?.approved == true))
        approval.isEnabled = !isBusy && !closed && !approval.isHidden
        reloadButton.isEnabled = !isBusy && !closed;closeButton.isEnabled = !isBusy && !closed
    }
    @objc private func changeCandidate() {guard let state,state.canSetCandidate else{return};perform(approval:false,value:!state.candidate)}
    @objc private func changeApproval() {guard let state,state.canApprove else{return};perform(approval:true,value:!state.approved)}
    private func perform(approval:Bool,value:Bool) {
        guard operation == nil,!closed,let state else{return}
        let expected=state.account,service=service,id=id
        message.stringValue="保存しています…"
        operation=Task { @MainActor [weak self] in
            let result=await Task.detached { () -> Result<NativeAccountCaseStudyState,Error> in
                Result {
                    if approval {_ = try service.setAccountCaseStudyApproved(expected,approved:value)}
                    else {_ = try service.setAccountCaseStudyCandidate(expected,candidate:value)}
                    return try service.accountCaseStudy(id)
                }
            }.value
            guard let self else{return};self.operation=nil
            switch result {
            case let .success(value):self.state=value;self.message.stringValue="保存しました。";self.onChanged?()
            case let .failure(error):self.state=nil;self.message.stringValue=error.localizedDescription+" 再読込して状態を確認してください。"
            }
            self.render()
        }
        render()
    }
    @objc private func reload() {
        guard !isBusy,!closed else{return}
        do {state=try service.accountCaseStudy(id);message.stringValue=""}
        catch {state=nil;message.stringValue=error.localizedDescription}
        render()
    }
    func confirmDiscard()->Bool { !isBusy }
    func windowShouldClose(_ sender:NSWindow)->Bool {if !confirmDiscard(){return false};close();return false}
    @objc private func close() {guard confirmDiscard(),!closed else{return};closed=true;if let parent=window.sheetParent {parent.endSheet(window)} else {window.close()}}
}
