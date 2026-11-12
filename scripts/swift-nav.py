#!/usr/bin/env python3
"""Structural navigation for Swift files, backed by sourcekit-lsp.

Commands print exact symbol boundaries so agents can read a symbol instead of
guessing line windows. See .claude/skills/swift-nav/SKILL.md for usage rules.

A background helper per worktree keeps sourcekit-lsp warm. It starts on the
first call, listens on a Unix socket in the runtime directory, and exits after
an idle timeout. When it cannot start, the command runs sourcekit-lsp for that
call only, so it still answers.
"""

import argparse
import difflib
import fcntl
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

DEFAULT_IDLE_SECONDS = 30 * 60
STARTUP_TIMEOUT_SECONDS = 20
REQUEST_TIMEOUT_SECONDS = 120
SYMBOL_CACHE_LIMIT = 64

KIND_NAMES = {
    1: "file", 2: "module", 3: "ext", 4: "pkg", 5: "class", 6: "func", 7: "var",
    8: "field", 9: "init", 10: "enum", 11: "proto", 12: "func", 13: "var",
    14: "let", 22: "case", 23: "struct", 24: "event", 25: "op", 26: "typeparam",
}
TYPE_KINDS = {2, 3, 5, 10, 11, 23}
FUNCTION_KINDS = {6, 9, 12, 25}
VALUE_KINDS = {7, 8, 13, 14, 22}


class NavError(Exception):
    """A user-facing failure; printed without a traceback."""


class DaemonUnavailable(Exception):
    pass


# --- Runtime locations -------------------------------------------------------

def runtime_dir():
    base = os.environ.get("SWIFT_NAV_RUNTIME_DIR")
    if not base:
        tmp = os.environ.get("TMPDIR") or "/tmp"
        base = os.path.join(tmp, f"swift-nav-{os.getuid()}")
        # macOS limits Unix socket paths to 104 bytes.
        if len(base) > 70:
            base = f"/tmp/swift-nav-{os.getuid()}"
    os.makedirs(base, mode=0o700, exist_ok=True)
    return base


def root_key(root):
    return hashlib.sha256(root.encode()).hexdigest()[:16]


def runtime_paths(root):
    base = runtime_dir()
    key = root_key(root)
    return {
        "socket": os.path.join(base, f"{key}.sock"),
        "lock": os.path.join(base, f"{key}.lock"),
        "state": os.path.join(base, f"{key}.json"),
        "log": os.path.join(base, f"{key}.log"),
    }


def find_root(start):
    try:
        out = subprocess.run(
            ["git", "-C", start, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if out:
            return os.path.realpath(out)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return os.path.realpath(start)


def sourcekit_lsp():
    path = os.environ.get("SWIFT_NAV_SOURCEKIT_LSP") or shutil.which("sourcekit-lsp")
    if not path:
        try:
            path = subprocess.run(["xcrun", "--find", "sourcekit-lsp"], capture_output=True, text=True, check=True).stdout.strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            path = None
    if not path:
        raise NavError("sourcekit-lsp was not found. Install Xcode or a Swift toolchain, or set SWIFT_NAV_SOURCEKIT_LSP.")
    return path


# --- sourcekit-lsp client ----------------------------------------------------

class LanguageServer:
    """A minimal synchronous LSP client that only needs document symbols."""

    def __init__(self, root):
        self.process = subprocess.Popen(
            [sourcekit_lsp()], cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
        self.next_id = 1
        try:
            self.request("initialize", {
                "processId": os.getpid(),
                "rootUri": pathlib.Path(root).as_uri(),
                "capabilities": {"textDocument": {"documentSymbol": {"hierarchicalDocumentSymbolSupport": True}}},
            })
            self.notify("initialized", {})
        except BaseException:
            self.process.kill()
            self.process.wait()
            self.process.stdin.close()
            self.process.stdout.close()
            raise

    @property
    def pid(self):
        return self.process.pid

    def _send(self, message):
        body = json.dumps(message).encode()
        self.process.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.process.stdin.flush()

    def _read(self):
        length = None
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise EOFError("sourcekit-lsp exited")
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1])
        if length is None:
            raise EOFError("sourcekit-lsp sent a message without Content-Length")
        return json.loads(self.process.stdout.read(length))

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params):
        return self.request_many([(method, params)])[0]

    def request_many(self, calls):
        """Sends every request before reading, so sourcekit-lsp can overlap them."""
        ids = {}
        for index, (method, params) in enumerate(calls):
            request_id = self.next_id
            self.next_id += 1
            ids[request_id] = index
            self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        results = [None] * len(calls)
        while ids:
            message = self._read()
            if "method" in message:
                if "id" in message:  # A server-to-client request; acknowledge it.
                    self._send({"jsonrpc": "2.0", "id": message["id"], "result": None})
                continue
            index = ids.pop(message.get("id"), None)
            if index is None:
                continue
            if "error" in message:
                raise RuntimeError(f"sourcekit-lsp error: {message['error'].get('message')}")
            results[index] = message.get("result")
        return results

    def document_symbols(self, documents):
        """Returns hierarchical symbols for each (path, text), using the given text."""
        uris = [pathlib.Path(path).as_uri() for path, _ in documents]
        for uri, (_, text) in zip(uris, documents):
            self.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "swift", "version": 1, "text": text}})
        try:
            return self.request_many([
                ("textDocument/documentSymbol", {"textDocument": {"uri": uri}}) for uri in uris
            ])
        finally:
            # Closing keeps sourcekit-lsp memory flat; results are cached by content.
            for uri in uris:
                self.notify("textDocument/didClose", {"textDocument": {"uri": uri}})

    def close(self):
        try:
            self.request("shutdown", None)
            self.notify("exit", None)
            self.process.wait(timeout=2)
        except Exception:
            self.process.kill()
            self.process.wait()
        finally:
            self.process.stdin.close()
            self.process.stdout.close()


