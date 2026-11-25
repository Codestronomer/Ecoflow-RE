// MainMenu — standard macOS menu bar per Apple HIG:
// [App], File, Edit, View, Window, Help. Every frequent command has a
// keyboard shortcut; disabled items communicate context (validation).
import AppKit

enum MainMenu {
    static func install(to delegate: AppDelegate) {
        let main = NSMenu()

        // -- App menu --
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu(title: "EcoFlow")
        app.addItem(withTitle: "About EcoFlow",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        let settingsItem = app.addItem(withTitle: "Settings…",
                                       action: #selector(AppDelegate.showSettingsTab),
                                       keyEquivalent: ",")
        settingsItem.target = delegate
        app.addItem(.separator())
        let servicesItem = app.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(.separator())
        app.addItem(withTitle: "Hide EcoFlow",
                    action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All",
                    action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit EcoFlow",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        // -- File --
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "File")
        let connect = file.addItem(withTitle: "Connect",
                                   action: #selector(AppDelegate.connectTapped),
                                   keyEquivalent: "c")
        connect.keyEquivalentModifierMask = [.command, .shift]
        connect.target = delegate
        let disconnect = file.addItem(withTitle: "Disconnect",
                                      action: #selector(AppDelegate.disconnectTapped),
                                      keyEquivalent: "d")
        disconnect.keyEquivalentModifierMask = [.command, .shift]
        disconnect.target = delegate
        file.addItem(.separator())
        let clock = file.addItem(withTitle: "Set Device Clock…",
                                 action: #selector(AppDelegate.setClockTapped),
                                 keyEquivalent: "t")
        clock.keyEquivalentModifierMask = [.command, .shift]
        clock.target = delegate
        file.addItem(.separator())
        let copyLog = file.addItem(withTitle: "Copy Packet Log",
                                   action: #selector(AppDelegate.copyPacketLogTapped),
                                   keyEquivalent: "l")
        copyLog.keyEquivalentModifierMask = [.command, .shift]
        copyLog.target = delegate
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window",
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        // -- Edit (standard; nil targets → responder chain handles text fields) --
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        // -- View --
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "View")
        let dash = view.addItem(withTitle: "Dashboard",
                                action: #selector(AppDelegate.showDashboardTab),
                                keyEquivalent: "1")
        dash.target = delegate
        let log = view.addItem(withTitle: "Log",
                               action: #selector(AppDelegate.showLogTab),
                               keyEquivalent: "2")
        log.target = delegate
        let set = view.addItem(withTitle: "Settings",
                               action: #selector(AppDelegate.showSettingsTab),
                               keyEquivalent: "3")
        set.target = delegate
        view.addItem(.separator())
        view.addItem(withTitle: "Toggle Sidebar",
                     action: #selector(NSSplitViewController.toggleSidebar(_:)),
                     keyEquivalent: "s")
        view.addItem(.separator())
        view.addItem(withTitle: "Copy Packet Log",
                     action: #selector(AppDelegate.copyPacketLogTapped),
                     keyEquivalent: "")
        (view.items.last)?.target = delegate
        // macOS adds "Enter Full Screen" automatically to a menu named "View".
        viewItem.submenu = view

        // -- Window --
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize",
                       action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front",
                       action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = window
        NSApp.windowsMenu = window

        // -- Help --
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let help = NSMenu(title: "Help")
        let shortcuts = help.addItem(withTitle: "Keyboard Shortcuts…",
                                     action: #selector(AppDelegate.showShortcutsTapped),
                                     keyEquivalent: "")
        shortcuts.target = delegate
        helpItem.submenu = help
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}
