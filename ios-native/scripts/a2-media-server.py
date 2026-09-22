"""Serves the a2 test media to the simulator, with the failures the playback
tests need to be able to produce on demand.

  /a2-clip.mp4     the deterministic 4s clip (range requests supported)
  /a2-long.mp4     the same picture, 16s, for anything that must break *during*
                   playback rather than before it starts
  /a2-poster.jpg   solid yellow, a colour the clip never contains
  /a2-slow.mp4     the clip, answered after a pause (first-load window)
  /a2-missing.mp4  always 404
  /a2-flaky.mp4    404 until /a2-heal is fetched, then the clip
  /a2-heal         flips the flaky file to working
  /a2-break        flips it back

And the four ways a stream dies, which is what the stall work needs:

  /a2-cutoff.mp4     **the stream dies half way.** Range requests that land in
                     the first part of the media data are answered in full, so
                     the item really does reach `.readyToPlay` and really does
                     start playing; a request that crosses CUT_FRACTION gets
                     honest headers, half a body, and then silence with the
                     connection still open; a request that starts beyond it
                     connects and sends nothing at all. `moov` is always
                     served, because an item that never opens is a *different*
                     defect and mixing the two is how "the video is broken"
                     stopped meaning anything.
  /a2-mend           makes /a2-cutoff.mp4 whole again — the network came back
  /a2-cut            breaks it again
  /a2-blackhole.mp4  connects, sends headers, never sends a byte. A timeout
                     that is not a refusal: every layer below AVFoundation
                     thinks it is fine.
  /a2-error500.mp4   an ordinary server error

Why a server and not one unreachable URL: a URL that does not resolve exercises
one branch, at one moment, before anything has played. Every interesting stall
happens *after* the picture is on the glass, and only a server that can answer
correctly and then stop can produce that.
"""

import http.server
import os
import struct
import sys
import threading
import time

DIRECTORY = sys.argv[1]
PORT = int(sys.argv[2])
# **State is per session, not global.**
#
# It used to be one dict for the whole server. Every test that needed a broken
# stream called /a2-cut first, so ordering alone should have been enough — but
# one test mends on purpose, the tests share a process, and nothing made the
# windows disjoint. `automaticRecoveryIsBoundedAndThenOffersAWayOut` failed
# with `phase=playing attempts=0`, which is what a stream that never broke
# looks like.
#
# A session token in the query string (?s=...) gives each test its own
# switches, and as a side effect its own URL — so an asset cached under one
# test's URL cannot answer another's.
#
# Requests without ?s share the "" session, which is exactly the old
# behaviour, so anything not yet converted keeps working.
# **Reentrant.** `session_state` takes this lock, and the switch branches in
# `serve` call it from inside a `with LOCK:` of their own. A plain Lock is not
# reentrant, so that combination deadlocks the worker thread: the connection is
# accepted, never answered, and curl reports 000 with nothing in the log — which
# reads like the server is down rather than like one handler is stuck.
LOCK = threading.RLock()
SESSIONS = {}


def log_switch(token, path, state):
    """One line per switch flip, so a later failure can be read back.

    Printed rather than counted: when a test says the stream never broke, the
    question is whether its own /a2-cut arrived and what the session looked
    like afterwards, and that is two facts on one line.
    """
    print("SWITCH session=%r %s -> %r" % (token or "<shared>", path, state), flush=True)


def session_state(query):
    """The switch dict for this request's session, created on first use."""
    token = ""
    if query:
        for pair in query.split("&"):
            if pair.startswith("s="):
                token = pair[2:]
                break
    with LOCK:
        return token, SESSIONS.setdefault(token, {"healed": False, "mended": False})

