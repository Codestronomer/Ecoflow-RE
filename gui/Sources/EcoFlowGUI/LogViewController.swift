// Packet log: streaming decoded frames, filter + pause + copy.
import AppKit

@MainActor
final class LogViewController: NSViewController {
    private let model: AppModel
    private var observer: NSObjectProtocol?

    private let filterField = NSTextField()
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let textView = NSTextView()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView()

        filterField.placeholderString = "Filter"
        filterField.font = .systemFont(ofSize: 12)
        filterField.target = self
        filterField.action = #selector(refreshText)
        filterField.translatesAutoresizingMaskIntoConstraints = false

        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        pauseButton.translatesAutoresizingMaskIntoConstraints = false

        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false

        // right-click context menu (HIG: interactive elements get one)
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy All Lines",
                     action: #selector(LogViewController.copyAll(_:)), keyEquivalent: "")
        textView.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(filterField)
        view.addSubview(pauseButton)
        view.addSubview(copyButton)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            filterField.widthAnchor.constraint(equalToConstant: 240),
            pauseButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            pauseButton.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 8),
            copyButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            copyButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])

        observer = NotificationCenter.default.addObserver(
            forName: .appModelChanged, object: model, queue: .main
        ) { [weak self] _ in
            self?.refreshText()
        }
        refreshText()
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    @objc private func pauseTapped() {
        model.logPaused.toggle()
        pauseButton.title = model.logPaused ? "Resume" : "Pause"
    }

    @objc func copyAll(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentLines().joined(separator: "\n"), forType: .string)
    }

    @objc private func copyTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentLines().joined(separator: "\n"), forType: .string)
    }

    private func currentLines() -> [String] {
        var lines = model.packetLines
        let f = filterField.stringValue
        if !f.isEmpty { lines = lines.filter { $0.localizedCaseInsensitiveContains(f) } }
        return lines.reversed()
    }

    @objc private func refreshText() {
        guard !model.logPaused else { return }
        let text = currentLines().joined(separator: "\n")
        if textView.string != text {
            textView.string = text
            // (text auto-scrolls via refreshText)
        }
    }
}