class Backend:
    """Answers symbol requests with a content-keyed cache."""

    def __init__(self, root):
        self.root = root
        self.server = LanguageServer(root)
        self.cache = {}

    def handle(self, request):
        if request.get("op") != "symbols":
            raise NavError(f"unknown request {request.get('op')!r}")
        documents = request["documents"]
        keys = [hashlib.sha256(text.encode()).hexdigest() for _, text in documents]
        missing = [(i, doc) for i, (doc, key) in enumerate(zip(documents, keys)) if key not in self.cache]
        if missing:
            results = self.server.document_symbols([doc for _, doc in missing])
            for (i, _), symbols in zip(missing, results):
                self.cache[keys[i]] = symbols or []
            while len(self.cache) > SYMBOL_CACHE_LIMIT:
                self.cache.pop(next(iter(self.cache)))
        return {"ok": True, "symbols": [self.cache[key] for key in keys]}


# --- Background helper -------------------------------------------------------

def write_state(paths, state):
    tmp = paths["state"] + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(state, handle)
    os.replace(tmp, paths["state"])


def serve(root):
    paths = runtime_paths(root)
    idle_seconds = float(os.environ.get("SWIFT_NAV_IDLE_SECONDS", DEFAULT_IDLE_SECONDS))
    backend = Backend(root)
    staging = paths["socket"] + f".{os.getpid()}"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(staging)
    listener.listen(16)
    listener.settimeout(min(30.0, max(1.0, idle_seconds / 4)))
    state = {
        "pid": os.getpid(), "lsp_pid": backend.server.pid, "root": root,
        "socket": paths["socket"], "started": time.time(), "last_used": time.time(),
        "requests": 0, "idle_seconds": idle_seconds,
    }
    write_state(paths, state)
    os.replace(staging, paths["socket"])  # Publishing the socket marks the helper ready.

    def cleanup(*_):
        try:
            if os.path.exists(paths["socket"]) and os.stat(paths["socket"]).st_ino == socket_inode:
                os.unlink(paths["socket"])
            with open(paths["state"]) as handle:
                if json.load(handle).get("pid") == os.getpid():
                    os.unlink(paths["state"])
        except (OSError, ValueError):
            pass
        backend.server.close()
        os._exit(0)

    socket_inode = os.stat(paths["socket"]).st_ino
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    while True:
        try:
            connection, _ = listener.accept()
        except socket.timeout:
            if time.time() - state["last_used"] >= idle_seconds:
                cleanup()
            # Another helper replaced the socket (for example after recovery).
            if not os.path.exists(paths["socket"]) or os.stat(paths["socket"]).st_ino != socket_inode:
                cleanup()
            continue
        with connection:
            connection.settimeout(REQUEST_TIMEOUT_SECONDS)
            try:
                request = json.loads(read_line(connection))
                if request.get("op") == "ping":
                    response = {"ok": True, "pid": os.getpid()}
                elif request.get("op") == "shutdown":
                    send_line(connection, {"ok": True})
                    cleanup()
                else:
                    response = backend.handle(request)
            except EOFError:
                send_line(connection, {"ok": False, "retry": True, "error": "sourcekit-lsp exited"})
                cleanup()
            except Exception as error:  # Report and keep serving.
                response = {"ok": False, "error": str(error)}
            state["last_used"] = time.time()
            state["requests"] += 1
            write_state(paths, state)
            try:
                send_line(connection, response)
            except OSError:
                pass


