// Sidebar: devices, connect/disconnect, session step rows, packs.
import AppKit
import EcoFlowKit

@MainActor
final class DeviceListViewController: NSViewController {
    private let model: AppModel
    private var rowsObserver: NSObjectProtocol?

    private let listScrollView = NSScrollView()
    private let listDocument = DocumentView()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let packsLabel = NSTextField(labelWithString: "Packs: —")
    private var packStack: NSStackView?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        connectButton.bezelStyle = .rounded
        connectButton.target = self
        connectButton.action = #selector(connectTapped)

        packsLabel.font = Fonts.caption
        packsLabel.textColor = .secondaryLabelColor

        listDocument.wantsLayer = true
        listScrollView.documentView = listDocument
        listScrollView.hasVerticalScroller = true
        listScrollView.drawsBackground = false

        listScrollView.translatesAutoresizingMaskIntoConstraints = false
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        packsLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(listScrollView)
        view.addSubview(connectButton)
        view.addSubview(packsLabel)

        NSLayoutConstraint.activate([
            listScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            packsLabel.topAnchor.constraint(equalTo: listScrollView.bottomAnchor, constant: 8),
            packsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            connectButton.topAnchor.constraint(equalTo: packsLabel.bottomAnchor, constant: 10),
            connectButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            connectButton.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            connectButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

        rebuildList()
        refreshButtons()

        rowsObserver = NotificationCenter.default.addObserver(
            forName: .appModelChanged, object: model, queue: .main
        ) { [weak self] _ in
            self?.rebuildList()
            self?.refreshButtons()
        }
    }

    deinit { if let o = rowsObserver { NotificationCenter.default.removeObserver(o) } }

    @objc private func connectTapped() {
        model.connect()
    }

    private func refreshButtons() {
        let live = model.phase == .live
        connectButton.title = live ? "Disconnect" : "Connect"
        connectButton.action = live ? #selector(disconnectTapped) : #selector(connectTapped)
        connectButton.isEnabled = live || model.hasSecret
    }

    @objc private func disconnectTapped() { model.disconnect() }

    // Rebuild the list content (small lists; fine to rebuild on change).
    private func rebuildList() {
        listDocument.subviews.forEach { $0.removeFromSuperview() }

        var cursor = NSStackView()
        cursor.orientation = .vertical
        cursor.spacing = 10
        cursor.alignment = .leading
        cursor.translatesAutoresizingMaskIntoConstraints = false
        listDocument.addSubview(cursor)

        var constraints: [NSLayoutConstraint] = [
            cursor.topAnchor.constraint(equalTo: listDocument.topAnchor, constant: 12),
            cursor.leadingAnchor.constraint(equalTo: listDocument.leadingAnchor, constant: 12),
            cursor.trailingAnchor.constraint(lessThanOrEqualTo: listDocument.trailingAnchor, constant: -12),
        ]

        // session steps
        let steps = stepRows()
        for s in steps { cursor.addArrangedSubview(s) }

        // devices
        let header = NSTextField(labelWithString: "DEVICES")
        header.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .secondaryLabelColor
        cursor.addArrangedSubview(header)

        if model.discovered.isEmpty {
            let empty = NSTextField(labelWithString: model.phase == .scanning ? "Scanning…" : "No devices yet")
            empty.font = Fonts.caption
            empty.textColor = .secondaryLabelColor
            cursor.addArrangedSubview(empty)
        }
        for d in model.discovered {
            let row = DeviceRowView(name: d.name ?? "Unknown", rssi: d.rssi) { [weak self] in
                self?.model.connectToDevice(d)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            cursor.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: cursor.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: cursor.trailingAnchor),
            ])
        }

        // packs
        let packsHeader = NSTextField(labelWithString: "SUB-PACKS")
        packsHeader.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        packsHeader.textColor = .secondaryLabelColor
        cursor.addArrangedSubview(packsHeader)
        if model.packs.isEmpty {
            let none = NSTextField(labelWithString: "—")
            none.font = Fonts.caption
            none.textColor = .secondaryLabelColor
            cursor.addArrangedSubview(none)
        }
        for (i, sn) in model.packs.enumerated() {
            let text = "Pack \(i): \(sn ?? "<redacted>")"
            let l = NSTextField(labelWithString: text)
            l.font = Fonts.caption
            cursor.addArrangedSubview(l)
        }

        constraints.append(cursor.bottomAnchor.constraint(lessThanOrEqualTo: listDocument.bottomAnchor, constant: -12))
        NSLayoutConstraint.activate(constraints)
        listDocument.frame = NSRect(origin: .zero, size: cursor.fittingSize)
    }

    private func stepRows() -> [NSView] {
        var rows: [NSView] = []
        let order: [EcoFlowSession.Phase] = [.idle, .scanning, .connecting, .handshake, .auth, .live]
        guard let pi = order.firstIndex(of: model.phase) else { return rows }

        func row(_ title: String, index: Int) -> NSView {
            let done = pi > index
            let active = pi == index
            let stack = NSStackView(views: [
                NSTextField(labelWithString: done ? "✔" : (active ? "●" : "○")),
                NSTextField(labelWithString: title),
            ])
            stack.orientation = .horizontal
            stack.spacing = 6
            let titleField = stack.arrangedSubviews[1] as! NSTextField
            titleField.font = Fonts.caption
            return stack
        }
        rows.append(row("Handshake", index: 3))
        rows.append(row("Key exchange", index: 4))
        rows.append(row("Auth", index: 5))
        rows.append(row("Live", index: 6))
        return rows
    }
}

@MainActor
final class DeviceRowView: NSView {
    init(name: String, rssi: Int, onConnect: @escaping () -> Void) {
        super.init(frame: .zero)

        let nameField = NSTextField(labelWithString: name)
        nameField.font = .systemFont(ofSize: 13)
        let rssiField = NSTextField(labelWithString: "\(rssi) dBm")
        rssiField.font = Fonts.caption
        rssiField.textColor = .secondaryLabelColor

        let button = NSButton(title: "Connect", target: self, action: #selector(connectTapped))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        connectAction = onConnect

        let stack = NSStackView(views: [nameField, rssiField, NSView(), button])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // right-click: Connect (context menu subset per HIG)
        let menu = NSMenu()
        menu.addItem(withTitle: "Connect", action: #selector(connectTapped), keyEquivalent: "")
        menu.autoenablesItems = false
        for item in menu.items { item.target = self; item.isEnabled = true }
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var connectAction: (() -> Void)?
    @objc private func connectTapped() { connectAction?() }
}

@MainActor
final class DocumentView: NSView {}
