// Settings: device identity, auth secret (Keychain), derive helper, menu bar.
import AppKit
import EcoFlowKit

@MainActor
final class SettingsViewController: NSViewController {
    private let model: AppModel
    private let snField = NSTextField()
    private let secretField = NSSecureTextField()
    private let identifierField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let passwordPlainField = NSTextField()
    private let revealButton = NSButton()
    private var passwordRevealed = false
    private let regionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let signInButton = NSButton(title: "Sign In…", target: nil, action: nil)
    let signInSpinner = NSProgressIndicator()
    private var signInStatusField: NSTextField!
    private let signInStatus = NSTextField(labelWithString: "")
    private let autoConnect = NSSwitch()
    private let menuSOC = NSSwitch()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let content = NSView()
        // install subviews FIRST — constraints between views that don't
        // share a common ancestor throw

        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = Fonts.caption
            l.textColor = .secondaryLabelColor
            return l
        }

        snField.placeholderString = "SN"
        snField.font = .systemFont(ofSize: 13)

        secretField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)


        identifierField.placeholderString = "Email or phone"
        identifierField.font = .systemFont(ofSize: 13)
        passwordField.placeholderString = "EcoFlow account password"
        passwordField.font = .systemFont(ofSize: 13)
        passwordField.target = self
        passwordField.action = #selector(signInTapped)   // Return submits

        passwordPlainField.placeholderString = "EcoFlow account password"
        passwordPlainField.font = .systemFont(ofSize: 13)
        passwordPlainField.isHidden = true
        passwordPlainField.target = self
        passwordPlainField.action = #selector(signInTapped)

        revealButton.isBordered = false
        revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show password")
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        for region in EcoFlowRegion.allCases { regionPopup.addItem(withTitle: region.title) }
        regionPopup.selectItem(at: 0)
        let passwordRow = NSStackView(views: [passwordField, passwordPlainField, revealButton])
        passwordRow.orientation = .horizontal
        passwordRow.spacing = 6
        passwordPlainField.widthAnchor.constraint(equalTo: passwordField.widthAnchor).isActive = true
        signInButton.bezelStyle = .rounded
        signInButton.target = self
        signInButton.action = #selector(signInTapped)
        signInSpinner.isIndeterminate = true
        signInSpinner.controlSize = .small
        signInSpinner.style = .spinning
        signInSpinner.isHidden = true

        // multi-line status, bounded so it can't drive the window layout
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = Fonts.caption
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 360
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        signInStatusField = status

        autoConnect.state = model.autoConnect ? .on : .off
        autoConnect.target = self
        autoConnect.action = #selector(autoConnectChanged)

        menuSOC.state = model.showSOCInMenuBar ? .on : .off
        menuSOC.target = self
        menuSOC.action = #selector(menuSOCChanged)

        func centeredRow(_ views: [NSView]) -> NSView {
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }

        func formRow(_ label: String, _ field: NSView) -> NSView {
            let cap = caption(label)
            cap.setContentHuggingPriority(.required, for: .horizontal)
            cap.isHidden = label.isEmpty
            let row = NSStackView(views: [cap, field])
            row.orientation = .horizontal
            row.spacing = 10
            return row
        }

        let rowHeight: [NSLayoutConstraint] = []
        _ = rowHeight
        let passwordRowForForm = NSStackView(views: [passwordField, passwordPlainField, revealButton])
        passwordRowForForm.orientation = .horizontal
        passwordRowForForm.spacing = 6

        let rows: [NSView] = [
            formRow("Email or phone", identifierField),
            formRow("EcoFlow password", passwordRowForForm),
            formRow("Region", regionPopup),
            centeredRow([signInButton, signInSpinner]),
            formRow("", signInStatusField),
            centeredRow([NSTextField(labelWithString: "— or manual —")]),
            formRow("Serial number (SN)", snField),
            formRow("Auth secret (32 hex chars, Keychain)", secretField),
        ]
        let form = NSStackView(views: rows)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false

        let autoLabel = NSTextField(labelWithString: "Auto-connect to last device")
        autoLabel.font = .systemFont(ofSize: 13)
        let menuLabel = NSTextField(labelWithString: "Show SOC in menu bar")
        menuLabel.font = .systemFont(ofSize: 13)
        let autoRow = NSStackView(views: [autoLabel, autoConnect])
        autoRow.orientation = .horizontal
        autoRow.spacing = 10
        let menuRow = NSStackView(views: [menuLabel, menuSOC])
        menuRow.orientation = .horizontal
        menuRow.spacing = 10
        let toggles = NSStackView(views: [autoRow, menuRow])
        toggles.orientation = .vertical
        toggles.alignment = .leading
        toggles.spacing = 12
        toggles.translatesAutoresizingMaskIntoConstraints = false
        let about = NSTextField(wrappingLabelWithString:
            "Sign-in sends your password only to EcoFlow's official server (over TLS) to resolve your " +
            "account ID — it is never stored. The derived secret lives in the Keychain. " +
            "Everything else runs locally: no cloud, no analytics.")
        about.font = Fonts.caption
        about.textColor = .secondaryLabelColor
        about.maximumNumberOfLines = 2
        about.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(form)
        content.addSubview(toggles)
        content.addSubview(about)

        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            snField.widthAnchor.constraint(equalToConstant: 260),
            secretField.widthAnchor.constraint(equalToConstant: 260),
            identifierField.widthAnchor.constraint(equalToConstant: 260),
            passwordField.widthAnchor.constraint(equalToConstant: 260),
            regionPopup.widthAnchor.constraint(equalToConstant: 200),
            toggles.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 20),
            toggles.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            about.topAnchor.constraint(equalTo: toggles.bottomAnchor, constant: 20),
            about.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            about.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
        ])

        // persist on edit end
        snField.target = self
        snField.action = #selector(fieldsChanged)
        secretField.target = self
        secretField.action = #selector(fieldsChanged)

        view = content
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
        let password = activePasswordField.stringValue
        let sn = snField.stringValue.trimmingCharacters(in: .whitespaces)

        // -- validation (inline, before any network work) --
        if identifier.isEmpty {
            setStatus("Enter your EcoFlow account email or phone number.", .error)
            identifierField.becomeFirstResponder()
            return
        }
        let isEmail = identifier.contains("@") && identifier.contains(".")
        let isPhone = Self.isPhoneLike(identifier)
        if !isEmail && !isPhone {
            setStatus("That doesn't look like an email address or phone number.", .error)
            identifierField.becomeFirstResponder()
            return
        }
        if password.isEmpty {
            setStatus("Enter your EcoFlow account password.", .error)
            activePasswordField.becomeFirstResponder()
            return
        }
        if sn.isEmpty {
            setStatus("Enter the device serial number (SN) first — it's on the device label.", .error)
            snField.becomeFirstResponder()
            return
        }

        // -- request lifecycle: spinner + disabled button immediately --
        signInButton.isEnabled = false
        signInSpinner.isHidden = false
        signInSpinner.startAnimation(nil)
        setStatus("Signing in to EcoFlow (\(EcoFlowRegion.allCases[regionPopup.indexOfSelectedItem].host))…", .busy)

        let region = EcoFlowRegion.allCases[regionPopup.indexOfSelectedItem]
        let auth = EcoFlowCloudAuth(region: region)
        Task { [weak self] in
            do {
                let userId = try await auth.fetchUserId(identifier: identifier, password: password)
                let secret = EcoFlowCloudAuth.bleSecret(userId: userId, deviceSN: sn)
                await MainActor.run {
                    guard let self else { return }
                    self.endSpinner()
                    self.secretField.stringValue = secret
                    self.model.authSecret = secret
                    self.model.persistSettings()
                    self.passwordField.stringValue = ""   // never linger
                    self.setStatus("Signed in — the secret was derived and stored in the Keychain.", .success)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.endSpinner()
                    self.passwordField.stringValue = ""
                    self.passwordPlainField.stringValue = ""
                    let message: String
                    switch error {
                    case EcoFlowCloudError.apiError(_, let m):
                        message = "Sign-in failed: \(m)"
                    case EcoFlowCloudError.httpStatus(let status):
                        message = "Sign-in failed (HTTP \(status)) — check your account, region and connection."
                    case EcoFlowCloudError.missingUserId:
                        message = "Sign-in succeeded but the response had no user ID — please report this."
                    case EcoFlowCloudError.badIdentifier:
                        message = "Enter a valid email/phone and password."
                    case EcoFlowCloudError.invalidResponse:
                        message = "EcoFlow sent an unexpected response — try again."
                    case is URLError:
                        message = "Network error — check your internet connection and try again."
                    default:
                        message = "Sign-in failed — check your connection and try again."
                    }
                    self.setStatus(message, .error)
                }
            }
        }
    }

    // show/hide the password (plain mirror kept in sync both ways)
    @objc private func revealTapped() {
        passwordRevealed.toggle()
        let showing = passwordRevealed
        if showing {
            passwordPlainField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = passwordPlainField.stringValue
        }
        passwordField.isHidden = showing
        passwordPlainField.isHidden = !showing
        revealButton.image = NSImage(systemSymbolName: showing ? "eye.slash" : "eye",
                                     accessibilityDescription: showing ? "Hide password" : "Show password")
        (showing ? passwordPlainField : passwordField).becomeFirstResponder()
    }

    private var activePasswordField: NSTextField {
        passwordRevealed ? passwordPlainField : passwordField
    }

    private func endSpinner() {
        signInSpinner.stopAnimation(nil)
        signInSpinner.isHidden = true
        signInButton.isEnabled = true
    }

    private enum StatusKind { case info, busy, success, error }

    private func setStatus(_ text: String, _ kind: StatusKind) {
        signInStatusField.stringValue = text
        switch kind {
        case .info, .busy: signInStatusField.textColor = .secondaryLabelColor
        case .success: signInStatusField.textColor = Design.accent
        case .error: signInStatusField.textColor = .systemRed
        }
    }

    // -- self-test hooks (used by EF_TEST_SIGNIN) --
    func runTestSignIn(identifier: String, password: String, sn: String) {
        identifierField.stringValue = identifier
        activePasswordField.stringValue = password
        snField.stringValue = sn
        signInTapped()
    }

    func statusForTest() -> String { signInStatusField.stringValue }

    private static func isPhoneLike(_ s: String) -> Bool {
        let digits = s.dropFirst(s.hasPrefix("+") ? 1 : 0)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) && digits.count >= 6
    }

}
