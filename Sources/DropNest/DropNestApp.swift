import AppKit
import SwiftUI
import CoreGraphics

@main
enum DropNestApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var panel: NSPanel!
    private var settings: NSWindow?
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        model.showSettings = { [weak self] in self?.model.settingsTab = 0; self?.openSettings() }
        model.showSearch = { [weak self] in self?.openSearch() }
        panel = DropPanel(contentRect: NSRect(x: 0, y: 0, width: DropPanelLayout.width, height: DropPanelLayout.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = false; panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        // Keep the drop zone above Finder's desktop icons, below all normal app windows.
        // No canJoinAllSpaces/fullScreenAuxiliary: it stays on its desktop.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        panel.contentView = NSHostingView(rootView: DropView(model: model))
        panel.setFrameAutosaveName("DropNest.DesktopPanel")
        if panel.setFrameUsingName("DropNest.DesktopPanel") {
            // Restore position, but do not restore the previous release's larger size.
            let saved = panel.frame
            panel.setFrame(NSRect(x: saved.minX, y: saved.maxY - DropPanelLayout.height,
                                  width: DropPanelLayout.width, height: DropPanelLayout.height), display: false)
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - DropPanelLayout.width - 26, y: screen.visibleFrame.minY + 80))
        }
        panel.delegate = self
        panel.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "落格")
        let menu = NSMenu()
        for (title, action, key) in [("显示 / 隐藏收纳窗", #selector(togglePanel), ""),
                                      ("设置与整理记录…", #selector(openSettings), ","),
                                      ("搜索文件…", #selector(openSearch), "f"),
                                      ("整理发票…", #selector(openInvoices), ""),
                                      ("打开归档位置", #selector(openFolder), "")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出落格", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); statusItem.menu = menu
        let mainMenu = NSMenu(); mainMenu.addItem(NSMenuItem(title: "落格", action: nil, keyEquivalent: ""))
        mainMenu.items[0].submenu = menu.copy() as? NSMenu
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("拷贝", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        edit.submenu = editMenu; mainMenu.addItem(edit); NSApp.mainMenu = mainMenu
    }
    @objc func togglePanel() { panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless() }
    @objc func openFolder() { model.openRoot() }
    @objc func openSearch() { model.settingsTab = 2; openSettings() }
    @objc func openInvoices() { model.settingsTab = 5; openSettings() }
    @objc func openSettings() {
        model.refreshAI()
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "落格 · 设置与记录"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model)); window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        model.error = "正在处理文件，请等待当前操作完成后退出。"
        return .terminateCancel
    }
    func windowDidMove(_ notification: Notification) { panel?.saveFrame(usingName: "DropNest.DesktopPanel") }
}