def read_line(connection):
    chunks = []
    while True:
        chunk = connection.recv(1 << 20)
        if not chunk:
            break
        chunks.append(chunk)
        if chunk.endswith(b"\n"):
            break
    data = b"".join(chunks)
    if not data:
        raise ConnectionError("empty message")
    return data


def send_line(connection, message):
    connection.sendall(json.dumps(message).encode() + b"\n")


def daemon_request(socket_path, request, timeout=REQUEST_TIMEOUT_SECONDS):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(timeout)
            client.connect(socket_path)
            send_line(client, request)
            response = json.loads(read_line(client))
    except (OSError, ConnectionError, ValueError) as error:
        raise DaemonUnavailable(str(error))
    if not response.get("ok") and response.get("retry"):
        raise DaemonUnavailable(response.get("error", "helper failed"))
    return response


def spawn_daemon(root, paths):
    with open(paths["log"], "ab") as log:
        helper = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "_serve", root],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True,
        )
    deadline = time.time() + STARTUP_TIMEOUT_SECONDS
    while time.time() < deadline:
        if helper.poll() is not None:
            raise DaemonUnavailable(f"helper exited with status {helper.returncode}; see {paths['log']}")
        if os.path.exists(paths["socket"]):
            try:
                daemon_request(paths["socket"], {"op": "ping"}, timeout=5)
                return
            except DaemonUnavailable:
                pass
        time.sleep(0.05)
    raise DaemonUnavailable("helper did not become ready")