# How far into the media data /a2-cutoff.mp4 keeps working. 0.35 of the mdat
# region: comfortably past the point where playback has started and the first
# frames are on screen, and comfortably short of the end, so what breaks is
# playback and not opening.
CUT_FRACTION = float(os.environ.get("A2_CUT_FRACTION", "0.35"))
# **The bytes before the cut arrive at a rate, not all at once.**
#
# Measured, and it is the difference between reproducing the defect and
# reproducing something else. `automaticallyWaitsToMinimizeStalling` means
# AVPlayer does not start at all if it can already tell it will not be able to
# play through: delivered instantly, 35% of the file (and 60%, and 75% — all
# three were tried) leaves the clock at exactly 0.00 and the first frame frozen,
# so what is under test is "never started" rather than "stopped half way".
# Delivered at a little over real time, the same 35% makes throughput look
# healthy, playback commits and starts — and *then* the bytes run out. That is a
# stream breaking mid-playback, holding the last frame it decoded.
DRIP_MULTIPLE = float(os.environ.get("A2_DRIP_MULTIPLE", "2.5"))
DRIP_CHUNK = 2048
# A connection that is "open but silent" has to end some time or the server
# leaks a thread per request. Longer than anything the client waits for.
HANG_SECONDS = 25

_MDAT_CACHE = {}


