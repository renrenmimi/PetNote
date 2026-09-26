#!/usr/bin/env python3
"""Local stand-in for Cloudinary's upload endpoint, for emulator UI tests only.

    python3 scripts/upload-standin.py [--port 8766]

The emulator has no Cloudinary account behind it, so without something here no
UI test can publish a post — the composer refuses to share without media, as
the web client does. An emulator build launched with
`-petnote-upload-standin http://127.0.0.1:8766` sends its uploads here instead
(`UploadSignature.endpoint`, compiled only under PETNOTE_FAULT_INJECTION).

**What this proves, and what it does not.** It proves the client's half: the
multipart request is built with exactly the fields the server signed, it is
sent, and the answer is carried into `createPostCallable`, whose own URL checks
(`validateTrustedHttpsUrl`, `assertOwnCloudinaryAsset`) then run for real in the
functions emulator. It does **not** check the signature — the emulator signs
with fake secrets — and it proves nothing about Cloudinary accepting the
request. The `secure_url` it returns has the right shape for the server's
checks and does not exist on the real CDN, so the image will not load.

Endpoints
  POST /v1_1/<cloud>/<image|video>/upload   multipart; answers like Cloudinary
  GET  /health                              "ok"
  GET  /uploads                             what was received, as JSON, for a
                                            test to assert on
"""

import argparse
import email.parser
import email.policy
import json
import re
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# What `UploadSignature.formFields` sends besides the file: the three signed
# parameters plus the two that authenticate the request. A request missing any
# of them would be refused by Cloudinary, so it is refused here too — a
# stand-in that accepted anything would let the client stop sending one.
REQUIRED_FIELDS = ("api_key", "timestamp", "signature", "folder", "upload_preset")
PATH = re.compile(r"^/v1_1/([^/]+)/(image|video)/upload$")

received = []
lock = threading.Lock()


def parse_multipart(content_type, body):
    """Fields and the file part, from a multipart/form-data body."""
    message = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body
    )
    fields, file_part = {}, None
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name == "file":
            file_part = {
                "filename": part.get_filename(),
                "mime": part.get_content_type(),
                "bytes": len(part.get_payload(decode=True) or b""),
            }
        elif name:
            fields[name] = part.get_content().strip()
    return fields, file_part


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"ok": True})
        elif self.path == "/uploads":
            with lock:
                self._json(200, {"uploads": list(received)})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        match = PATH.match(self.path)
        if not match:
            self._json(404, {"error": {"message": "not an upload path"}})
            return
        cloud, resource_type = match.groups()
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data"):
            self._json(400, {"error": {"message": "expected multipart/form-data"}})
            return

        fields, file_part = parse_multipart(content_type, body)
        missing = [name for name in REQUIRED_FIELDS if not fields.get(name)]
        unexpected = sorted(set(fields) - set(REQUIRED_FIELDS))
        if missing or file_part is None or file_part["bytes"] == 0:
            reason = f"missing {missing}" if missing else "no file"
            self._json(400, {"error": {"message": reason}})
            return
        if unexpected:
            # Cloudinary would reject a signature over parameters it was not
            # given; here the client sending *more* than was signed is the bug.
            self._json(400, {"error": {"message": f"unsigned fields {unexpected}"}})
            return

        stem = f"standin-{uuid.uuid4().hex[:12]}"
        public_id = f"{fields['folder']}/{stem}"
        extension = "mp4" if resource_type == "video" else "jpg"
        secure_url = (
            f"https://res.cloudinary.com/{cloud}/{resource_type}/upload/v1/{public_id}.{extension}"
        )
        record = {
            "cloud": cloud,
            "resourceType": resource_type,
            "folder": fields["folder"],
            "fields": sorted(fields),
            "file": file_part,
            "publicId": public_id,
            "secureUrl": secure_url,
        }
        with lock:
            received.append(record)
        print(f"UPLOAD {resource_type} {file_part['bytes']}B -> {public_id}", flush=True)
        self._json(200, {
            "public_id": public_id,
            "secure_url": secure_url,
            "resource_type": resource_type,
            "format": extension,
            "bytes": file_part["bytes"],
            "version": 1,
        })

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8766)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"upload stand-in on http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
