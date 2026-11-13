import AppKit
import Shared
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    /// The app that was in front before ours — a macOS-widget button goes back to it.
    private var previousApp: NSRunningApplication?

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        W.registerFonts()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if app != NSRunningApplication.current { self?.previousApp = app } }
        }
        _ = Player.shared
        // Space plays / pauses, except while typing.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
            MainActor.assumeIsolated { Player.shared.toggle() }
            return nil
        }
        showWindow()
        if UserDefaults.standard.object(forKey: "widgetOpen") as? Bool ?? true { DesktopWidget.shared.open() }
        WidgetBridge.shared.changed()
        Task { await LocalMusic.shared.rescan() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    /// Closing the window keeps the music (and the widgets) going.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ n: Notification) { Player.shared.save() }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        WidgetBridge.shared.handle(url, previousApp: previousApp)
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "WreckBox Player"
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(W.bg)
            w.contentView = NSHostingView(rootView: MainView())
            w.setFrameAutosaveName("main")
            if !w.setFrameUsingName("main") { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showMain(page: Page? = nil) {
        if let page { Nav.shared.page = page }
        (NSApp.delegate as? AppDelegate)?.showWindow()
    }

    // MARK: menu

    private func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = m
            main.addItem(item)
        }
        func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let i = MenuAction(title: title, key: key, action: action)
            i.keyEquivalentModifierMask = mods
            return i
        }
        sub("WreckBox Player", [
            item("About WreckBox Player", "") { NSApp.orderFrontStandardAboutPanel(nil) },
            .separator(),
            item("Settings…", ",") { Nav.shared.settings = true; AppDelegate.showMain() },
            .separator(),
            item("Hide WreckBox Player", "h") { NSApp.hide(nil) },
            item("Quit WreckBox Player", "q") { NSApp.terminate(nil) },
        ])
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        let p = Player.shared
        sub("Controls", [
            item("Play / Pause (Space)", "p") { p.toggle() },
            item("Next", String(UnicodeScalar(NSRightArrowFunctionKey)!)) { p.next() },
            item("Previous", String(UnicodeScalar(NSLeftArrowFunctionKey)!)) { p.previous() },
            item("Forward 10 s", String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]) { p.skip(10) },
            item("Back 10 s", String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]) { p.skip(-10) },
            .separator(),
            item("Shuffle", "s", [.command, .option]) { p.setShuffle(!p.shuffle) },
            item("Repeat (off → all → one)", "r", [.command, .option]) { p.cycleRepeat() },
            item("Like", "l") { if let t = p.current { Library.shared.toggleLike(t) } },
            .separator(),
            item("Volume Up", String(UnicodeScalar(NSUpArrowFunctionKey)!)) { SystemVolume.step(true); WidgetBridge.shared.changed() },
            item("Volume Down", String(UnicodeScalar(NSDownArrowFunctionKey)!)) { SystemVolume.step(false); WidgetBridge.shared.changed() },
        ])
        sub("View", [
            item("Home", "1") { Nav.shared.page = .home },
            item("Search", "f") { Nav.shared.page = .search },
            item("Playlists", "2") { Nav.shared.page = .playlists },
            item("Playing", "3") { Nav.shared.page = .playing },
            .separator(),
            item("Equaliser", "e", [.command, .option]) { Nav.shared.eqSheet = true },
            item("Desktop Widget", "w", [.command, .option]) { DesktopWidget.shared.toggle() },
        ])
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(MenuAction(title: "WreckBox Player", key: "0") { AppDelegate.showMain() })
        let winItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let run: @MainActor () -> Void
    init(title: String, key: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { MainActor.assumeIsolated { run() } }
}

MainActor.assumeIsolated {
    if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "make-icon" {
        IconMaker.run(URL(fileURLWithPath: CommandLine.arguments[2]))
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
