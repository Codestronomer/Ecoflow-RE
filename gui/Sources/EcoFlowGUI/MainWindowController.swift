// Main window: sidebar (devices + session steps) and tabbed detail
// (Dashboard / Log / Settings). Programmatic AppKit.
import AppKit
import EcoFlowKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var windowController: MainWindowController?
    var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("EF-LAUNCH: didFinishLaunching entered")
        let main = MainWindowController(model: model)
        NSLog("EF-LAUNCH: window controller created")
        main.showWindow(nil)
        main.window?.makeKeyAndOrderFront(nil)
        windowController = main

        let status = StatusBarController(model: model)
        status.install()
        statusBar = status

        MainMenu.install(to: self)

        // SELF-TEST (EF_TEST_SIGNIN=1): drive the sign-in lifecycle headlessly
        if ProcessInfo.processInfo.environment["EF_TEST_SIGNIN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.runSignInTest()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep running for the menu bar
    }

    // SELF-TEST (EF_TEST_SIGNIN=1): drive the sign-in lifecycle with dummy
    // credentials and log the status so it is observable headlessly.
    private var testStatusTimer: Timer?

    private func runSignInTest() {
        guard let svc = windowController?.settingsVCRef else {
            NSLog("EF-TEST no settings vc"); return
        }
        windowController?.selectTab(2)
        svc.runTestSignIn(identifier: "someone@example.com", password: "wrong-password", sn: "TESTSN0000")
        var ticks = 0
        testStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            ticks += 1
            NSLog("EF-TEST t+\(ticks): '\(svc.statusForTest())' buttonEnabled=\(svc.signInButton.isEnabled) spinnerHidden=\(svc.signInSpinner.isHidden)")
            if ticks >= 12 { self.testStatusTimer?.invalidate() }
        }
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
        Connect  \u{21e7}\u{2318}C    Disconnect  \u{21e7}\u{2318}D
        Set Device Clock…  \u{21e7}\u{2318}T
        Copy Packet Log  \u{21e7}\u{2318}L
        Dashboard / Log / Settings  \u{2318}1 / \u{2318}2 / \u{2318}3
        Settings…  \u{2318},    Close Window  \u{2318}W
        Minimize  \u{2318}M    Hide  \u{2318}H    Quit  \u{2318}Q
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
        NSLog("EF-LAUNCH: main entered")
        let app = NSApplication.shared
        NSLog("EF-LAUNCH: app shared")
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class MainWindowController: NSWindowController {
    private let model: AppModel
    private var dashboardVC: DashboardViewController!
    private var logVC: LogViewController!
    private var settingsVC: SettingsViewController!
    private var detailVCRef: DetailHostViewController?
    private(set) weak var settingsVCRef: SettingsViewController?
    private var lastShownFailure: String?
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
        // appear on the active Space (and alongside fullscreen apps) instead
        // of spawning an invisible background Space
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)

        dashboardVC = DashboardViewController(model: model)
        self.logVC = LogViewController(model: model)
        self.settingsVC = SettingsViewController(model: model)
        settingsVCRef = settingsVC

        let sidebarVC = DeviceListViewController(model: model)
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = false
        let detailVC = DetailHostViewController(
            dashboard: dashboardVC.view, log: logVC.view, settings: settingsVC.view)
        detailVCRef = detailVC
        let detailItem = NSSplitViewItem(viewController: detailVC)

        let split = RootSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 980, height: 680))
        window.center()
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .appModelChanged, object: model, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.dashboardVC.refresh()
            // connection failures surface as a sheet (busy device, bluetooth
            // off, wrong secret, device not found…)
            if let failure = self.model.failureText, failure != self.lastShownFailure {
                self.lastShownFailure = failure
                self.showFailureAlert(failure)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func showFailureAlert(_ text: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Connection problem"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.model.clearFailure()
        }
    }

    func selectTab(_ index: Int) {
        detailVCRef?.selectTab(index)
        UserDefaults.standard.set(index, forKey: "ui.selectedTab")
    }

    deinit { if let o = refreshObserver { NotificationCenter.default.removeObserver(o) } }
}

// NSSplitViewController updates its own preferredContentSize from its
// (tiny) fitting size on layout, and the window then resizes to it —
// which collapsed the window. Re-assert the intended size after every
// layout pass so the window can never shrink below it.
@MainActor
final class RootSplitViewController: NSSplitViewController {
    private var didAssertInitialSize = false

    override func viewDidLayout() {
        super.viewDidLayout()
        NSLog("EF-FIT pass: split.fitting=\(splitView.fittingSize) pref=\(preferredContentSize) winFrame=\(view.window?.frame ?? .zero)")
        preferredContentSize = NSSize(width: 980, height: 680)
        // one-shot: the first layout pass applies the content's fitting
        // width (259) over the intended 980 — correct it once it has settled
        if !didAssertInitialSize, let w = view.window, w.isVisible {
            didAssertInitialSize = true
            if w.frame.width < 980 {
                w.setContentSize(NSSize(width: 980, height: 680))
                w.center()
            }
        }
    }
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
