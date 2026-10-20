import AppKit

/// How overlay text is drawn, derived from the display settings.
struct TextAppearance: Equatable {
    /// 0.4...1, applied to the white text.
    var textOpacity: Double = 1
    /// 0...1 darkness of the band behind the text; 0 means no band.
    var bandOpacity: Double = 0
    /// A soft halo, used when the apps behind are not blurred.
    var halo = false

    var textColor: NSColor { NSColor.white.withAlphaComponent(textOpacity) }
    var secondaryColor: NSColor { NSColor.white.withAlphaComponent(textOpacity * 0.62) }
    var band: NSColor? { bandOpacity > 0.01 ? NSColor.black.withAlphaComponent(bandOpacity) : nil }

    var shadow: NSShadow? {
        guard halo else { return nil }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        return shadow
    }
}
