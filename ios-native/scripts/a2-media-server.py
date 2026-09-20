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
            return

        if path == "/a2-missing.mp4":
            self.simple(404, b"no such clip", "text/plain", with_body)
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
                return
            path = "/a2-clip.mp4"

        name = os.path.basename(path)
        full = os.path.join(DIRECTORY, name)
        if not os.path.isfile(full):
            self.simple(404, b"missing", "text/plain", with_body)
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
            return

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if with_body:
            self.wfile.write(data)

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
