#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore

/// `ScriptEngine` on JavaScriptCore, the engine Apple platforms ship.
package final class JavaScriptCoreScriptEngine: ScriptEngine {
    private let context: JSContext
    package var onError: ((String) -> Void)?

    package init(name: String) throws {
        guard let context = JSContext() else { throw PluginTreeError(message: "Couldn't create a JavaScript context.") }
        self.context = context
        context.name = name
        context.exceptionHandler = { [weak self] _, exception in
            self?.onError?(Self.describe(exception))
        }
    }

    package func evaluate(_ source: String, sourceURL: URL) {
        context.evaluateScript(source, withSourceURL: sourceURL)
    }

    package func setGlobal(_ name: String, to value: PluginValue) {
        context.setObject(value.javaScriptValue(in: context), forKeyedSubscript: name as NSString)
    }

    package func call(_ name: String, _ arguments: [PluginValue]) -> PluginValue? {
        guard let function = context.objectForKeyedSubscript(name), !function.isUndefined,
              let result = function.call(withArguments: arguments.map { $0.javaScriptValue(in: context) }) else { return nil }
        return try? PluginValue(javaScript: result)
    }

    package func defineNativeObject(_ name: String, functions: [String: ScriptNativeFunction]) {
        let object = JSValue(newObjectIn: context)!
        for (functionName, function) in functions {
            // Arguments are read from the call itself, so one block shape serves every arity.
            let block: @convention(block) () -> Void = {
                function(JavaScriptCoreArguments(values: JSContext.currentArguments() as? [JSValue] ?? []))
            }
            object.setObject(block, forKeyedSubscript: functionName as NSString)
        }
        context.setObject(object, forKeyedSubscript: name as NSString)
    }

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "Unknown JavaScript error" }
        let message = exception.toString() ?? "Unknown JavaScript error"
        if let line = exception.objectForKeyedSubscript("line"), !line.isUndefined, let source = exception.objectForKeyedSubscript("sourceURL")?.toString(), source != "undefined" {
            return "\(message) (\(URL(fileURLWithPath: source).lastPathComponent):\(line.toInt32()))"
        }
        return message
    }
}

private struct JavaScriptCoreArguments: ScriptArguments {
    let values: [JSValue]

    private func argument(_ index: Int) -> JSValue? { values.indices.contains(index) ? values[index] : nil }

    func value(_ index: Int) throws -> PluginValue {
        guard let value = argument(index) else { return .null }
        return try PluginValue(javaScript: value)
    }

    func string(_ index: Int) -> String { argument(index)?.toString() ?? "undefined" }
    func number(_ index: Int) -> Double { argument(index)?.toDouble() ?? .nan }
    func int(_ index: Int) -> Int { Int(argument(index)?.toInt32() ?? 0) }
    func bool(_ index: Int) -> Bool { argument(index)?.toBool() ?? false }
}
#endif
