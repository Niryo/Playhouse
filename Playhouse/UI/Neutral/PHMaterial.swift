/// The translucent backgrounds Playhouse uses. SwiftUI draws them as materials; a toolkit without
/// materials (GTK) draws a plain panel color instead.
public enum PHMaterial: Sendable {
    case ultraThin
    case regular
    /// The material of a toolbar or bar.
    case bar
}
