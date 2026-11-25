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
    private let identifierField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let regionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let signInButton = NSButton(title: "Sign In…", target: nil, action: nil)
    private let signInStatus = NSTextField(labelWithString: "")
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

        identifierField.placeholderString = "Email or phone"
        identifierField.font = .systemFont(ofSize: 13)
        passwordField.placeholderString = "EcoFlow account password"
        passwordField.font = .systemFont(ofSize: 13)
        for region in EcoFlowRegion.allCases { regionPopup.addItem(withTitle: region.title) }
        regionPopup.selectItem(at: 0)
        signInButton.bezelStyle = .rounded
        signInButton.target = self
        signInButton.action = #selector(signInTapped)
        signInStatus.font = Fonts.caption
        signInStatus.textColor = .secondaryLabelColor

        autoConnect.state = model.autoConnect ? .on : .off
        autoConnect.target = self
        autoConnect.action = #selector(autoConnectChanged)

        menuSOC.state = model.showSOCInMenuBar ? .on : .off
        menuSOC.target = self
        menuSOC.action = #selector(menuSOCChanged)

        let form = NSGridView(views: [
            [caption("Email or phone"), identifierField],
            [caption("EcoFlow password"), passwordField],
            [caption("Region"), regionPopup],
            [NSView(), signInButton],
            [NSView(), signInStatus],
            [caption("— or manual —"), NSTextField(labelWithString: "")],
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
            identifierField.widthAnchor.constraint(equalToConstant: 260),
            passwordField.widthAnchor.constraint(equalToConstant: 260),
            regionPopup.widthAnchor.constraint(equalToConstant: 200),
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

    @objc private func signInTapped() {
        let identifier = identifierField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        let sn = snField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty, !password.isEmpty else {
            signInStatus.stringValue = "Enter your EcoFlow email (or phone) and password."
            return
        }
        guard !sn.isEmpty else {
            signInStatus.stringValue = "Enter the device SN first (on the device label)."
            return
        }
        signInButton.isEnabled = false
        signInStatus.stringValue = "Signing in to EcoFlow…"

        let region = EcoFlowRegion.allCases[regionPopup.indexOfSelectedItem]
        let auth = EcoFlowCloudAuth(region: region)
        Task { [weak self] in
            do {
                let userId = try await auth.fetchUserId(identifier: identifier, password: password)
                let secret = EcoFlowCloudAuth.bleSecret(userId: userId, deviceSN: sn)
                await MainActor.run {
                    guard let self else { return }
                    self.secretField.stringValue = secret
                    self.model.authSecret = secret
                    self.model.persistSettings()
                    self.passwordField.stringValue = ""
                    self.signInStatus.stringValue = "Signed in — secret stored in the Keychain."
                    self.signInButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.passwordField.stringValue = ""
                    self.signInButton.isEnabled = true
                    switch error {
                    case EcoFlowCloudError.apiError(_, let message):
                        self.signInStatus.stringValue = "Sign-in failed: \(message)"
                    case EcoFlowCloudError.httpStatus(let status):
                        self.signInStatus.stringValue = "Sign-in failed (HTTP \(status)) — check account and region."
                    default:
                        self.signInStatus.stringValue = "Sign-in failed — check your connection."
                    }
                }
            }
        }
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
