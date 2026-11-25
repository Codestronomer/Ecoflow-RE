// Dashboard: glass hero (SOC ring + pack/flow) + metric grid + controls.
import AppKit
import EcoFlowKit

@MainActor
final class DashboardViewController: NSViewController {
    private let model: AppModel
    private var observer: NSObjectProtocol?

    private let socRing: SocRingView
    private let packTile: MetricTileView
    private let currentTile: MetricTileView
    private let inTile: MetricTileView
    private let outTile: MetricTileView
    private let tempTile: MetricTileView
    private let cyclesTile: MetricTileView
    private let pvTile: MetricTileView
    private let chargeTile: MetricTileView
    private let packsTile: MetricTileView
    private let acSwitch = NSSwitch()
    private let acStateLabel = NSTextField(labelWithString: "")
    private let clockButton = NSButton(title: "Set to now…", target: nil, action: nil)
    private var confirmPending: Bool?

    init(model: AppModel) {
        self.model = model
        socRing = SocRingView(size: 190)
        packTile = MetricTileView(title: "Pack voltage", symbol: "bolt.horizontal.fill")
        currentTile = MetricTileView(title: "Current", symbol: "arrow.branch.circuit")
        inTile = MetricTileView(title: "Input", symbol: "arrow.down.heart")
        outTile = MetricTileView(title: "Output", symbol: "arrow.up.heart")
        tempTile = MetricTileView(title: "Battery temp", symbol: "thermometer.medium")
        cyclesTile = MetricTileView(title: "Cycles", symbol: "arrow.triangle.2.circlepath")
        pvTile = MetricTileView(title: "PV voltage", symbol: "sun.max.fill")
        chargeTile = MetricTileView(title: "Charge state", symbol: "powerplug.fill")
        packsTile = MetricTileView(title: "Packs", symbol: "square.stack.3d.up")
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let content = GlassCardView()
        content.translatesAutoresizingMaskIntoConstraints = false

        acSwitch.controlSize = .regular
        acSwitch.target = self
        acSwitch.action = #selector(acToggled)
        acStateLabel.font = Fonts.caption
        acStateLabel.textColor = .secondaryLabelColor
        clockButton.bezelStyle = .rounded
        clockButton.target = self
        clockButton.action = #selector(clockTapped)
        clockButton.isEnabled = false

        let acRow = NSStackView(views: [
            NSImageView(image: NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: "AC") ?? NSImage()),
            NSTextField(labelWithString: "AC output"),
            NSView(), acSwitch,
        ])
        acRow.orientation = .horizontal
        acRow.spacing = 10

        let clockRow = NSStackView(views: [
            NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: "Clock") ?? NSImage()),
            NSTextField(labelWithString: "Device clock"),
            NSView(), clockButton,
        ])
        clockRow.orientation = .horizontal
        clockRow.spacing = 10

        let grid = NSGridView(views: [
            [packTile, currentTile, inTile],
            [outTile, tempTile, cyclesTile],
            [pvTile, chargeTile, packsTile],
        ])
        grid.rowSpacing = Design.gridGap
        grid.columnSpacing = Design.gridGap
        grid.xPlacement = .fill
        grid.yPlacement = .fill

        let inner = NSStackView(views: [socRing, grid])
        inner.orientation = .vertical
        inner.alignment = .centerX
        inner.spacing = Design.gridGap

        content.addSubview(inner)
        content.addSubview(acRow)
        content.addSubview(acStateLabel)
        content.addSubview(clockRow)

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: content.topAnchor, constant: Design.cardPadding),
            inner.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Design.cardPadding),
            inner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            acRow.topAnchor.constraint(equalTo: inner.bottomAnchor, constant: Design.gridGap + 6),
            acRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Design.cardPadding + 6),
            acRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Design.cardPadding - 6),
            acStateLabel.topAnchor.constraint(equalTo: acRow.bottomAnchor, constant: 4),
            acStateLabel.leadingAnchor.constraint(equalTo: acRow.leadingAnchor, constant: 2),
            clockRow.topAnchor.constraint(equalTo: acStateLabel.bottomAnchor, constant: Design.gridGap),
            clockRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Design.cardPadding + 6),
            clockRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Design.cardPadding - 6),
            clockRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Design.cardPadding),
        ])

        // each tile keeps a reasonable minimum width
        for t: MetricTileView in [packTile, currentTile, inTile, outTile, tempTile,
                                  cyclesTile, pvTile, chargeTile, packsTile] {
            t.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        }

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor

        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
        ])

        observer = NotificationCenter.default.addObserver(
            forName: .appModelChanged, object: model, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    @objc private func acToggled() {
        let target = acSwitch.state == .on
        // two-step confirm: revert switch until confirmed
        acSwitch.state = model.acEnabled == true ? .on : .off
        if confirmPending == nil {
            confirmPending = target
            let alert = NSAlert()
            alert.messageText = target ? "Turn AC output ON?" : "Turn AC output OFF?"
            alert.informativeText = "This sends a verified command to the device (same bytes the official app uses)."
            alert.addButton(withTitle: target ? "Turn ON" : "Turn OFF")
            alert.addButton(withTitle: "Cancel")
            if target == false { alert.buttons.first?.hasDestructiveAction = true }
            alert.beginSheetModal(for: view.window!) { [weak self] resp in
                guard let self = self else { return }
                defer { self.confirmPending = nil }
                if resp == .alertFirstButtonReturn {
                    self.model.setAC(target)
                } else {
                    self.acSwitch.state = self.model.acEnabled == true ? .on : .off
                }
            }
        }
    }

    @objc private func clockTapped() {
        let alert = NSAlert()
        alert.messageText = "Set the device clock to this Mac's time?"
        alert.informativeText = "Sends the verified SET RTC command (same bytes the official app uses)."
        alert.addButton(withTitle: "Set clock")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: view.window!) { [weak self] resp in
            if resp == .alertFirstButtonReturn { self?.model.setRTC() }
        }
    }

    func refresh() {
        socRing.setSOC(model.soc)
        packTile.setValue(model.packVoltage.map { String(format: "%.2f V", $0) } ?? "—")
        currentTile.setValue(model.current.map { String(format: "%.2f A", $0) } ?? "—")
        inTile.setValue(model.inputWatts.map { "\($0) W" } ?? "—")
        outTile.setValue(model.outputWatts.map { "\($0) W" } ?? "—")
        tempTile.setValue(model.batteryTemp.map { "\($0) °C" } ?? "—")
        cyclesTile.setValue(model.cycles.map { "\($0)" } ?? "—")
        pvTile.setValue(model.mpptInVoltage.map { String(format: "%.2f V", $0) } ?? "—")
        chargeTile.setValue(model.chargeState.map { "\($0)" } ?? "—")
        packsTile.setValue("\(model.packs.count) detected")
        let live = model.phase == .live
        acSwitch.isEnabled = live
        clockButton.isEnabled = live
        if let ac = model.acEnabled { acSwitch.state = ac ? .on : .off }
        acStateLabel.stringValue = "Device-reported AC state"
            + (model.acEnabled.map { $0 ? " · on" : " · off" } ?? "")
    }
}
