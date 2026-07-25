import AppKit

enum LedgeTheme {
    static let glass = NSColor.black.withAlphaComponent(0.92)
    static let glassSolid = NSColor.black
    static let raised = NSColor(white: 1, alpha: 0.055)
    static let raisedHover = NSColor(white: 1, alpha: 0.085)
    /// The *glass* button's hover wash — one step above `raisedHover`, because a
    /// glass button starts at `raised` and would otherwise barely move (D1).
    static let raisedHover2 = NSColor(white: 1, alpha: 0.10)
    static let hairline = NSColor(white: 1, alpha: 0.09)
    /// A hairline that is being hovered. Same value as `track`, different job —
    /// naming the intent is what keeps a future track tweak out of the buttons.
    static let hairlineHover = NSColor(white: 1, alpha: 0.14)
    static let track = NSColor(white: 1, alpha: 0.14)
    /// Progress made of ink, not brand (D8/Q6): slider fill, progress bar fill.
    static let inkFill = NSColor(white: 1, alpha: 0.85)
    /// The selected segment's wash (D6 `segment`).
    static let selected = NSColor(white: 1, alpha: 0.12)
    static let primary = NSColor(white: 1, alpha: 0.94)
    static let secondary = NSColor(white: 1, alpha: 0.56)
    static let tertiary = NSColor(white: 1, alpha: 0.32)
    static let accent = NSColor(srgbRed: 1, green: 180 / 255, blue: 84 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 1)
    static let red = NSColor(srgbRed: 1, green: 69 / 255, blue: 58 / 255, alpha: 1)
    static let violet = NSColor(displayP3Red: 0.56, green: 0.38, blue: 1, alpha: 1)
    static let cyan = NSColor(displayP3Red: 0.18, green: 0.82, blue: 0.94, alpha: 1)
    static let blue = NSColor(displayP3Red: 0.24, green: 0.54, blue: 1, alpha: 1)

    // MARK: - Semantic container tokens (spec §5 proposal: stack fill/stroke)
    //
    // Apps name an *intent*, never a color: the shell owns the palette, so a
    // theme change is a change here and nowhere else. Same reasoning as the
    // semantic `text.color` vocabulary already in §5.
    static let accentTint = accent.withAlphaComponent(0.10)
    static let greenTint = green.withAlphaComponent(0.09)
    static let redTint = red.withAlphaComponent(0.09)
    static let sunken = NSColor.black.withAlphaComponent(0.35)
    static let accentStroke = accent.withAlphaComponent(0.25)
    static let greenStroke = green.withAlphaComponent(0.25)
    static let redStroke = red.withAlphaComponent(0.25)
    static let violetTint = violet.withAlphaComponent(0.08)
    static let violetStroke = violet.withAlphaComponent(0.20)
    /// Cyan completes the tint/stroke set so `pill tone="cyan"` (D6) is a triple
    /// from the theme like every other hue, not an improvised alpha.
    static let cyanTint = cyan.withAlphaComponent(0.09)
    static let cyanStroke = cyan.withAlphaComponent(0.25)

    static func systemFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func numericFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    func withAlpha(_ alpha: CGFloat) -> NSColor {
        withAlphaComponent(alpha)
    }
}
