import AppKit

/// How the cap is drawn in the menu bar. Purely cosmetic, so these live in
/// UserDefaults rather than the shared config file -- the root daemon has no
/// use for them.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case outlined
    case solid
    case rounded
    case monospaced
    case light
    case numberOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .outlined: return "Outlined"
        case .solid: return "Solid"
        case .rounded: return "Rounded"
        case .monospaced: return "Monospaced"
        case .light: return "Light"
        case .numberOnly: return "Number only"
        }
    }

    fileprivate var font: NSFont {
        switch self {
        case .outlined: return .systemFont(ofSize: 11, weight: .semibold)
        case .solid: return .systemFont(ofSize: 12, weight: .regular)
        case .rounded: return Self.rounded(size: 12, weight: .medium)
        case .monospaced: return .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        case .light: return .systemFont(ofSize: 12, weight: .ultraLight)
        case .numberOnly: return .systemFont(ofSize: 12, weight: .regular)
        }
    }

    /// SF Rounded has no direct constructor; it comes from a descriptor, and
    /// falls back to the plain system font if unavailable.
    private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// Menu bar tint. Any style can take any colour.
enum MenuBarColor: String, CaseIterable, Identifiable {
    case automatic
    case red
    case orange
    case yellow
    case green
    case blue
    case purple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    /// nil means "let the menu bar decide": the image is marked as a template
    /// and macOS tints it black or white to match light/dark. Picking a real
    /// colour opts out of that, so it stays that colour in both appearances.
    ///
    /// Pinned to sRGB because the system colours are appearance-dependent, and
    /// a non-template image is rendered once rather than re-resolved when the
    /// user switches theme.
    var ink: NSColor? {
        let color: NSColor
        switch self {
        case .automatic: return nil
        case .red: color = .systemRed
        case .orange: color = .systemOrange
        case .yellow: color = .systemYellow
        case .green: color = .systemGreen
        case .blue: color = .systemBlue
        case .purple: color = .systemPurple
        }
        return color.usingColorSpace(.sRGB) ?? color
    }
}

extension MenuBarStyle {
    /// `dimmed` is the "Limit Charging is off" state.
    func image(percent: Int, dimmed: Bool, color: MenuBarColor) -> NSImage {
        let isTemplate = color.ink == nil
        // Template images carry only alpha, so the black here is a mask, not a
        // colour -- the menu bar supplies the real one.
        let ink = (color.ink ?? .black).withAlphaComponent(dimmed ? 0.4 : 1)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]

        if self == .outlined {
            // Positive strokeWidth means outline with no fill. A negative
            // value would fill *and* stroke, which is not what we want.
            attributes[.strokeWidth] = 3.5
            attributes[.strokeColor] = ink
            attributes[.foregroundColor] = NSColor.clear
        } else {
            attributes[.foregroundColor] = ink
        }

        let text = self == .numberOnly ? "\(percent)" : "\(percent)%"
        let attributed = NSAttributedString(string: text, attributes: attributes)

        // Pad so a stroke or a wide glyph isn't clipped at the text bounds.
        let textSize = attributed.size()
        let size = NSSize(width: ceil(textSize.width) + 4, height: ceil(textSize.height))
        let image = NSImage(size: size, flipped: false) { _ in
            attributed.draw(at: NSPoint(x: 2, y: 0))
            return true
        }
        image.isTemplate = isTemplate
        return image
    }
}