def mdat_range(path):
    """Where the media data lives, so the cut can land *inside* it.

    Everything that is not `mdat` — `ftyp`, `moov`, `free` — is always served,
    whatever the cut says. That is the difference the whole exercise turns on:
    a response that loses `moov` produces an item that never opens, which is a
    *first-load* failure and already has its own test. Only by keeping the
    index intact does the truncated response mean what it is supposed to mean —
    a video that opens, knows how long it is, plays, and then runs out of
    bytes.

    Parsed rather than assumed, because "the index is at the front" is a
    property of how the fixture is written and a silent change there should
    show up as a parse miss rather than as a mystifying test failure. An
    unparseable file yields the whole file, which degrades to "truncate
    everything after the fraction".
    """
    with LOCK:
        if path in _MDAT_CACHE:
            return _MDAT_CACHE[path]
    size = os.path.getsize(path)
    found = (0, size)
    with open(path, "rb") as handle:
        offset = 0
        while offset + 8 <= size:
            handle.seek(offset)
            header = handle.read(8)
            if len(header) < 8:
                break
            length, kind = struct.unpack(">I4s", header)
            if length == 1:                      # 64-bit extended size
                length = struct.unpack(">Q", handle.read(8))[0]
            elif length == 0:                    # runs to the end of the file
                length = size - offset
            if length < 8:
                break
            if kind == b"mdat":
                found = (offset, length)
                break
            offset += length
    with LOCK:
        _MDAT_CACHE[path] = found
    return found


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
        path, _, query = self.path.partition("?")

        if path in ("/a2-heal", "/a2-break"):
            with LOCK:
                _, st = session_state(query)
                st["healed"] = path == "/a2-heal"
            self.simple(200, b"ok", "text/plain", with_body)
            self.note(200, 2)
            return

        if path in ("/a2-mend", "/a2-cut"):
            with LOCK:
                token, st = session_state(query)
                st["mended"] = path == "/a2-mend"
                log_switch(token, path, st)
            self.simple(200, b"ok", "text/plain", with_body)
            self.note(200, 2)
            return

        if path == "/a2-error500.mp4":
            self.simple(500, b"server is having a bad day", "text/plain", with_body)
            self.note(500, 0)
            return

        if path == "/a2-blackhole.mp4":
            # Connected, answered, and then nothing. The socket stays open, so
            # nothing below AVFoundation reports an error — which is the point:
            # this is the failure that looks identical to "still loading".
            full = os.path.join(DIRECTORY, "a2-long.mp4")
            length = os.path.getsize(full) if os.path.isfile(full) else 1 << 20
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            self.note("200-silent", 0)
            self.hang()
            return

        if path == "/a2-cutoff.mp4":
            with LOCK:
                _, st = session_state(query)
                mended = st["mended"]
            if mended:
                path = "/a2-long.mp4"
            else:
                self.serve_cut(with_body)
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
                _, st = session_state(query)
                healed = st["healed"]
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

    def serve_cut(self, with_body):
        """The clip, up to the point where the stream dies.

        Three answers, and which one a request gets is decided only by where it
        lands in the file — so the behaviour is the same every run and the same
        for however many times AVFoundation re-asks:

          * anywhere inside `moov` → served in full, always. An item that never
            opens is a different defect from a stream that stops, and a test
            that cannot tell them apart proves nothing about either.
          * crossing the cut → honest headers, half the promised body, socket
            closed. Literally "sent half and then stopped".
          * entirely past the cut → headers, then silence, then a closed
            socket. This is what a retry of the dead region meets.
        """
        full = os.path.join(DIRECTORY, "a2-long.mp4")
        if not os.path.isfile(full):
            self.simple(404, b"no long clip; regenerate the media", "text/plain", with_body)
            self.note(404, 0)
            return
        with open(full, "rb") as handle:
            data = handle.read()
        total = len(data)
        mdat_start, mdat_length = mdat_range(full)
        cut = mdat_start + int(mdat_length * CUT_FRACTION)

        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            first, _, last = rng[len("bytes="):].partition("-")
            start = int(first) if first else 0
            end = min(int(last), total - 1) if last else total - 1
        else:
            start, end = 0, total - 1

        # Anything outside the media data — `ftyp`, `moov`, `free` — is served
        # whole, always. See `mdat_range`.
        if start >= mdat_start + mdat_length:
            chunk = data[start:end + 1]
            self.ranged(start, end, total, chunk, with_body)
            self.note("206-index", len(chunk))
            return

        if start >= cut:
            # Nothing is coming. Headers first, so the client believes it.
            self.ranged(start, end, total, b"", with_body, declare=end - start + 1)
            self.note("206-silent", 0)
            self.hang()
            return

        promised = data[start:end + 1]
        delivered = data[start:min(end + 1, cut)]
        # Headers say the whole truth; the body arrives at DRIP_MULTIPLE times
        # the clip's own bitrate and then simply stops.
        seconds_of_media = 16.0
        rate = max((mdat_length / seconds_of_media) * DRIP_MULTIPLE, 1.0)
        self.ranged(start, end, total, b"", with_body, declare=len(promised))
        if with_body:
            sent = 0
            while sent < len(delivered):
                chunk = delivered[sent:sent + DRIP_CHUNK]
                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    self.note("206-dripped-aborted", sent)
                    return
                sent += len(chunk)
                time.sleep(len(chunk) / rate)
        self.note("206-dripped", "%d/%d" % (len(delivered), len(promised)))
        # **Stop sending. Do not hang up.**
        #
        # Measured, and it is the whole difference between the two failures.
        # Closing the socket after a short body is a *transport error*:
        # AVFoundation throws the item away and reports `.failed` without ever
        # parsing the index it was just handed, so the video never opens and
        # nothing ever plays — a first-load failure wearing a mid-stream
        # costume. Holding the connection open with bytes still owed is what a
        # stream that died actually looks like from inside the client: the item
        # opens, knows its duration, plays what arrived, and then sits there.
        # That is the state the app could not see.
        self.hang()

    def hang(self):
        """Owe the client bytes, and never send them.

        **`/a2-mend` deliberately does not release these.** Cutting a hung
        connection short means closing a socket with bytes still owed, and that
        is a transport error: measured, AVFoundation throws the item away and
        reports `.failed`, so "the network came back" would arrive at the client
        as "this video is broken" and the recovery under test would never
        happen. A connection that died stays dead — which is also what a real
        one does. Recovery comes from the *next* request, which is the client's
        job and the thing worth testing.
        """
        time.sleep(HANG_SECONDS)

    def ranged(self, start, end, total, body, with_body, declare=None):
        self.send_response(206)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, total))
        self.send_header("Content-Length", str(declare if declare is not None else len(body)))
        self.end_headers()
        if with_body and body:
            self.wfile.write(body)
            self.wfile.flush()

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
