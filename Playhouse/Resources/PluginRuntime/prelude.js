// The plugin runtime's hand-written prelude. Swift evaluates it first, then
// defines the vendored modules with __playhouseDefine, then calls
// __playhouseBoot(atomNames), then evaluates the plugin. See
// Playhouse/App/Plugins/README.md for the op protocol this sends.
//
// Native functions Swift installs before this file runs:
//   __native.commit(json)          one JSON array of ops per React commit
//   __native.log(level, message)
//   __native.setTimer(id, ms)      Swift calls __playhouseFireTimer(id) when due
//   __native.clearTimer(id)
(function (global) {
  "use strict";

  // CommonJS just big enough for the vendored builds.
  var factories = {};
  var cache = {};
  function require(name) {
    if (cache[name]) return cache[name].exports;
    var factory = factories[name];
    if (!factory) throw new Error("Unknown module: " + name);
    var module = { exports: {} };
    cache[name] = module;
    factory(module, module.exports, require);
    return module.exports;
  }
  global.__playhouseDefine = function (name, factory) { factories[name] = factory; };
  global.process = { env: { NODE_ENV: "production" } };

  function format(args) {
    return Array.prototype.map.call(args, function (value) {
      if (typeof value === "string") return value;
      if (value instanceof Error) return value.stack ? value.message + "\n" + value.stack : String(value);
      try { return JSON.stringify(value); } catch (error) { return String(value); }
    }).join(" ");
  }
  global.console = {
    log: function () { __native.log("log", format(arguments)); },
    info: function () { __native.log("log", format(arguments)); },
    warn: function () { __native.log("warn", format(arguments)); },
    error: function () { __native.log("error", format(arguments)); }
  };

  // Timers run on the host's queue; the scheduler and plugins both use them.
  var timers = {};
  var nextTimer = 1;
  global.setTimeout = function (callback, ms) {
    var id = nextTimer++;
    var args = Array.prototype.slice.call(arguments, 2);
    timers[id] = function () { delete timers[id]; callback.apply(null, args); };
    __native.setTimer(id, Math.max(0, Number(ms) || 0));
    return id;
  };
  global.clearTimeout = function (id) {
    if (timers[id]) { delete timers[id]; __native.clearTimer(id); }
  };
  // An interval is a chain of timeouts; its handle maps to the pending one.
  var intervals = {};
  global.setInterval = function (callback, ms) {
    var handle = nextTimer++;
    function tick() { intervals[handle] = global.setTimeout(tick, ms); callback(); }
    intervals[handle] = global.setTimeout(tick, ms);
    return handle;
  };
  global.clearInterval = function (handle) {
    if (intervals[handle]) { global.clearTimeout(intervals[handle]); delete intervals[handle]; }
  };
  global.queueMicrotask = function (callback) { Promise.resolve().then(callback); };
  // Until boot, timers run unbatched; boot wraps them in batchedUpdates.
  var batch = function (callback) { callback(); };
  global.__playhouseFireTimer = function (id) {
    var timer = timers[id];
    if (timer) batch(function () { run(timer); });
  };

  function run(callback) {
    try { callback(); } catch (error) { reportError(error); }
  }
  function reportError(error) {
    __native.log("error", format([error]));
  }

  global.__playhouseBoot = function (atomNames) {
    var React = require("react");
    var Reconciler = require("react-reconciler");
    var atoms = {};
    atomNames.forEach(function (name) { atoms[name] = true; });

    // Ops collected since the last commit; flushed as one message in resetAfterCommit.
    var ops = [];
    var nextID = 1;
    // Event handlers by node id. Functions never cross into Swift; only their names do.
    var handlers = {};

    function split(props) {
      var payload = {};
      var events = [];
      var handlerMap = {};
      for (var key in props) {
        if (key === "children" || key === "key" || key === "ref") continue;
        var value = props[key];
        if (typeof value === "function") {
          events.push(key);
          handlerMap[key] = value;
        } else if (value !== undefined) {
          payload[key] = value;
        }
      }
      events.sort();
      return { props: payload, events: events, handlers: handlerMap };
    }

    function sameJSON(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

    var hostConfig = {
      supportsMutation: true,
      supportsPersistence: false,
      supportsHydration: false,
      isPrimaryRenderer: true,
      noTimeout: -1,
      supportsMicrotasks: true,
      scheduleMicrotask: global.queueMicrotask,
      scheduleTimeout: global.setTimeout,
      cancelTimeout: global.clearTimeout,
      getCurrentEventPriority: function () { return 16; /* DefaultEventPriority */ },

      getRootHostContext: function () { return { insideText: false }; },
      getChildHostContext: function (parent, type) {
        var insideText = type === "Text";
        return parent.insideText === insideText ? parent : { insideText: insideText };
      },
      shouldSetTextContent: function () { return false; },

      createInstance: function (type, props) {
        if (!atoms[type]) throw new Error("Unknown atom <" + type + ">. Atoms: " + atomNames.join(", "));
        var id = nextID++;
        var parts = split(props);
        handlers[id] = parts.handlers;
        ops.push({ op: "create", id: id, type: type, props: parts.props, events: parts.events });
        return { id: id, type: type };
      },
      createTextInstance: function (text, root, context) {
        if (!context.insideText) throw new Error("Text \"" + text + "\" must be inside a <Text> atom.");
        var id = nextID++;
        ops.push({ op: "createText", id: id, text: String(text) });
        return { id: id, type: "#text" };
      },
      appendInitialChild: function (parent, child) {
        ops.push({ op: "append", parent: parent.id, child: child.id });
      },
      finalizeInitialChildren: function () { return false; },
      prepareUpdate: function (instance, type, oldProps, newProps) {
        var before = split(oldProps), after = split(newProps);
        handlers[instance.id] = after.handlers;
        if (sameJSON(before.props, after.props) && sameJSON(before.events, after.events)) return null;
        return after;
      },
      commitUpdate: function (instance, payload) {
        ops.push({ op: "update", id: instance.id, props: payload.props, events: payload.events });
      },
      commitTextUpdate: function (instance, oldText, newText) {
        ops.push({ op: "text", id: instance.id, text: String(newText) });
      },
      appendChild: function (parent, child) { ops.push({ op: "append", parent: parent.id, child: child.id }); },
      appendChildToContainer: function (container, child) { ops.push({ op: "append", parent: 0, child: child.id }); },
      insertBefore: function (parent, child, before) {
        ops.push({ op: "insert", parent: parent.id, child: child.id, before: before.id });
      },
      insertInContainerBefore: function (container, child, before) {
        ops.push({ op: "insert", parent: 0, child: child.id, before: before.id });
      },
      removeChild: function (parent, child) { ops.push({ op: "remove", parent: parent.id, child: child.id }); },
      removeChildFromContainer: function (container, child) { ops.push({ op: "remove", parent: 0, child: child.id }); },
      detachDeletedInstance: function (instance) { delete handlers[instance.id]; },
      clearContainer: function () { ops.push({ op: "clear" }); },
      resetTextContent: function () {},
      hideInstance: function () {}, unhideInstance: function () {},
      hideTextInstance: function () {}, unhideTextInstance: function () {},
      commitMount: function () {},
      getPublicInstance: function (instance) { return instance; },
      prepareForCommit: function () { return null; },
      resetAfterCommit: function () {
        if (ops.length === 0) return;
        var batch = ops;
        ops = [];
        __native.commit(JSON.stringify(batch));
      },
      preparePortalMount: function () {},
      getInstanceFromNode: function () { return null; },
      beforeActiveInstanceBlur: function () {}, afterActiveInstanceBlur: function () {},
      prepareScopeUpdate: function () {}, getInstanceFromScope: function () { return null; }
    };

    var reconciler = Reconciler(hostConfig);
    // A timer's state updates commit as one batch, like an event's.
    batch = reconciler.batchedUpdates;
    // A legacy (synchronous) root: every update commits before the call that caused it returns.
    var root = reconciler.createContainer({}, 0, null, false, null, "", reportError, null);

    // Swift calls this for an event; the handler's state updates commit as one batch.
    global.__playhouseDispatch = function (id, event, value) {
      var handler = handlers[id] && handlers[id][event];
      if (!handler) return false;
      reconciler.batchedUpdates(function () {
        run(function () { value === undefined ? handler() : handler(value); });
      });
      return true;
    };

    var Playhouse = {
      props: global.__playhouseProps || {},
      render: function (element) { reconciler.updateContainer(element, root, null, null); }
    };
    global.React = React;
    global.h = React.createElement;
    global.Playhouse = Playhouse;
    // Each atom is also a global string constant, so plugins write h(Text, …).
    atomNames.forEach(function (name) { global[name] = name; });
  };
})(this);
