// The plugin runtime's hand-written prelude. Swift evaluates it first, then
// defines the vendored modules with __playhouseDefine, then calls
// __playhouseBoot(atomNames), then evaluates the plugin. See
// Playhouse/App/Plugins/README.md for the op protocol this sends.
//
// Native functions Swift installs before this file runs:
//   __native.commit(ops)           one array of ops per React commit, read by Swift directly
//   __native.log(level, message)
//   __native.setTimer(id, ms)      Swift calls __playhouseFireTimer(id) when due
//   __native.clearTimer(id)
//   __native.hostCall(id, kind, name, arguments)
//                                  Swift answers with __playhouseAnswerHostCall(id, ok, value)
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

    // Ops collected since the last commit; handed to Swift as one array in resetAfterCommit.
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
        __native.commit(batch);
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

    // Host calls: each returns a promise the host settles with __playhouseAnswerHostCall.
    var hostCalls = {};
    var nextHostCall = 1;
    function hostCall(kind, name, args) {
      return new Promise(function (resolve, reject) {
        var id = nextHostCall++;
        hostCalls[id] = { resolve: resolve, reject: reject };
        __native.hostCall(id, kind, name, args === undefined ? null : args);
      });
    }
    global.__playhouseAnswerHostCall = function (id, ok, value) {
      var call = hostCalls[id];
      if (!call) return;
      delete hostCalls[id];
      reconciler.batchedUpdates(function () {
        run(function () {
          if (ok) {
            call.resolve(value);
          } else {
            var error = new Error((value && value.message) || "The host call failed.");
            error.code = value && value.code;
            call.reject(error);
          }
        });
      });
    };

    // fetch(url, {method, headers, body, timeout}): one HTTP or HTTPS request,
    // answered by the host (PluginNetwork). Bodies are text; an HTTP error
    // status still resolves (ok is false), and a request that can't be made
    // rejects with an Error carrying code and message.
    function fetchHeaders(fields) {
      var names = Object.keys(fields);
      return {
        get: function (name) {
          var value = fields[String(name).toLowerCase()];
          return value === undefined ? null : value;
        },
        has: function (name) { return Object.prototype.hasOwnProperty.call(fields, String(name).toLowerCase()); },
        keys: function () { return names.slice(); },
        forEach: function (callback) { names.forEach(function (name) { callback(fields[name], name); }); },
        toJSON: function () { return fields; }
      };
    }
    function fetch(input, init) {
      init = init || {};
      var headers = {};
      var given = init.headers;
      if (given && typeof given.forEach === "function" && !Array.isArray(given)) {
        given.forEach(function (value, name) { headers[String(name)] = String(value); });
      } else if (Array.isArray(given)) {
        given.forEach(function (pair) { headers[String(pair[0])] = String(pair[1]); });
      } else if (given) {
        Object.keys(given).forEach(function (name) { headers[name] = String(given[name]); });
      }
      var request = {
        url: String(input && input.url !== undefined ? input.url : input),
        method: String(init.method || "GET"),
        headers: headers
      };
      if (init.body !== undefined && init.body !== null) request.body = String(init.body);
      if (init.timeout !== undefined) request.timeout = Number(init.timeout);
      return hostCall("net", "fetch", request).then(function (answer) {
        var body = answer.body;
        return {
          ok: answer.status >= 200 && answer.status < 300,
          status: answer.status,
          statusText: answer.statusText,
          url: answer.url,
          redirected: answer.redirected,
          headers: fetchHeaders(answer.headers || {}),
          text: function () { return Promise.resolve(body); },
          json: function () { return new Promise(function (resolve) { resolve(JSON.parse(body)); }); }
        };
      });
    }

    // Swift replaces the props when the placement's context changes.
    var propsListeners = [];
    global.__playhouseSetProps = function (props) {
      Playhouse.props = props || {};
      reconciler.batchedUpdates(function () {
        propsListeners.slice().forEach(function (listener) { run(function () { listener(Playhouse.props); }); });
      });
    };
    function onPropsChange(listener) {
      propsListeners.push(listener);
      return function () {
        var index = propsListeners.indexOf(listener);
        if (index >= 0) propsListeners.splice(index, 1);
      };
    }

    // App events (PluginEvent in Swift): Swift calls __playhouseEmit(name, payload)
    // for "task.statusChanged", "app.focus", "plugin.stateChanged" and "app.launched".
    var eventListeners = {};
    // "app.launched" arrives as the plugin first mounts, often before the effect
    // that listens for it has run: the first listener added later still hears it.
    var unheardLaunch = null;
    global.__playhouseEmit = function (name, payload) {
      var listeners = (eventListeners[name] || []).slice();
      if (name === "app.launched" && listeners.length === 0) unheardLaunch = payload || {};
      reconciler.batchedUpdates(function () {
        listeners.forEach(function (listener) { run(function () { listener(payload || {}); }); });
      });
      return listeners.length;
    };
    function on(name, listener) {
      name = String(name);
      (eventListeners[name] = eventListeners[name] || []).push(listener);
      if (name === "app.launched" && unheardLaunch !== null) {
        var launch = unheardLaunch;
        unheardLaunch = null;
        global.setTimeout(function () {
          if ((eventListeners[name] || []).indexOf(listener) < 0) return;
          reconciler.batchedUpdates(function () { run(function () { listener(launch); }); });
        }, 0);
      }
      return function () {
        var listeners = eventListeners[name] || [];
        var index = listeners.indexOf(listener);
        if (index >= 0) listeners.splice(index, 1);
      };
    }

    // throttle(fn, seconds): the first call runs at once; calls made while it
    // runs (until a promise it returns settles) or within `seconds` after it
    // started collapse into one trailing call with the latest arguments. Use it
    // to keep frequent events from flooding a rate-limited service like GitHub.
    function throttle(fn, seconds) {
      var interval = Math.max(0, Number(seconds) || 0) * 1000;
      // The cooldown is a timer, so it follows the host's clock (and
      // `plugin render --advance`) the way every other timer does.
      var cooling = false;
      var running = false;
      var pendingArgs = null;
      function start(args) {
        running = true;
        cooling = true;
        pendingArgs = null;
        global.setTimeout(function () { cooling = false; schedule(); }, interval);
        var finish = function () { running = false; schedule(); };
        var result;
        try { result = fn.apply(null, args); } catch (error) { reportError(error); }
        if (result && typeof result.then === "function") {
          result.then(finish, function (error) { reportError(error); finish(); });
        } else {
          finish();
        }
      }
      function schedule() {
        if (pendingArgs && !running && !cooling) start(pendingArgs);
      }
      return function () {
        pendingArgs = Array.prototype.slice.call(arguments);
        schedule();
      };
    }

    var Playhouse = {
      props: global.__playhouseProps || {},
      // Listens for an app event; returns a function that stops listening.
      on: on,
      throttle: throttle,
      render: function (element) { reconciler.updateContainer(element, root, null, null); },
      onPropsChange: onPropsChange,
      // The current props, re-rendering the component whenever they change.
      useProps: function () {
        var state = React.useState(Playhouse.props);
        React.useEffect(function () {
          if (state[0] !== Playhouse.props) state[1](Playhouse.props);
          return onPropsChange(function (props) { state[1](props); });
        }, []);
        return state[0];
      },
      // Any Playhouse bridge command, the same ones the CLI sends ("task.list", "task.create", …).
      bridge: function (command, args) { return hostCall("bridge", String(command), args || {}); },
      // Saves one of this plugin's values (null removes it); it comes back as props.state.
      setState: function (key, value) {
        var plugin = Playhouse.props.plugin || {};
        return hostCall("bridge", "plugin.state.set", { pluginID: plugin.id, key: String(key), value: value === undefined ? null : value });
      },
      // What only the window can do.
      ui: {
        close: function () { return hostCall("ui", "close", {}); },
        openTask: function (taskID) { return hostCall("ui", "openTask", { taskID: String(taskID) }); },
        // Shows a task.changes.list entry's diff over the conversation.
        openDiff: function (entry) { return hostCall("ui", "openDiff", entry || {}); },
        // Tells the window the task's folders changed, so it rereads them and bumps props.workspace.revision.
        refreshWorkspace: function () { return hostCall("ui", "refreshWorkspace", {}); },
        // Moves the task to a board column ("Done", "Review", …), as dragging its card would.
        moveTask: function (taskID, status) { return hostCall("ui", "moveTask", { taskID: String(taskID), status: String(status) }); },
        // Opens the task with its pull request conflicts ready to resolve.
        resolveConflicts: function (taskID) { return hostCall("ui", "resolveConflicts", { taskID: String(taskID) }); },
        // Shows an alert over the window, for a failure the user should see.
        alert: function (title, message) { return hostCall("ui", "alert", { title: String(title), message: message == null ? "" : String(message) }); },
        // Opens an http(s) link in the default browser.
        openURL: function (url) { return hostCall("ui", "openURL", { url: String(url) }); },
        // Asks the user to confirm ({title, message, confirm, destructive}); resolves true when they do.
        // Only on the board.
        confirm: function (options) {
          options = options || {};
          return hostCall("ui", "confirm", {
            title: String(options.title || ""), message: options.message == null ? "" : String(options.message),
            confirm: options.confirm == null ? "OK" : String(options.confirm), destructive: options.destructive === true
          });
        },
        composer: {
          setDraft: function (text) { return hostCall("ui", "composer.setDraft", { text: String(text) }); },
          insertText: function (text) { return hostCall("ui", "composer.insertText", { text: String(text) }); },
          replaceSelection: function (text) { return hostCall("ui", "composer.replaceSelection", { text: String(text) }); },
          focus: function () { return hostCall("ui", "composer.focus", {}); }
        }
      }
    };
    global.React = React;
    global.h = React.createElement;
    global.Playhouse = Playhouse;
    global.fetch = fetch;
    // Each atom is also a global string constant, so plugins write h(Text, …).
    atomNames.forEach(function (name) { global[name] = name; });
  };
})(this);
