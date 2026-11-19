#if UI_ACCEPTANCE
import AppKit
import SwiftUI

/// Acceptance-build only: when ZHUYU_SNAPSHOT_DIR is set, the app renders its
/// own windows to PNG (no screen-recording permission involved), at several
/// sizes and with each panel open, then quits.
@MainActor
enum UISnapshot {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["ZHUYU_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: AppModel, showVersionHistory: @escaping (Bool) -> Void) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }) else { return }
        let sizes: [(String, CGFloat, CGFloat)] = [("寬", 1440, 900), ("中", 1100, 720), ("窄", 760, 560)]
        for (name, width, height) in sizes {
            window.setContentSize(NSSize(width: width, height: height))
            try? await Task.sleep(for: .milliseconds(700))
            capture(window, to: directory.appendingPathComponent("主畫面_\(name).png"))
        }
        window.setContentSize(NSSize(width: 1100, height: 720))
        // One utterance still being spoken, as during live recognition.
        model.receiveTranscript(SpeechUpdate(id: "snapshot-live", text: "接下來我們用頻譜分析確認這個峰值的來源，", isFinal: false))
        try? await Task.sleep(for: .milliseconds(900))
        capture(window, to: directory.appendingPathComponent("主畫面_說話中.png"))

        let panels: [(String, (Bool) -> Void)] = [
            ("設定", { model.showsSettings = $0 }),
            ("歷史紀錄", { model.showsHistory = $0 }),
            ("語意環境", { model.showsSemanticEnvironment = $0 }),
            ("版本記錄", showVersionHistory)
        ]
        for (name, toggle) in panels {
            toggle(true)
            try? await Task.sleep(for: .milliseconds(900))
            if let sheet = window.attachedSheet {
                capture(sheet, to: directory.appendingPathComponent("面板_\(name).png"))
                capture(window, to: directory.appendingPathComponent("面板_\(name)_整體.png"), includeSheet: sheet)
            }
            toggle(false)
            try? await Task.sleep(for: .milliseconds(600))
        }
        exit(0)
    }

    private static func capture(_ window: NSWindow, to url: URL, includeSheet sheet: NSWindow? = nil) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let sheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
           let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) {
            sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            rep.draw(in: view.bounds)
            NSColor.black.withAlphaComponent(0.18).setFill()
            view.bounds.fill(using: .sourceOver)
            let origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
            sheetRep.draw(in: NSRect(origin: origin, size: sheetView.bounds.size))
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let composed = NSBitmapImageRep(data: tiff) {
                try? composed.representation(using: .png, properties: [:])?.write(to: url)
            }
            return
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
