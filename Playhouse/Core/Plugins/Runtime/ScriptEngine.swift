import Foundation

/// The JavaScript engine a plugin runs in. `PluginRuntime` drives the plugin through this
/// interface only, so plugins never depend on a particular engine: on Apple platforms it is
/// JavaScriptCore (`JavaScriptCoreScriptEngine`); a Linux build adds an engine for WebKitGTK's
/// JavaScriptCore or QuickJS and returns it from `ScriptEngines.make`.
///
/// Values cross as `PluginValue`, converted by the engine straight from its own values (a
/// React commit's op array is read without a JSON string in between).
package protocol ScriptEngine: AnyObject {
    /// Called with a readable description of each uncaught script error.
    var onError: ((String) -> Void)? { get set }
    /// Runs a script; an error it throws goes to `onError`.
    func evaluate(_ source: String, sourceURL: URL)
    /// Sets a global variable.
    func setGlobal(_ name: String, to value: PluginValue)
    /// Calls the global function `name`. Nil when there is no such function or its result
    /// can't be read.
    @discardableResult func call(_ name: String, _ arguments: [PluginValue]) -> PluginValue?
    /// Defines a global object whose methods call back into Swift.
    func defineNativeObject(_ name: String, functions: [String: ScriptNativeFunction])
}

/// A Swift function a script can call, with the arguments of that call.
package typealias ScriptNativeFunction = (ScriptArguments) -> Void

/// The arguments of one call from a script into Swift, converted only when read.
package protocol ScriptArguments {
    /// The argument at `index` as a JSON-like value; throws when it isn't one (a cycle, a function).
    func value(_ index: Int) throws -> PluginValue
    func string(_ index: Int) -> String
    func number(_ index: Int) -> Double
    /// The argument as a 32-bit integer, as JavaScript's `| 0` reads it (0 when not a number).
    func int(_ index: Int) -> Int
    func bool(_ index: Int) -> Bool
}

package enum ScriptEngines {
    /// Creates the engine for one plugin; `name` labels it in debuggers.
    package static func make(name: String) throws -> any ScriptEngine {
        #if canImport(JavaScriptCore)
        return try JavaScriptCoreScriptEngine(name: name)
        #else
        throw PluginTreeError(message: "This platform has no JavaScript engine for plugins yet.")
        #endif
    }
}
