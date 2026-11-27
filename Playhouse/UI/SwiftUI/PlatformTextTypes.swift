#if os(macOS)
import AppKit
import SwiftUI

// The platform's own font, color and image types, for the rich text that native text views
// draw (an attributed string's attributes) and for pictures decoded off screen. On macOS they
// are AppKit's; a Linux build defines them over Pango and GdkPixbuf.

public typealias PHPlatformFont = NSFont
public typealias PHPlatformFontDescriptor = NSFontDescriptor
public typealias PHPlatformColor = NSColor
public typealias PHPlatformImage = NSImage
public typealias PHParagraphStyle = NSParagraphStyle
public typealias PHMutableParagraphStyle = NSMutableParagraphStyle
public typealias PHTextAttachment = NSTextAttachment
public typealias PHTextTab = NSTextTab
public typealias PHUnderlineStyle = NSUnderlineStyle

extension PHColor {
    /// The SwiftUI color of a platform color, following its light and dark appearances.
    public init(platformColor: PHPlatformColor) {
        self.init(nsColor: platformColor)
    }
}

extension PHImage {
    /// The image of a decoded platform picture.
    public init(platformImage: PHPlatformImage) {
        self.init(nsImage: platformImage)
    }
}

extension PHPlatformFont {
    /// This font with bold and/or italic added, as the font manager converts it.
    public func phAdding(bold: Bool, italic: Bool) -> PHPlatformFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return self }
        return NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}

extension PHView {
    /// Runs `action` when the app becomes active again.
    public func phOnAppActivation(perform action: @escaping @MainActor () -> Void) -> some PHView {
        onNotification(NSApplication.didBecomeActiveNotification) { _ in action() }
    }
}
#endif
