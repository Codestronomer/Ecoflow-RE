// StatusBarController — NSStatusItem with a compact glass popover sharing
// the same AppModel/session as the main window (FR-8).
import AppKit

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusItem()
    private let popover = NSPopover()
    private var observer: NSObjectProtocol?
    private var panelVC: MenuBarPanelViewController!

    init(model: AppModel) {
        self.model = model
        super.init()
        panelVC = MenuBarPanelViewController(model: model)
    }

    func install() {
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = panelVC
        refreshLabel()

        observer = NotificationCenter.default.addObserver(
            forName: .appModelChanged, object: model, queue: .main
        ) { [weak self] _ in
            self?.refreshLabel()
        }
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    private func refreshLabel() {
        guard let button = item.button else { return }
        let live = model.phase == .live
        let symbolName = live ? "bolt.ring.left" : "bolt.slash"
        let icon = NSImage(systemSymbolName: NSImage.Name(symbolName), accessibilityDescription: "EcoFlow")

        if model.showSOCInMenuBar, let soc = model.soc {
            let label = "\(Int(soc.rounded()))%"
            let size = button.frame.height == 0 ? 22 : button.frame.height
            button.title = label
            button.image = icon
            button.font = Fonts.mono(13)
            _ = size
        } else {
            button.title = ""
            button.image = icon
        }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

// Compact menu bar panel view controller.
@MainActor
final class MenuBarPanelViewController: NSViewController {
    private let model: AppModel
    private var observer: NSObjectProtocol?

    private let ring: SocRingView
    private let inTile = NSTextField(labelWithString: "In — W")
    private let outTile = NSTextField(labelWithString: "Out — W")
    private let packTile = NSTextField(labelWithString: "Pack — V")
    private let tempTile = NSTextField(labelWithString: "Temp — °C")
    private let phaseLabel = NSTextField(labelWithString: "Not connected")
    private let acSwitch = NSSwitch()
    private let acConfirmButton = NSButton(title: "Confirm AC off", target: nil, action: nil)
    private var armAC = false

    init(model: AppModel) {
        self.model = model
        ring = SocRingView(size: 96)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let container = GlassCardView(cornerRadius: 16)
        container.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSStackView(views: [ring, metricColumn()])
        grid.orientation = .horizontal
        grid.spacing = Design.gridGap

        acSwitch.controlSize = .small
        acSwitch.target = self
        acSwitch.action = #selector(acToggled)

        acConfirmButton.bezelStyle = .rounded
        acConfirmButton.controlSize = .small
        acConfirmButton.target = self
        acConfirmButton.action = #selector(confirmACTapped)
        acConfirmButton.isHidden = true

        let openButton = NSButton(title: "Open Dashboard", target: self, action: #selector(openDashboard))
        openButton.bezelStyle = .rounded
        let clockButton = NSButton(title: "Set Clock", target: self, action: #selector(setClock))
        clockButton.bezelStyle = .rounded
        clockButton.controlSize = .small
        let disconnectButton = NSButton(title: "Disconnect", target: self, action: #selector(disconnectTapped))
        disconnectButton.bezelStyle = .rounded
        disconnectButton.controlSize = .small
        let quitButton = NSButton(title: "Quit EcoFlow", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small

        phaseLabel.font = Fonts.caption
        phaseLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            phaseRow(), grid, acRow(), NSView(), openButton, clockButton, disconnectButton, quitButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)

        view = container
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])

        observer = NotificationCenter.default.addObserver(
            forName: .appModelChanged, object: model, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    private func phaseRow() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = model.statusColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        phaseLabel.stringValue = model.phaseLabel
        let row = NSStackView(views: [dot, NSTextField(labelWithString: "EcoFlow E980"), phaseLabel, NSView()])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func metricColumn() -> NSView {
        let stack = NSStackView(views: [inTile, outTile, packTile, tempTile])
        stack.orientation = .vertical
        stack.spacing = 6
        for l in stack.arrangedSubviews {
            (l as! NSTextField).font = Fonts.mono(12)
        }
        return stack
    }

    private func acRow() -> NSView {
        let row = NSStackView(views: [
            NSTextField(labelWithString: "AC output"),
            NSView(), acSwitch, acConfirmButton,
        ])
        row.orientation = .horizontal
        row.spacing = 8
        (row.arrangedSubviews[0] as! NSTextField).font = .systemFont(ofSize: 13)
        let spacer = row.arrangedSubviews[1]
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    // MARK: actions

    @objc private func acToggled() {
        let target = acSwitch.state == .on
        acSwitch.state = model.acEnabled == true ? .on : .off   // revert until confirmed
        armAC = true
        acConfirmButton.title = target ? "Confirm AC ON" : "Confirm AC OFF"
        acConfirmButton.isHidden = false
    }

    @objc private func confirmACTapped() {
        model.setAC(!(model.acEnabled ?? false))
        armAC = false
        acConfirmButton.isHidden = true
    }

    @objc private func openDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.isVisible && w.title.contains("EcoFlow") {
            w.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func setClock() { model.setRTC() }

    @objc private func disconnectTapped() { model.disconnect() }

    private func refresh() {
        ring.setSOC(model.soc)
        inTile.stringValue = "In \(model.inputWatts ?? 0) W"
        outTile.stringValue = "Out \(model.outputWatts ?? 0) W"
        packTile.stringValue = "Pack " + (model.packVoltage.map { String(format: "%.2f V", $0) } ?? "—")
        tempTile.stringValue = "Temp \(model.batteryTemp ?? 0) °C"
        phaseLabel.stringValue = model.phaseLabel
        if let ac = model.acEnabled { acSwitch.state = ac ? .on : .off }
        acSwitch.isEnabled = model.phase == .live
    }
}

extension Notification.Name {
    static let appModelChanged = Notification.Name("com.ecoflow.gui.appModelChanged")
}
