#if canImport(SwiftUI)
import SwiftUI

// The view features SwiftCrossUI lacks, each behind one PlayhouseUI modifier. On macOS they are
// SwiftUI's own; a Linux build implements them with raw GTK (a context menu, hover tracking) or
// draws nothing where the toolkit can't (shadows, materials, continuous corners, masks).
// scripts/check-module-boundaries.py rejects the SwiftUI forms in atoms and composites.

extension PHImage {
    /// The image of a Playhouse icon.
    public init(icon: PHIcon) {
        self.init(systemName: icon.sfSymbolName)
    }
}

extension PHLabel where Title == PHText, Icon == PHImage {
    /// A title beside a Playhouse icon.
    public init(_ title: some StringProtocol, icon: PHIcon) {
        self.init(title, systemImage: icon.sfSymbolName)
    }
}

extension PHButton where Label == SwiftUI.Label<PHText, PHImage> {
    /// A button labeled with a title and a Playhouse icon.
    public init(_ title: some StringProtocol, icon: PHIcon, role: PHButtonRole? = nil, action: @escaping () -> Void) {
        self.init(title, systemImage: icon.sfSymbolName, role: role, action: action)
    }
}

extension PHRoundedRectangle {
    /// A rounded rectangle with continuous (squircle) corners where the platform draws them.
    public static func phContinuous(cornerRadius: CGFloat) -> PHRoundedRectangle {
        PHRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

extension PHUnevenRoundedRectangle {
    /// The same, with each corner its own radius.
    public static func phContinuous(cornerRadii: RectangleCornerRadii) -> PHUnevenRoundedRectangle {
        PHUnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
    }
}

extension PHMaterial {
    package var shapeStyle: Material {
        switch self {
        case .ultraThin: .ultraThinMaterial
        case .regular: .regularMaterial
        case .bar: .bar
        }
    }
}

extension PHView {
    /// A context menu on right-click.
    public func phContextMenu<MenuItems: PHView>(@PHViewBuilder menuItems: () -> MenuItems) -> some PHView {
        contextMenu(menuItems: menuItems)
    }

    /// A drop shadow.
    public func phShadow(color: PHColor = .init(.sRGBLinear, white: 0, opacity: 0.33), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some PHView {
        shadow(color: color, radius: radius, x: x, y: y)
    }

    /// Tells `action` when the pointer enters (true) and leaves (false) the view.
    public func phOnHover(perform action: @escaping (Bool) -> Void) -> some PHView {
        onHover(perform: action)
    }

    /// Masks the view with the alpha of `mask`.
    public func phMask<Mask: PHView>(alignment: PHAlignment = .center, @PHViewBuilder _ mask: () -> Mask) -> some PHView {
        self.mask(alignment: alignment, mask)
    }

    /// A translucent material behind the view, in `shape`.
    public func phMaterialBackground<S: PHShape>(_ material: PHMaterial, in shape: S) -> some PHView {
        background(material.shapeStyle, in: shape)
    }

    /// A translucent material behind the view.
    public func phMaterialBackground(_ material: PHMaterial) -> some PHView {
        background(material.shapeStyle)
    }
}
#endif
