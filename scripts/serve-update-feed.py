#!/usr/bin/env python3
"""Serves an update test feed over HTTP on 127.0.0.1, like GitHub serves a release.

Used by the bridge and UI update tests with scripts/make-update-fixture.py
--base-url, so a download goes through the app's real network path and reports
real progress. Archives (.zip) are sent in small pieces spread over --seconds, so
a test can watch the download and cancel it. A missing file answers 404.

Prints {"port": N} on one line once it listens, then serves until killed.
"""

import argparse
import functools
import http.server
import json
import socketserver
import sys
import time
from pathlib import Path


class FeedHandler(http.server.SimpleHTTPRequestHandler):
    seconds = 6.0

    def copyfile(self, source, outputfile):
        if not self.path.split("?")[0].endswith(".zip"):
            return super().copyfile(source, outputfile)
        data = source.read()
        pieces = 60
        size = max(1, -(-len(data) // pieces))
        try:
            for start in range(0, len(data), size):
                outputfile.write(data[start:start + size])
                outputfile.flush()
                time.sleep(self.seconds / pieces)
        except (BrokenPipeError, ConnectionResetError):
            # The app canceled the download.
            pass

    def log_message(self, format, *args):
        sys.stderr.write("serve-update-feed: " + (format % args) + "\n")


class FeedServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer looks up the host's full name here, which asks macOS for local
        # network access (a dialog over the test's window); 127.0.0.1 needs no name.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--seconds", type=float, default=6.0, help="how long an archive takes to send")
    options = parser.parse_args()
    FeedHandler.seconds = options.seconds
    handler = functools.partial(FeedHandler, directory=str(options.directory))
    server = FeedServer(("127.0.0.1", 0), handler)
    print(json.dumps({"port": server.server_address[1]}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