def daemon_symbols(root, request):
    paths = runtime_paths(root)
    try:
        return check(daemon_request(paths["socket"], request))
    except DaemonUnavailable:
        pass
    with open(paths["lock"], "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:  # Another caller may have started the helper while this one waited.
            return check(daemon_request(paths["socket"], request))
        except DaemonUnavailable:
            pass
        try:  # Nothing answers on the socket: remove it and start a fresh helper.
            os.unlink(paths["socket"])
        except FileNotFoundError:
            pass
        spawn_daemon(root, paths)
    return check(daemon_request(paths["socket"], request))


def request_symbols(root, documents):
    """Returns symbols for [(path, text)] through the helper, or per call as a fallback."""
    request = {"op": "symbols", "documents": documents}
    if os.environ.get("SWIFT_NAV_NO_DAEMON") != "1":
        try:
            return daemon_symbols(root, request)
        except (DaemonUnavailable, OSError) as error:
            print(f"swift-nav: background helper unavailable ({error}); running sourcekit-lsp for this call only.", file=sys.stderr)
    backend = None
    try:
        backend = Backend(root)
        return check(backend.handle(request))
    except (RuntimeError, EOFError) as error:
        raise NavError(str(error)) from error
    finally:
        if backend is not None:
            backend.server.close()


def check(response):
    if not response.get("ok"):
        raise NavError(response.get("error", "request failed"))
    return response["symbols"]


# --- Symbol model --------------------------------------------------------------

class Symbol:
    def __init__(self, raw, parent):
        self.name = raw["name"]
        self.kind = raw["kind"]
        self.parent = parent
        self.start = raw["range"]["start"]["line"] + 1
        self.end = raw["range"]["end"]["line"] + 1
        self.name_line = raw.get("selectionRange", raw["range"])["start"]["line"] + 1
        self.name_column = raw.get("selectionRange", raw["range"])["start"]["character"]
        self.children = [Symbol(child, self) for child in raw.get("children") or []]

    @property
    def base(self):
        return self.name.split("(", 1)[0]

    @property
    def kind_name(self):
        return KIND_NAMES.get(self.kind, "sym")

    @property
    def path(self):
        names = []
        node = self
        while node:
            names.append(node.name)
            node = node.parent
        return ".".join(reversed(names))

    @property
    def depth(self):
        return 0 if self.parent is None else self.parent.depth + 1

    def walk(self):
        yield self
        for child in self.children:
            yield from child.walk()

    def inside_function(self):
        node = self.parent
        while node:
            if node.kind in FUNCTION_KINDS:
                return True
            node = node.parent
        return False


def load_file(root, file_arg):
    path = os.path.realpath(file_arg)
    if not os.path.isfile(path):
        raise NavError(f"no such file: {file_arg}")
    if not path.endswith(".swift"):
        raise NavError(f"not a Swift file: {file_arg}")
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    return path, text


def symbols_for(root, documents):
    raw_lists = request_symbols(root, documents)
    return [[Symbol(raw, None) for raw in raw_list] for raw_list in raw_lists]


def every_symbol(roots):
    for symbol in roots:
        yield from symbol.walk()


def display_path(path, root):
    try:
        relative = os.path.relpath(path, os.getcwd())
        if not relative.startswith(".."):
            return relative
    except ValueError:
        pass
    return os.path.relpath(path, root) if path.startswith(root + os.sep) else path


def segment_matches(segment, symbol):
    return segment == symbol.name or segment == symbol.base


def matches_query(symbol, segments):
    node = symbol
    for segment in reversed(segments):
        if node is None or not segment_matches(segment, node):
            return False
        node = node.parent
    return True


def resolve(roots, query, line=None):
    segments = [part for part in query.split(".") if part]
    if not segments:
        raise NavError("empty symbol name")
    found = [symbol for symbol in every_symbol(roots) if matches_query(symbol, segments)]
    if line is not None:
        found = [symbol for symbol in found if symbol.start <= line <= symbol.end]
        # Prefer the innermost symbol that contains the line.
        found.sort(key=lambda symbol: symbol.end - symbol.start)
        found = found[:1]
    return found


# --- Commands ------------------------------------------------------------------

def outline_line(symbol, indent):
    label = symbol.name if symbol.kind == 9 else f"{symbol.kind_name} {symbol.name}"
    return f"{'  ' * indent}{symbol.start}-{symbol.end} {label}"


def member_summary(symbol):
    counts = {}
    for child in symbol.children:
        if child.kind in TYPE_KINDS:
            continue
        label = child.kind_name
        counts[label] = counts.get(label, 0) + 1
    if not counts:
        return ""
    return " [" + ", ".join(f"{count} {label}" for label, count in sorted(counts.items(), key=lambda item: -item[1])) + "]"


def command_outline(args, root):
    path, text = load_file(root, args.file)
    roots = symbols_for(root, [(path, text)])[0]
    line_count = len(text.splitlines())
    if args.scope:
        scopes = resolve(roots, args.scope)
        if not scopes:
            raise NavError(not_found_message(roots, args.scope, path, root))
    else:
        scopes = None

    nodes = scopes if scopes else roots
    base = scopes[0].depth if scopes else 0
    pattern = args.grep.lower() if args.grep else None

    def included(symbol):
        if symbol.kind == 26 or symbol.inside_function():
            return args.all
        if symbol.kind in VALUE_KINDS:
            return args.vars or args.all
        return True

    def visible(symbol):
        if args.depth is not None and symbol.depth - base >= args.depth:
            return False
        node = symbol
        while node is not None and node.depth >= base:
            if not included(node):
                return False
            node = node.parent
        return True

    def matching(symbol):
        return pattern is None or any(pattern in s.name.lower() for s in symbol.walk() if visible(s))

    def render(collapsed):
        lines = []

        def emit(symbol):
            if not visible(symbol) or not matching(symbol):
                return
            hidden = symbol in collapsed
            lines.append(outline_line(symbol, symbol.depth - base) + (member_summary(symbol) if hidden else ""))
            for child in symbol.children:
                if not hidden or child.kind in TYPE_KINDS:
                    emit(child)

        for node in nodes:
            emit(node)
        return lines

    # Collapse the types with the most members first until the outline fits.
    collapsed = set()
    lines = render(collapsed)
    full_count = len(lines)
    if not args.full and not scopes and pattern is None and args.depth is None:
        candidates = sorted(
            (s for s in every_symbol(nodes) if s.kind in TYPE_KINDS and visible(s)),
            key=lambda s: -sum(1 for child in s.children if child.kind not in TYPE_KINDS and visible(child)),
        )
        for symbol in candidates:
            if len(lines) <= args.max_lines:
                break
            collapsed.add(symbol)
            lines = render(collapsed)
    total = sum(1 for _ in every_symbol(roots))
    header = f"{display_path(path, root)}: {line_count} lines, {total} symbols"
    if scopes:
        header += f", scope {args.scope}"
    if pattern:
        header += f", names containing '{args.grep}'"
    print(header)
    print("\n".join(lines))
    if collapsed:
        print(f"({len(collapsed)} largest type(s) collapsed to member counts; {full_count} lines otherwise. "
              f"Use `outline {args.file} <Type>`, --grep NAME, or --full.)")


def not_found_message(roots, query, path, root):
    names = sorted({symbol.path for symbol in every_symbol(roots)} | {symbol.name for symbol in every_symbol(roots)})
    close = difflib.get_close_matches(query, names, n=5, cutoff=0.5)
    message = f"symbol '{query}' not found in {display_path(path, root)}"
    if close:
        message += ". Close matches: " + ", ".join(close)
    return message


def doc_comment_start(lines, start):
    index = start - 1  # 1-based start -> index of the line above
    while index >= 1 and lines[index - 1].lstrip().startswith("///"):
        index -= 1
    return index + 1


def signature_end(lines, symbol):
    for number in range(symbol.name_line, symbol.end + 1):
        if "{" in lines[number - 1]:
            return number
    return symbol.end if symbol.end - symbol.start < 3 else symbol.name_line


def command_show(args, root):
    path, text = load_file(root, args.file)
    roots = symbols_for(root, [(path, text)])[0]
    found = resolve(roots, args.symbol, args.line)
    if not found:
        raise NavError(not_found_message(roots, args.symbol, path, root))
    if len(found) > 1 and not args.all:
        listing = "\n".join(f"  {s.start}-{s.end} {s.kind_name} {s.path}" for s in found)
        raise NavError(
            f"'{args.symbol}' matches {len(found)} symbols in {display_path(path, root)}:\n{listing}\n"
            "Pick one with --line <start>, a more qualified name (Type.method or method(label:)), or print all with --all."
        )
    lines = text.split("\n")
    shown = display_path(path, root)
    for index, symbol in enumerate(found):
        start = doc_comment_start(lines, symbol.start) if not args.signature_only else symbol.start
        end = signature_end(lines, symbol) if args.signature_only else symbol.end
        first = max(1, start - args.context)
        last = min(len(lines), end + args.context)
        if index:
            print()
        print(f"{shown}:{symbol.start}-{symbol.end} {symbol.kind_name} {symbol.path}"
              f"  (Read offset={first} limit={last - first + 1})")
        width = len(str(last))
        for number in range(first, last + 1):
            print(f"{number:>{width}}\t{lines[number - 1]}")


def search_files(root, name, include_vendor, paths):
    targets = paths or ["."]
    if shutil.which("rg"):
        command = ["rg", "--line-number", "--no-heading", "--with-filename", "--color", "never",
                   "--word-regexp", "--fixed-strings", "--glob", "*.swift"]
        if not include_vendor:
            command += ["--glob", "!Vendor/**"]
    else:
        command = ["grep", "-rHnwF", "--include=*.swift"]
        if not include_vendor:
            command += ["--exclude-dir=Vendor"]
    command += ["--", name, *targets]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise NavError(f"text search failed: {result.stderr.strip()}")
    hits = {}
    for raw in result.stdout.splitlines():
        file_part, _, rest = raw.partition(":")
        number, _, line_text = rest.partition(":")
        if not number.isdigit():
            continue
        path = os.path.realpath(os.path.join(root, file_part))
        hits.setdefault(path, []).append((int(number), line_text))
    return hits


def command_refs(args, root):
    segments = [part for part in args.symbol.split(".") if part]
    if not segments:
        raise NavError("empty symbol name")
    name = segments[-1].split("(", 1)[0]
    search_paths = [os.path.realpath(path) for path in args.path]
    for path in search_paths:
        if not os.path.exists(path):
            raise NavError(f"no such path: {path}")
    hits = search_files(root, name, args.vendor, search_paths)
    documents = []
    for path in sorted(hits):
        with open(path, encoding="utf-8", errors="replace") as handle:
            documents.append((path, handle.read()))
    symbol_lists = symbols_for(root, documents) if documents else []
    definitions, others, candidates, comments = [], [], [], []
    for (path, _), roots in zip(documents, symbol_lists):
        flat = list(every_symbol(roots))
        for number, line_text in hits[path]:
            location = f"{display_path(path, root)}:{number}"
            declared = [s for s in flat if s.name_line == number and s.base == name]
            if declared:
                for symbol in declared:
                    entry = (symbol, f"{location}  {symbol.kind_name} {symbol.path}")
                    (definitions if matches_query(symbol, segments) else others).append(entry)
                continue
            snippet = line_text.strip()
            if snippet.startswith("//"):
                comments.append(f"{location}  {snippet[:160]}")
                continue
            enclosing = [s for s in flat if s.start <= number <= s.end and s.kind not in {8, 14, 22, 26}]
            context = f"[in {min(enclosing, key=lambda s: s.end - s.start).path}]  " if enclosing else ""
            candidates.append((line_text, f"{location}  {context}{snippet[:160]}"))
    # A function is used by calling it or naming it as a member, so other words
    # with the same spelling (a local `record` variable) are dropped.
    callable_only = bool(definitions) and all(symbol.kind in FUNCTION_KINDS for symbol, _ in definitions)
    if callable_only:
        pattern = re.compile(rf"(\.{re.escape(name)}\b)|(\b{re.escape(name)}\s*[(<{{])")
        uses = [entry for text, entry in candidates if pattern.search(text)]
    else:
        uses = [entry for _, entry in candidates]
    print(f"refs {args.symbol}: best-effort (word search for '{name}' + document symbols; no compiler index). "
          "Uses are name matches and can include other symbols with the same name.")
    if len(segments) > 1:
        print(f"Definitions are filtered to '{args.symbol}'; uses are not filtered by type.")
    if callable_only:
        print(f"Uses are limited to calls and member references; {len(candidates) - len(uses)} other word matches dropped.")
    print(f"definitions ({len(definitions)}):")
    for _, entry in definitions:
        print(f"  {entry}")
    if others:
        print(f"other definitions named '{name}' ({len(others)}):")
        for _, entry in others[:10]:
            print(f"  {entry}")
        if len(others) > 10:
            print(f"  ... {len(others) - 10} more")
    print(f"uses ({len(uses)}):")
    for entry in uses[:args.limit]:
        print(f"  {entry}")
    if len(uses) > args.limit:
        print(f"  ... {len(uses) - args.limit} more (narrow with --path DIR, or raise --limit)")
    if comments and args.comments:
        print(f"comments ({len(comments)}):")
        for entry in comments[:args.limit]:
            print(f"  {entry}")
    elif comments:
        print(f"({len(comments)} matches in comments hidden; --comments shows them)")


def process_rss_kb(pids):
    pids = [str(pid) for pid in pids if pid]
    if not pids:
        return 0
    result = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(pids)], capture_output=True, text=True)
    return sum(int(value) for value in result.stdout.split() if value.isdigit())


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError):
        return False


