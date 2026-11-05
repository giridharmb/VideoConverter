import SwiftUI
import AppKit

@main
struct VideoConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1440, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Media…") { store.importFiles() }.keyboardShortcut("o")
                Button("Add Folder…") { store.importFiles(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Conversion") {
                Button("Start Queue") { store.send(.start) }.keyboardShortcut("r")
                Button("Stop Scheduling") { store.send(.stopScheduling) }.keyboardShortcut(".")
                Divider()
                Button("Pause Selected") { store.send(.pause(store.selection)) }
                Button("Resume Selected") { store.send(.resume(store.selection)) }
                Button("Cancel Selected") { store.send(.cancel(store.selection)) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if terminating { return .terminateLater }
        if !store.activeJobs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Stop active work and quit?"
            alert.informativeText = "Active conversions will be cancelled. Your queue is saved so you can retry them next time."
            alert.addButton(withTitle: "Stop and Quit"); alert.addButton(withTitle: "Keep Converting")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        terminating = true
        Task { await store.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
