"""Serves the a2 test media to the simulator, with the two failures the UI
tests need to be able to produce on demand.

  /a2-clip.mp4     the deterministic clip (range requests supported)
  /a2-poster.jpg   solid yellow, a colour the clip never contains
  /a2-missing.mp4  always 404
  /a2-flaky.mp4    404 until /a2-heal is fetched, then the clip
  /a2-heal         flips the flaky file to working
  /a2-break        flips it back

A UI test can reach /a2-heal itself, which is what turns "error, then retry"
into something that can actually recover on a schedule the test controls.
"""

import http.server
import os
import sys
import threading
import time

DIRECTORY = sys.argv[1]
PORT = int(sys.argv[2])
STATE = {"healed": False}
LOCK = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # One request per connection.
    #
    # With keep-alive, AVPlayer holds the connection open between range
    # requests and this server answers them one at a time on the same thread;
    # a run once stalled with the picture up, the clock frozen at zero and
    # `waiting=EvaluatingBufferingRate` — which reads exactly like a playback
    # defect and was a transport one. Closing each response keeps the two
    # kinds of failure apart.
    def end_headers(self):
        self.send_header("Connection", "close")
        # **Nothing served here may be cached, and `/a2-flaky.mp4` least of
        # all.** That file is 404 in one test and the clip in the next, which
        # is exactly the shape a URL cache is built to flatten: the retry test
        # healed it, the app downloaded it, and the *next run* of the same test
        # replayed those bytes from the simulator's cache instead of asking —
        # so a URL the server was answering 404 for produced a working video,
        # no failure state, no retry button, and a test that failed saying "a
        # 404 video never offered a retry". It had not been offered a 404.
        # The app container survives between runs; this header is what makes
        # the server's state, and not a cache's memory, decide what is seen.
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.close_connection = True
        http.server.BaseHTTPRequestHandler.end_headers(self)

    def do_GET(self):
        self.serve(with_body=True)

    def do_HEAD(self):
        self.serve(with_body=False)

    def serve(self, with_body):
        path = self.path.split("?")[0]

        if path in ("/a2-heal", "/a2-break"):
            with LOCK:
                STATE["healed"] = path == "/a2-heal"
            self.simple(200, b"ok", "text/plain", with_body)
            self.note(200, 2)
            return

        if path == "/a2-missing.mp4":
            self.simple(404, b"no such clip", "text/plain", with_body)
            self.note(404, 0)
            return

        if path == "/a2-slow.mp4":
            # Long enough that "a player exists but there is no picture yet"
            # can be photographed. AVPlayer asks for several ranges, so the
            # window is a few seconds in total.
            time.sleep(1.5)
            path = "/a2-clip.mp4"

        if path == "/a2-flaky.mp4":
            with LOCK:
                healed = STATE["healed"]
            if not healed:
                self.simple(404, b"not yet", "text/plain", with_body)
                self.note(404, 0)
                return
            path = "/a2-clip.mp4"

        name = os.path.basename(path)
        full = os.path.join(DIRECTORY, name)
        if not os.path.isfile(full):
            self.simple(404, b"missing", "text/plain", with_body)
            self.note(404, 0)
            return

        with open(full, "rb") as handle:
            data = handle.read()
        ctype = "video/mp4" if name.endswith(".mp4") else "image/jpeg"

        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            first, _, last = rng[len("bytes="):].partition("-")
            start = int(first) if first else 0
            end = int(last) if last else len(data) - 1
            end = min(end, len(data) - 1)
            chunk = data[start:end + 1]
            self.send_response(206)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(data)))
            self.send_header("Content-Length", str(len(chunk)))
            self.end_headers()
            if with_body:
                self.wfile.write(chunk)
            self.note(206, len(chunk))
            return

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if with_body:
            self.wfile.write(data)
        self.note(200, len(data))

    def note(self, status, length):
        """One line per request, on stderr, so a failing run can be read back.

        `server in tests are green` and `the app asked for a single byte` are
        different claims, and only this can tell them apart: a run that scrolled
        eight times while the first page was still loading reported a playback
        defect and never made a request at all.
        """
        sys.stderr.write(
            "%.3f %s %s range=%s -> %s %s bytes\n" % (
                time.time(), self.command, self.path,
                self.headers.get("Range") or "-", status, length,
            )
        )
        sys.stderr.flush()

    def simple(self, status, body, ctype, with_body):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if with_body:
            self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
print("serving %s on 127.0.0.1:%d" % (DIRECTORY, PORT), flush=True)
server.serve_forever()