def is_helper_process(pid, root):
    """Do not signal a PID from stale state unless its command is our helper."""
    if not isinstance(pid, int) or not alive(pid):
        return False
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                            capture_output=True, text=True)
    command = result.stdout.strip()
    return (result.returncode == 0 and os.path.abspath(__file__) in command
            and "_serve" in command and root in command)


def helper_states():
    base = runtime_dir()
    states = []
    for entry in sorted(os.listdir(base)):
        if not entry.endswith(".json"):
            continue
        try:
            with open(os.path.join(base, entry)) as handle:
                states.append(json.load(handle))
        except (OSError, ValueError):
            continue
    return states


def command_status(args, root):
    states = helper_states()
    if not states:
        print(f"no swift-nav helpers running (runtime dir {runtime_dir()})")
        return
    now = time.time()
    for state in states:
        running = alive(state.get("pid"))
        marker = "*" if state.get("root") == root else " "
        if not running:
            print(f"{marker} stale  pid {state.get('pid')}  {state.get('root')}")
            continue
        rss = process_rss_kb([state.get("pid"), state.get("lsp_pid")])
        print(f"{marker} pid {state['pid']} (sourcekit-lsp {state.get('lsp_pid')})  "
              f"idle {int(now - state['last_used'])}s of {int(state.get('idle_seconds', 0))}s  "
              f"requests {state.get('requests', 0)}  memory {rss / 1024:.0f} MB  {state['root']}")


