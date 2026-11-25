// Design system (AppKit) — modern, sleek, one accent, glass materials.
import AppKit
import EcoFlowKit

enum Design {
    static let accent = NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.35, alpha: 1)
    static let cardRadius: CGFloat = 18
    static let cardPadding: CGFloat = 16
    static let gridGap: CGFloat = 12

    static func statusColor(_ phase: EcoFlowSession.Phase, stale: Bool) -> NSColor {
        if stale { return .systemOrange }
        switch phase {
        case .live: return .systemGreen
        case .idle: return .secondaryLabelColor
        default: return .systemYellow
        }
    }
}

// Monospaced numerics helper.
enum Fonts {
    static func hero(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }
    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }
    static let title = NSFont.boldSystemFont(ofSize: 15)
    static let caption = NSFont.systemFont(ofSize: 11)
}

// Glass card container (NSVisualEffectView).
final class GlassCardView: NSView {
    init(cornerRadius: CGFloat = Design.cardRadius) {
        super.init(frame: .zero)
        wantsLayer = true
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

// Metric tile: caption + big monospaced value inside a glass card.
final class MetricTileView: NSView {
    private let valueLabel = NSTextField(labelWithString: "—")

    init(title: String, symbol: String) {
        valueLabel.font = Fonts.hero(24)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail

        super.init(frame: .zero)

        let icon = NSTextField(labelWithString: "")
        icon.font = NSFont.systemFont(ofSize: 11)
        let imageView = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        imageView.contentTintColor = .secondaryLabelColor

        let titleField = NSTextField(labelWithString: title)
        titleField.font = Fonts.caption
        titleField.textColor = .secondaryLabelColor

        let header = NSStackView(views: [imageView, titleField])
        header.orientation = .horizontal
        header.spacing = 5
        header.alignment = .firstBaseline

        let stack = NSStackView(views: [header, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setValue(_ text: String) { valueLabel.stringValue = text }
}

// Hero SOC ring (Core Animation ring + centered labels).
final class SocRingView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let valueLabel = CATextLayer()
    private let captionLabel = CATextLayer()

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size / 2

        track.fillColor = .clear
        track.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.15).cgColor
        track.lineWidth = 12
        track.lineCap = .round

        arc.fillColor = .clear
        arc.strokeColor = Design.accent.cgColor
        arc.lineWidth = 12
        arc.lineCap = .round

        valueLabel.string = "—"
        valueLabel.font = Fonts.hero(size * 0.26)
        valueLabel.foregroundColor = NSColor.labelColor.cgColor
        valueLabel.alignmentMode = .center
        valueLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        captionLabel.string = "SOC %"
        captionLabel.font = Fonts.caption
        captionLabel.foregroundColor = NSColor.secondaryLabelColor.cgColor
        captionLabel.alignmentMode = .center
        captionLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        for l in [track, arc, valueLabel, captionLabel] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let b = bounds
        let inset: CGFloat = 8
        let rect = b.insetBy(dx: inset, dy: inset)
        let path = CGPath(ellipseIn: rect, transform: nil)
        track.path = path
        arc.path = path
        arc.strokeEnd = CGFloat(socFraction) * 0.999
        let midY = b.midY
        valueLabel.frame = CGRect(x: 0, y: midY + 2, width: b.width, height: b.height * 0.28)
        captionLabel.frame = CGRect(x: 0, y: midY - b.height * 0.16, width: b.width, height: 14)
    }

    private var socFraction: Double = 0

    func setSOC(_ soc: Double?) {
        let f = soc.map { max(0.001, min(1, $0 / 100)) } ?? 0
        socFraction = soc == nil ? 0 : f
        needsLayout = true
        valueLabel.string = soc.map { "\(Int($0.rounded()))" } ?? "—"
        valueLabel.font = Fonts.hero(frame.width * 0.26)
        // custom-drawn control: declare role/value to the accessibility tree
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("State of charge")
        setAccessibilityValue(soc.map { "\(Int($0.rounded())) percent" } ?? "unknown")
    }
}
