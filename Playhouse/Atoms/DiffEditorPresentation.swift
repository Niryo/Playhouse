import Foundation


/// What Monaco has actually rendered, as opposed to the diff the app has asked for.
package struct DiffEditorPresentation: Equatable {
    /// Which load of Monaco rendered it: this stays at "1" for a warm session.
    package let editorTag: String
    package let path: String
    /// True when the editor was already loaded when this diff was opened.
    package let reusedWarmEditor: Bool

    package init(editorTag: String, path: String, reusedWarmEditor: Bool) {
        self.editorTag = editorTag
        self.path = path
        self.reusedWarmEditor = reusedWarmEditor
    }
}