def command_stop(args, root):
    stopped = 0
    for state in helper_states():
        if not args.all and state.get("root") != root:
            continue
        paths = runtime_paths(state["root"])
        try:
            daemon_request(paths["socket"], {"op": "shutdown"}, timeout=5)
        except DaemonUnavailable:
            if is_helper_process(state.get("pid"), state.get("root", "")):
                os.kill(state["pid"], signal.SIGTERM)
        deadline = time.time() + 5
        while alive(state.get("pid")) and time.time() < deadline:
            time.sleep(0.05)
        for leftover in (paths["state"], paths["socket"]):
            if not alive(state.get("pid")):
                try:
                    os.unlink(leftover)
                except FileNotFoundError:
                    pass
        stopped += 1
        print(f"stopped helper for {state['root']}")
    if not stopped:
        print("no matching swift-nav helper")


# --- Entry point ---------------------------------------------------------------

HELP = """\
Structural navigation for Swift files (sourcekit-lsp document symbols).

  outline FILE [SCOPE] [--grep NAME] [--vars] [--all] [--depth N] [--full]
      Types, extensions and functions with start-end lines, indented by nesting.
      Large files collapse members to counts; pass a type (SCOPE) to list its members.
  show FILE SYMBOL [--line N] [--all] [--signature-only] [--context N]
      Print exactly one symbol's source with line numbers. SYMBOL may be
      qualified (Type.method) or labelled (method(_:with:)).
  refs SYMBOL [--path DIR] [--limit N] [--vendor] [--comments]
      Definitions and uses across the repository (best-effort, labelled).
  status | stop [--all]
      Inspect or stop the per-worktree background helper.

The helper starts on first use and exits after SWIFT_NAV_IDLE_SECONDS (default 1800)
without requests. SWIFT_NAV_NO_DAEMON=1 runs sourcekit-lsp for the call only.
"""


