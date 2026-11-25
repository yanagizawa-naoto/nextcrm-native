import AppKit

@MainActor final class NativeTerminationRunLoopProbe:NSObject,NSApplicationDelegate {
    let root=NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:240),styleMask:[.titled],backing:.buffered,defer:false)
    let sheet=NSPanel(contentRect:NSRect(x:0,y:0,width:280,height:180),styleMask:[.titled],backing:.buffered,defer:false)
    var sheetClosed=false,shutdownFinished=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        root.isReleasedWhenClosed=false;sheet.isReleasedWhenClosed=false
        root.title="終了の非同期処理を検証"
        root.beginSheet(sheet) { [weak self] _ in self?.sheetClosed=true }
        Task { @MainActor in
            NativeSheetTermination.dismiss(in:root)
            NativeSheetTermination.scheduleApplicationQuit { NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        precondition(sheetClosed && root.attachedSheet==nil)
        Task { @MainActor in
            // A real suspension ensures this cannot accidentally succeed by
            // replying synchronously before AppKit enters its nested loop.
            try? await Task.sleep(nanoseconds:20_000_000)
            shutdownFinished=true
            sender.reply(toApplicationShouldTerminate:true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification:Notification) {
        precondition(shutdownFinished && sheetClosed)
        print("NativeTerminationRunLoopTests: sheet close, suspended MainActor drain and terminateLater reply completed")
        fflush(stdout)
    }
}
@main enum NativeTerminationRunLoopTests {
    @MainActor static func main() {
        let app=NSApplication.shared,probe=NativeTerminationRunLoopProbe()
        app.setActivationPolicy(.accessory);app.delegate=probe
        app.run();withExtendedLifetime(probe){}
    }
}
