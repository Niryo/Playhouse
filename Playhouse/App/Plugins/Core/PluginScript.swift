import Foundation
import JavaScriptCore

/// The JavaScript every plugin context starts with, and the source transforms
/// applied to logic.js. Shared by the host and the validator so both evaluate
/// logic.js the same way.
enum PluginScript {
    /// Installed after `__playhouseNative` (log, schedule, cancel, call, done) is set.
    /// Defines console, timers, `api`, and the `__playhouse` entry points the host calls.
    static let prelude = #"""
    (function (global) {
      "use strict";
      const native = global.__playhouseNative;
      delete global.__playhouseNative;
      function describe(error) {
        if (error instanceof Error) { return error.stack ? error.message + "\n" + error.stack : error.message; }
        return String(error);
      }
      function format(args) {
        return Array.prototype.map.call(args, function (value) {
          if (typeof value === "string") { return value; }
          if (value instanceof Error) { return describe(value); }
          try { const text = JSON.stringify(value); return text === undefined ? String(value) : text; }
          catch (error) { return String(value); }
        }).join(" ");
      }
      global.console = Object.freeze({
        log: function () { native.log("log", format(arguments)); },
        debug: function () { native.log("log", format(arguments)); },
        info: function () { native.log("info", format(arguments)); },
        warn: function () { native.log("warn", format(arguments)); },
        error: function () { native.log("error", format(arguments)); }
      });
      const timers = {};
      let nextTimer = 1;
      function schedule(fn, ms, args, repeat) {
        if (typeof fn !== "function") { throw new TypeError("Timers need a function."); }
        const id = nextTimer++;
        timers[id] = { fn: fn, args: args, repeat: repeat };
        native.schedule(id, Math.max(0, Number(ms) || 0), repeat);
        return id;
      }
      global.setTimeout = function (fn, ms) { return schedule(fn, ms, Array.prototype.slice.call(arguments, 2), false); };
      global.setInterval = function (fn, ms) { return schedule(fn, ms, Array.prototype.slice.call(arguments, 2), true); };
      global.clearTimeout = global.clearInterval = function (id) {
        if (timers[id]) { delete timers[id]; native.cancel(id); }
      };
      const pending = {};
      let nextCall = 1;
      global.api = Object.freeze({
        call: function (command, args) {
          return new Promise(function (resolve, reject) {
            const token = nextCall++;
            pending[token] = { resolve: resolve, reject: reject };
            native.call(token, String(command), JSON.stringify(args === undefined ? {} : args));
          });
        }
      });
      let actions = {};
      let state = {};
      global.__playhouse = Object.freeze({
        fireTimer: function (id) {
          const timer = timers[id];
          if (!timer) { return; }
          if (!timer.repeat) { delete timers[id]; }
          timer.fn.apply(null, timer.args);
        },
        settle: function (token, ok, text) {
          const call = pending[token];
          if (!call) { return; }
          delete pending[token];
          if (ok) { call.resolve(text === undefined || text === null ? undefined : JSON.parse(text)); }
          else { call.reject(new Error(text)); }
        },
        start: function () {
          const exported = global.__playhouseExports || {};
          const initial = typeof exported.initialState === "function" ? exported.initialState() : exported.initialState;
          state = initial === undefined ? {} : JSON.parse(JSON.stringify(initial));
          actions = exported.actions || {};
          return JSON.stringify(Object.keys(actions).filter(function (name) { return typeof actions[name] === "function"; }));
        },
        state: function () { return JSON.stringify(state === undefined ? null : state); },
        dispatch: function (name, payloadText, token) {
          const fn = actions[name];
          if (typeof fn !== "function") { native.done(token, "logic.js has no action named \"" + name + "\"."); return; }
          let result;
          try { result = fn(state, payloadText === undefined || payloadText === null ? null : JSON.parse(payloadText), global.api); }
          catch (error) { native.done(token, describe(error)); return; }
          Promise.resolve(result).then(
            function () { native.done(token, null); },
            function (error) { native.done(token, describe(error)); }
          );
        }
      });
    })(this);
    """#

    /// Evaluated after logic.js: collects its top-level `initialState` and `actions`.
    static let epilogue = #"""
    globalThis.__playhouseExports = {
      initialState: typeof initialState === "undefined" ? undefined : initialState,
      actions: typeof actions === "undefined" ? undefined : actions
    };
    """#

    /// logic.js may use `export const` / `export function`; a plain script context
    /// has no modules, so the keyword is dropped and the names become globals.
    static func strippingExports(_ source: String) -> String {
        var text = source
        text = text.replacingOccurrences(
            of: #"(?m)^([ \t]*)export[ \t]+(default[ \t]+)?(?=(const|let|var|function|async|class)\b)"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"(?m)^[ \t]*export[ \t]*\{[^}]*\}[ \t]*;?"#, with: "", options: .regularExpression)
        return text
    }

    static func describe(_ exception: JSValue?) -> String {
        guard let exception, !exception.isUndefined else { return "Unknown JavaScript error." }
        let message = exception.toString() ?? "Unknown JavaScript error."
        let line = exception.objectForKeyedSubscript("line").flatMap { $0.isUndefined ? nil : $0.toString() }
        if let stack = exception.objectForKeyedSubscript("stack"), !stack.isUndefined, let text = stack.toString(), !text.isEmpty {
            return "\(message)\n\(text)"
        }
        return line.map { "\(message) (line \($0))" } ?? message
    }
}
