// Main window: sidebar (devices + session steps) and tabbed detail
// (Dashboard / Log / Settings). Programmatic AppKit.
import AppKit
import EcoFlowKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = AppModel()
    var windowController: MainWindowController?
    var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = MainWindowController(model: model)
        main.showWindow(nil)
        main.window?.makeKeyAndOrderFront(nil)
        windowController = main

        let status = StatusBarController(model: model)
        status.install()
        statusBar = status

        MainMenu.install(to: self)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep running for the menu bar
    }

    // MARK: menu actions (target = self)

    @objc func connectTapped() { model.connect() }
    @objc func disconnectTapped() { model.disconnect() }
    @objc func setClockTapped() { model.setRTC() }

    @objc func copyPacketLogTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.packetLines.joined(separator: "\n"), forType: .string)
    }

    @objc func showDashboardTab() { windowController?.selectTab(0) }
    @objc func showLogTab() { windowController?.selectTab(1) }
    @objc func showSettingsTab() {
        windowController?.selectTab(2)
        windowController?.showWindow(nil)
    }

    @objc func showShortcutsTapped() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        Connect  ⇧⌘C    Disconnect  ⇧⌘D
        Set Device Clock…  ⇧⌘T
        Copy Packet Log  ⇧⌘L
        Dashboard / Log / Settings  ⌘1 / ⌘2 / ⌘3
        Settings…  ⌘,    Close Window  ⌘W
        Minimize  ⌘M    Hide  ⌘H    Quit  ⌘Q
        """
        alert.runModal()
    }

    // Disabled items communicate context (HIG).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(connectTapped):
            return model.phase != .live
        case #selector(disconnectTapped):
            return model.phase == .live
        case #selector(setClockTapped):
            return model.phase == .live
        case #selector(copyPacketLogTapped):
            return !model.packetLines.isEmpty
        default:
            return true
        }
    }
}

@main
struct EcoFlowGUIMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate()                      // foreground the app at launch (macOS 14+)
        app.run()
    }
}

@MainActor
final class MainWindowController: NSWindowController {
    private let model: AppModel
    private var dashboardVC: DashboardViewController!
    private var detailVC: DetailHostViewController!
    private var refreshObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "EcoFlow E980"
        window.minSize = NSSize(width: 860, height: 600)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.autorecalculatesKeyViewLoop = true   // keep Tab order correct as views come and go
        // appear on the active Space (and alongside fullscreen apps) instead
        // of spawning an invisible background Space
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)

        dashboardVC = DashboardViewController(model: model)
        let logVC = LogViewController(model: model)
        let settingsVC = SettingsViewController(model: model)

        let sidebarVC = DeviceListViewController(model: model)
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = false
        let detailVC = DetailHostViewController(
            dashboard: dashboardVC.view, log: logVC.view, settings: settingsVC.view)
        self.detailVC = detailVC
        let detailItem = NSSplitViewItem(viewController: detailVC)

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 980, height: 680))
        window.center()
        window.setFrameAutosaveName("MainWindow")   // session state: restore position/size
        // session state: restore the active tab
        let savedTab = UserDefaults.standard.integer(forKey: "ui.selectedTab")
        detailVC.selectTab(min(max(savedTab, 0), 2))
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .appModelChanged, object: model, queue: .main
        ) { [weak self] _ in
            self?.dashboardVC.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func selectTab(_ index: Int) {
        detailVC?.selectTab(index)
        UserDefaults.standard.set(index, forKey: "ui.selectedTab")
    }

    deinit { if let o = refreshObserver { NotificationCenter.default.removeObserver(o) } }
}

// Detail tab host: segmented control switching three child views.
@MainActor
final class DetailHostViewController: NSViewController {
    private let segmented = NSSegmentedControl(labels: ["Dashboard", "Log", "Settings"],
                                               trackingMode: .selectOne,
                                               target: nil, action: nil)
    private var tabViews: [(view: NSView, isSettings: Bool)]

    init(dashboard: NSView, log: NSView, settings: NSView) {
        tabViews = [(dashboard, false), (log, false), (settings, true)]
        super.init(nibName: nil, bundle: nil)
        segmented.target = self
        segmented.action = #selector(switchTab)
        segmented.selectedSegment = 0
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func switchTab() {
        selectTab(segmented.selectedSegment)
    }

    func selectTab(_ index: Int) {
        segmented.selectedSegment = index
        for (i, tab) in tabViews.enumerated() { tab.view.isHidden = (i != index) }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        segmented.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmented)

        var edgeConstraints: [NSLayoutConstraint] = []
        for tab in tabViews {
            tab.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(tab.view)
            edgeConstraints.append(contentsOf: [
                tab.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
                tab.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                tab.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tab.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        NSLayoutConstraint.activate(
            edgeConstraints + [
                segmented.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
                segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.cardPadding),
            ]
        )
        switchTab()
    }
}
