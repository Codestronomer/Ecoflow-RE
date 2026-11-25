// Settings: device identity, auth secret (Keychain), derive helper, menu bar.
import AppKit
import EcoFlowKit

@MainActor
final class SettingsViewController: NSViewController {
    private let model: AppModel
    private let snField = NSTextField()
    private let secretField = NSSecureTextField()
    private let userIdField = NSTextField()
    private let deriveSNField = NSTextField()
    private let deriveStatus = NSTextField(labelWithString: "")
    private let autoConnect = NSSwitch()
    private let menuSOC = NSSwitch()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView()

        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = Fonts.caption
            l.textColor = .secondaryLabelColor
            return l
        }

        snField.placeholderString = "SN"
        snField.font = .systemFont(ofSize: 13)

        secretField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        userIdField.placeholderString = "userId"
        userIdField.font = .systemFont(ofSize: 13)
        deriveSNField.placeholderString = "SN"
        deriveSNField.font = .systemFont(ofSize: 13)
        deriveStatus.font = Fonts.caption
        deriveStatus.textColor = .secondaryLabelColor

        autoConnect.state = model.autoConnect ? .on : .off
        autoConnect.target = self
        autoConnect.action = #selector(autoConnectChanged)

        menuSOC.state = model.showSOCInMenuBar ? .on : .off
        menuSOC.target = self
        menuSOC.action = #selector(menuSOCChanged)

        let form = NSGridView(views: [
            [caption("Serial number (SN)"), snField],
            [caption("Auth secret (32 hex chars, Keychain)"), secretField],
            [caption("Derive: EcoFlow userId"), userIdField],
            [caption("Derive: device SN"), deriveSNField],
            [NSView(), deriveStatus],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowSpacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false

        let deriveButton = NSButton(title: "Derive secret from userId + SN", target: self, action: #selector(deriveTapped))
        deriveButton.bezelStyle = .rounded
        deriveButton.translatesAutoresizingMaskIntoConstraints = false

        let autoLabel = NSTextField(labelWithString: "Auto-connect to last device")
        autoLabel.font = .systemFont(ofSize: 13)
        let menuLabel = NSTextField(labelWithString: "Show SOC in menu bar")
        menuLabel.font = .systemFont(ofSize: 13)

        let about = NSTextField(wrappingLabelWithString:
            "Runs entirely locally — no cloud, no analytics. Telemetry and commands use the verified BLE protocol.")
        about.font = Fonts.caption
        about.textColor = .secondaryLabelColor
        about.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(form)
        view.addSubview(deriveButton)
        view.addSubview(autoLabel)
        view.addSubview(autoConnect)
        view.addSubview(menuLabel)
        view.addSubview(menuSOC)
        view.addSubview(about)

        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            snField.widthAnchor.constraint(equalToConstant: 260),
            secretField.widthAnchor.constraint(equalToConstant: 260),
            userIdField.widthAnchor.constraint(equalToConstant: 240),
            deriveSNField.widthAnchor.constraint(equalToConstant: 240),
            deriveButton.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 14),
            deriveButton.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 190),
            autoLabel.topAnchor.constraint(equalTo: deriveButton.bottomAnchor, constant: 20),
            autoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            autoConnect.centerYAnchor.constraint(equalTo: autoLabel.centerYAnchor),
            autoConnect.leadingAnchor.constraint(equalTo: autoLabel.trailingAnchor, constant: 10),
            menuLabel.topAnchor.constraint(equalTo: autoConnect.bottomAnchor, constant: 14),
            menuLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            menuSOC.centerYAnchor.constraint(equalTo: menuLabel.centerYAnchor),
            menuSOC.leadingAnchor.constraint(equalTo: menuLabel.trailingAnchor, constant: 10),
            about.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            about.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            about.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        // persist on edit end
        snField.target = self
        snField.action = #selector(fieldsChanged)
        secretField.target = self
        secretField.action = #selector(fieldsChanged)
    }

    @objc private func fieldsChanged() {
        model.sn = snField.stringValue
        model.authSecret = secretField.stringValue
        model.persistSettings()
    }

    @objc private func autoConnectChanged() {
        model.autoConnect = autoConnect.state == .on
        model.persistSettings()
    }

    @objc private func menuSOCChanged() {
        model.showSOCInMenuBar = menuSOC.state == .on
        model.persistSettings()
    }

    @objc private func deriveTapped() {
        let uid = userIdField.stringValue.trimmingCharacters(in: .whitespaces)
        let snv = deriveSNField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !uid.isEmpty, !snv.isEmpty else {
            deriveStatus.stringValue = "Enter both userId and SN."
            return
        }
        let digest = md5(Data((uid + snv).utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        secretField.stringValue = hex
        model.authSecret = hex
        model.persistSettings()
        deriveStatus.stringValue = "Secret derived and stored in the Keychain."
    }
}
