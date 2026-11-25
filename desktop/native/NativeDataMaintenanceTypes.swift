import Foundation

enum NativeDataMaintenanceKind:String {case backup,restore}
struct NativeDataMaintenanceArtifact {
    let kind:NativeDataMaintenanceKind;let url:URL
    let backup:NativeBackupResult?;let restore:NativeRestoreResult?
    var snapshotID:String{backup?.snapshotID ?? restore?.snapshotID ?? ""}
}
struct NativeDataMaintenanceOutcome {
    enum State {case completed,cancelled,failed}
    let state:State;let artifact:NativeDataMaintenanceArtifact?;let message:String;let cleanupPending:Bool
}
final class NativeDataMaintenanceOperation {
    enum State {case running,cancelled,committing,completed,failed}
    struct Progress {let state:State;let message:String}
    private let lock=NSLock();private var state:State = .running;private var message="準備しています…"
    var cancelled:Bool{lock.lock();defer{lock.unlock()};return state == .cancelled}
    var progress:Progress{lock.lock();defer{lock.unlock()};return .init(state:state,message:message)}
    @discardableResult func cancel()->Bool {lock.lock();defer{lock.unlock()};guard state == .running else{return state == .cancelled};state = .cancelled;message="中止して作成途中のファイルを回収しています…";return true}
    func report(_ text:String){lock.lock();defer{lock.unlock()};if state == .running{message=text}}
    func seal()throws {lock.lock();defer{lock.unlock()};guard state == .running else{throw CancellationError()};state = .committing;message="保存内容を確定しています…"}
    func finish(success:Bool){lock.lock();defer{lock.unlock()};if success{state = .completed;message="保存しました。"}else if state != .cancelled{state = .failed}}
}
