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
        let main = MainWindowController(model: model)
        main.showWindow(nil)
        windowController = main

        let status = StatusBarController(model: model)
        status.install()
        statusBar = status

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep running for the menu bar
    }
}

@main
struct EcoFlowGUIMain {
    static func main() {
        let app = NSApplication.shared
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
    private var refreshObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "EcoFlow E980"
        window.minSize = NSSize(width: 860, height: 600)
        window.titlebarAppearsTransparent = true
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
        let detailItem = NSSplitViewItem(viewController: detailVC)

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        window.contentViewController = split

        refreshObserver = NotificationCenter.default.addObserver(
            forName: .appModelChanged, object: model, queue: .main
        ) { [weak self] _ in
            self?.dashboardVC.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { if let o = refreshObserver { NotificationCenter.default.removeObserver(o) } }
}

// Detail tab host: segmented control switching three child views.
@MainActor
final class DetailHostViewController: NSViewController {
    private let segmented: NSSegmentedControl
    private var tabViews: [(view: NSView, isSettings: Bool)]

    init(dashboard: NSView, log: NSView, settings: NSView) {
        segmented = NSSegmentedControl(labels: ["Dashboard", "Log"],
                                       trackingMode: .selectOne, target: nil, action: nil)
        tabViews = [(dashboard, false), (log, false), (settings, true)]
        super.init(nibName: nil, bundle: nil)
        segmented.target = self
        segmented.action = #selector(switchTab)
        segmented.selectedSegment = 0
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func switchTab() {
        let idx = segmented.selectedSegment
        for (i, child) in children.enumerated() { child.view.isHidden = (i != idx) }
    }

    override func loadView() {
        view = NSView()

        segmented.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmented)

        for child in children {
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child.view)
        }

        let constraints: [NSLayoutConstraint] = tabViews.flatMap { child in
            [
                child.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
                child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(
            constraints + [
                segmented.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
                segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.cardPadding),
            ]
        )
        switchTab()
    }
}
