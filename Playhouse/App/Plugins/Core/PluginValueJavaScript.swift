import Foundation
import JavaScriptCore

/// Direct conversion between `PluginValue` and JavaScript values, so a commit,
/// the plugin's props and event values cross without a JSON string in between.
extension PluginValue {
    /// A guard for the native stack; JSON.stringify has a similar limit.
    static let maxJavaScriptDepth = 1000

    /// Reads `value` with JSON.stringify's rules: only an object's own
    /// enumerable keys are read, `undefined`, functions and symbols are left out
    /// of objects and become `null` in arrays, non-finite numbers become
    /// `null`, an object's `toJSON()` (a Date's) is used, and a circular value
    /// is an error.
    init(javaScript value: JSValue) throws {
        var path: [JSValue] = []
        self = try Self.read(value, path: &path) ?? .null
    }

    /// The value, or nil for one JSON leaves out (undefined, a function, a symbol).
    /// Like JSON.stringify, `toJSON` is called at most once per value: its
    /// result is read as is, so a `toJSON` that returns `this` can't recurse.
    private static func read(_ value: JSValue, path: inout [JSValue], callToJSON: Bool = true) throws -> PluginValue? {
        if value.isUndefined || value.isSymbol || isFunction(value) { return nil }
        if value.isNull { return .null }
        if value.isBoolean { return .bool(value.toBool()) }
        if value.isNumber {
            let number = value.toDouble()
            guard number.isFinite else { return .null }
            return .number(number == 0 ? 0 : number)
        }
        if value.isString { return .string(value.toString()) }
        guard value.isObject else {
            throw PluginTreeError(message: "Can't pass the JavaScript value \(value.toString() ?? "?") to Swift.")
        }
        if callToJSON, let toJSON = value.forProperty("toJSON"), isFunction(toJSON) {
            return try read(value.invokeMethod("toJSON", withArguments: []), path: &path, callToJSON: false)
        }
        if path.contains(where: { $0.isEqual(to: value) }) {
            throw PluginTreeError(message: "A value is circular; JSON can't hold it.")
        }
        guard path.count < maxJavaScriptDepth else {
            throw PluginTreeError(message: "A value nests more than \(maxJavaScriptDepth) levels deep.")
        }
        path.append(value)
        defer { path.removeLast() }
        if value.isArray {
            let count = Int(value.forProperty("length")?.toUInt32() ?? 0)
            var items: [PluginValue] = []
            items.reserveCapacity(count)
            for index in 0..<count {
                items.append(try read(value.atIndex(index), path: &path) ?? .null)
            }
            return .array(items)
        }
        // Object.keys, as JSON.stringify uses: own enumerable string keys, not inherited ones.
        let keys = value.context.objectForKeyedSubscript("Object").invokeMethod("keys", withArguments: [value])
        let count = Int(keys?.forProperty("length")?.toUInt32() ?? 0)
        var fields: [String: PluginValue] = [:]
        for index in 0..<count {
            guard let key = keys?.atIndex(index).toString(), let field = value.forProperty(key) else { continue }
            if let read = try read(field, path: &path) { fields[key] = read }
        }
        return .object(fields)
    }

    private static func isFunction(_ value: JSValue) -> Bool {
        guard value.isObject else { return false }
        let context = value.context.jsGlobalContextRef
        guard let object = JSValueToObject(context, value.jsValueRef, nil) else { return false }
        return JSObjectIsFunction(context, object)
    }

    /// The value as a plain JavaScript value in `context`.
    func javaScriptValue(in context: JSContext) -> JSValue {
        switch self {
        case .null:
            return JSValue(nullIn: context)
        case .bool(let value):
            return JSValue(bool: value, in: context)
        case .number(let value):
            return JSValue(double: value, in: context)
        case .string(let value):
            return JSValue(object: value, in: context)
        case .array(let items):
            let array = JSValue(newArrayIn: context)!
            for (index, item) in items.enumerated() {
                array.setValue(item.javaScriptValue(in: context), at: index)
            }
            return array
        case .object(let fields):
            let object = JSValue(newObjectIn: context)!
            for (key, field) in fields {
                object.setValue(field.javaScriptValue(in: context), forProperty: key)
            }
            return object
        }
    }
}