def main(argv):
    if len(argv) >= 2 and argv[0] == "_serve":
        serve(argv[1])
        return 0
    parser = argparse.ArgumentParser(prog="swift-nav.py", description=HELP, formatter_class=argparse.RawDescriptionHelpFormatter, usage="%(prog)s {outline,show,refs,status,stop} ...")
    commands = parser.add_subparsers(dest="command", metavar="")
    outline = commands.add_parser("outline", help="nested symbol outline with line ranges")
    outline.add_argument("file")
    outline.add_argument("scope", nargs="?", help="only list members of this symbol (Type or Type.Nested)")
    outline.add_argument("--vars", action="store_true", help="include properties and enum cases")
    outline.add_argument("--all", action="store_true", help="include everything, also locals inside functions")
    outline.add_argument("--depth", type=int, help="maximum nesting depth to print (1 = top level only)")
    outline.add_argument("--grep", metavar="NAME", help="only symbols whose name contains NAME (case-insensitive), with their parents")
    outline.add_argument("--full", action="store_true", help="never collapse members of large files")
    outline.add_argument("--max-lines", type=int, default=150, help=argparse.SUPPRESS)
    show = commands.add_parser("show", help="print one symbol's source with line numbers")
    show.add_argument("file")
    show.add_argument("symbol")
    show.add_argument("--line", type=int, help="pick the match whose range contains this line")
    show.add_argument("--all", action="store_true", help="print every match instead of failing when ambiguous")
    show.add_argument("--signature-only", action="store_true", help="print only the declaration up to its opening brace")
    show.add_argument("--context", type=int, default=0, help="extra lines before and after")
    refs = commands.add_parser("refs", help="definitions and uses of a symbol across the repository")
    refs.add_argument("symbol")
    refs.add_argument("--limit", type=int, default=40, help="maximum uses to print (default 40)")
    refs.add_argument("--path", action="append", default=[], help="only search this file or directory (repeatable)")
    refs.add_argument("--vendor", action="store_true", help="also search Vendor/")
    refs.add_argument("--comments", action="store_true", help="list matches inside comments")
    commands.add_parser("status", help="list running helpers with idle time and memory")
    stop = commands.add_parser("stop", help="stop this worktree's helper")
    stop.add_argument("--all", action="store_true", help="stop helpers for every worktree")
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 2
    root = find_root(os.getcwd())
    handler = {"outline": command_outline, "show": command_show, "refs": command_refs,
               "status": command_status, "stop": command_stop}[args.command]
    try:
        handler(args, root)
    except NavError as error:
        print(f"swift-nav: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"swift-nav: {error}", file=sys.stderr)
        return 1
    except BrokenPipeError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
