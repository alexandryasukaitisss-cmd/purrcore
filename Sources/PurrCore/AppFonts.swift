import AppKit
import CoreText

enum AppFonts {
    /// Regular-weight 12pt macOS system font with standard natural width and tabular
    /// digits — matches the right-side menu bar date/time text cleanly without jitter.
    static let statusItemButton: NSFont = {
        let base = NSFont.systemFont(ofSize: 12, weight: .regular)
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }()
}
