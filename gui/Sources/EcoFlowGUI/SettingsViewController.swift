// Settings: device identity, sign-in (email/password → userId → Keychain
// secret), manual fallback, menu bar options.
import AppKit
import EcoFlowKit

final class SettingsViewController: NSViewController {
    private let model: AppModel
    private let snField = NSTextField()
    private let secretField = NSSecureTextField()

    // cloud sign-in
    private let identifierField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let regionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let signInButton = NSButton(title: "Sign In…", target: nil, action: nil)
    private let signInStatus = NSTextField(labelWithString: "")

    private let statusLabel = NSTextField(labelWithString: "")
    private let autoConnect = NSSwitch()
    private let menuSOC = NSSwitch()
    private var signInTask: Task<Void, Never>?

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

        snField.placeholderString = "Serial number (SN)"
        snField.font = .systemFont(ofSize: 13)
        snField.stringValue = model.sn
        snField.target = self
        snField.action = #selector(fieldsChanged)

        secretField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        secretField.stringValue = model.authSecret
        secretField.target = self
        secretField.action = #selector(fieldsChanged)

        // sign-in form
        identifierField.placeholderString = "Email or phone number"
        identifierField.font = .systemFont(ofSize: 13)
        passwordField.placeholderString = "EcoFlow account password"
        passwordField.font = .systemFont(ofSize: 13)
        for region in EcoFlowRegion.allCases {
            regionPopup.addItem(withTitle: region.title)
        }
        regionPopup.selectItem(at: 0)
        signInButton.bezelStyle = .rounded
        signInButton.target = self
        signInButton.action = #selector(signInTapped)
        signInStatus.font = Fonts.caption
        signInStatus.textColor = .secondaryLabelColor
        signInStatus.maximumNumberOfLines = 2
        signInStatus.lineBreakMode = .byWordWrapping

        statusLabel.font = Fonts.caption
        statusLabel.textColor = .secondaryLabelColor

        autoConnect.state = model.autoConnect ? .on : .off
        autoConnect.target = self
        autoConnect.action = #selector(autoConnectChanged)

        menuSOC.state = model.showSOCInMenuBar ? .on : .off
        menuSOC.target = self
        menuSOC.action = #selector(menuSOCChanged)

        // -- layout --
        let signInGrid = NSGridView(views: [
            [caption("Email or phone"), identifierField],
            [caption("Password"), passwordField],
            [caption("Region"), regionPopup],
            [NSView(), signInButton],
        ])
        signInGrid.column(at: 0).xPlacement = .trailing
        signInGrid.rowSpacing = 10
        signInGrid.columnSpacing = 10
        signInGrid.translatesAutoresizingMaskIntoConstraints = false

        let manualGrid = NSGridView(views: [
            [caption("Serial number (SN)"), snField],
            [caption("Auth secret (32 hex, Keychain)"), secretField],
        ])
        manualGrid.column(at: 0).xPlacement = .trailing
        manualGrid.rowSpacing = 10
        manualGrid.columnSpacing = 10
        manualGrid.translatesAutoresizingMaskIntoConstraints = false

        let autoLabel = NSTextField(labelWithString: "Auto-connect to last device")
        autoLabel.font = .systemFont(ofSize: 13)
        let menuLabel = NSTextField(labelWithString: "Show SOC in menu bar")
        menuLabel.font = .systemFont(ofSize: 13)

        let about = NSTextField(wrappingLabelWithString:
            "Sign-in sends your password only to EcoFlow's official server (over TLS) to resolve " +
            "your account ID — it is never stored. The derived secret lives in the Keychain. " +
            "Everything else runs locally: no cloud, no analytics.")
        about.font = Fonts.caption
        about.textColor = .secondaryLabelColor
        about.translatesAutoresizingMaskIntoConstraints = false

        for f in [identifierField, passwordField] {
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        snField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        secretField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        regionPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        view.addSubview(signInGrid)
        view.addSubview(signInStatus)
        view.addSubview(manualGrid)
        view.addSubview(autoLabel)
        view.addSubview(autoConnect)
        view.addSubview(menuLabel)
        view.addSubview(menuSOC)
        view.addSubview(about)

        NSLayoutConstraint.activate([
            signInGrid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            signInGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            signInStatus.topAnchor.constraint(equalTo: signInGrid.bottomAnchor, constant: 8),
            signInStatus.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            signInStatus.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            manualGrid.topAnchor.constraint(equalTo: signInStatus.bottomAnchor, constant: 18),
            manualGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            autoLabel.topAnchor.constraint(equalTo: manualGrid.bottomAnchor, constant: 20),
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

    // MARK: cloud sign-in

    @objc private func signInTapped() {
        let identifier = identifierField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        let sn = snField.stringValue.trimmingCharacters(in: .whitespaces)

        guard !identifier.isEmpty, !password.isEmpty else {
            signInStatus.stringValue = "Enter your EcoFlow account email (or phone) and password."
            return
        }
        guard !sn.isEmpty else {
            signInStatus.stringValue = "Enter the device serial number (SN) first — it's on the device label."
            return
        }

        signInButton.isEnabled = false
        signInStatus.stringValue = "Signing in to EcoFlow…"

        let region = EcoFlowRegion.allCases[regionPopup.indexOfSelectedItem]
        let auth = EcoFlowCloudAuth(region: region)
        signInTask = Task { [weak self] in
            do {
                let userId = try await auth.fetchUserId(identifier: identifier, password: password)
                let secret = EcoFlowCloudAuth.bleSecret(userId: userId, deviceSN: sn)
                await MainActor.run {
                    guard let self else { return }
                    self.secretField.stringValue = secret
                    self.model.authSecret = secret
                    self.model.persistSettings()
                    self.passwordField.stringValue = ""   // never linger
                    self.signInStatus.stringValue = "Signed in — secret derived and stored in the Keychain."
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
                        self.signInStatus.stringValue = "Sign-in failed (HTTP \(status)) — check your account and region."
                    case EcoFlowCloudError.badIdentifier:
                        self.signInStatus.stringValue = "Enter your account email/phone and password."
                    default:
                        self.signInStatus.stringValue = "Sign-in failed — check your connection and try again."
                    }
                }
            }
        }
    }
}
