import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var applicationIcon: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
    }

    func installApplicationIcon() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.png")
        if applicationIcon == nil { applicationIcon = NSImage(contentsOf: url) }
        if let applicationIcon { NSApp.applicationIconImage = applicationIcon }
    }

    func showAbout() {
        installApplicationIcon()
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let applicationIcon { options[.applicationIcon] = applicationIcon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            #if NATIVE_CAPTURE_ACCEPTANCE
            await NativeCaptureAcceptance.shared.stop()
            #endif
            await model.finishForTermination()
            model.persist()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ZhuyuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState<Bool> private var showsVersionHistory = false
    #if UI_ACCEPTANCE
    @ViewState<AppModel> private var model = AppModel(demo: true)
    #else
    @ViewState<AppModel> private var model = AppModel()
    #endif

    var body: some Scene {
        WindowGroup("逐語") {
            ContentView(model: model, showsVersionHistory: $showsVersionHistory)
                .preferredColorScheme(.light)
                .onAppear {
                    delegate.model = model
                    delegate.installApplicationIcon()
                    NSApp.activate(ignoringOtherApps: true)
                    #if UI_ACCEPTANCE
                    Task { await UISnapshot.run(model: model) { showsVersionHistory = $0 } }
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1250, height: 850)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("關於逐語") { delegate.showAbout() }
                Button("版本記錄") { showsVersionHistory = true }
            }
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { model.showsSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("開始新對話") { model.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.isBusy)
            }
            CommandMenu("逐字稿") {
                Button("語意環境") { model.showsSemanticEnvironment = true }
                Button(model.isRecording ? "停止辨識" : "開始辨識") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy || model.isDemo)
                Button("歷史紀錄") { model.showsHistory = true }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("匯出 Markdown") {
                    if let conversation = model.currentConversation { model.export(conversation, format: .markdown) }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.currentConversation?.hasContent != true)
                Button("匯出 TXT") {
                    if let conversation = model.currentConversation { model.export(conversation, format: .text) }
                }
                .disabled(model.currentConversation?.hasContent != true)
            }
            #if UI_ACCEPTANCE
            CommandMenu("介面驗收") {
                Button("660 × 520") { NSApp.keyWindow?.setContentSize(NSSize(width: 660, height: 520)) }
                Button("800 × 600") { NSApp.keyWindow?.setContentSize(NSSize(width: 800, height: 600)) }
                Button("1024 × 720") { NSApp.keyWindow?.setContentSize(NSSize(width: 1024, height: 720)) }
                Button("1440 × 850") { NSApp.keyWindow?.setContentSize(NSSize(width: 1440, height: 850)) }
            }
            #if NATIVE_CAPTURE_ACCEPTANCE
            CommandMenu("收音驗收") {
                Button("驗收電腦播放聲音") { NativeCaptureAcceptance.shared.run(.system) }
                Button("驗收麥克風") { NativeCaptureAcceptance.shared.run(.microphone) }
                Button("查看內容尺寸") { NativeCaptureAcceptance.shared.showContentSize() }
            }
            #endif
            #endif
        }
    }
}
