#!/usr/bin/env python3
"""Serve a folder of cambium-openwrt release files to an access point, and
receive the backups cambium-install.sh uploads before it writes flash.

Run it in the folder holding the release files:

    python3 cambium-serve.py [PORT]        (default port 8000)

GET serves the folder, like "python3 -m http.server". Uploads go to
uploads/NAME (the name is reduced to a plain file name):

  POST /upload/NAME                 the body is the whole file
  POST /upload/NAME?offset=N        hex-encoded chunk written at byte N
  POST /upload/NAME?done            finish a chunked upload

Each answer is the SHA-256 of what was stored (the chunk, or the whole
file), which the installer compares with its own. The installer uses the
chunked, hex-encoded form because BusyBox wget stops sending a posted file
at its first zero byte.
"""
import hashlib
import http.server
import os
import re
import sys
import urllib.parse


class Handler(http.server.SimpleHTTPRequestHandler):
    def _reply(self, text):
        body = (text + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _receive(self):
        url = urllib.parse.urlsplit(self.path)
        if not url.path.startswith("/upload/"):
            self.send_error(404, "uploads go to /upload/NAME")
            return
        name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(url.path[len("/upload/"):]))
        if not name or name.startswith("."):
            self.send_error(400, "bad file name")
            return
        query = urllib.parse.parse_qs(url.query, keep_blank_values=True)
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        os.makedirs("uploads", exist_ok=True)
        path = os.path.join("uploads", name)

        if "done" in query:
            # End of a chunked upload: publish the file, answer its SHA-256.
            if not os.path.exists(path + ".part"):
                self.send_error(400, "no upload in progress for " + name)
                return
            os.replace(path + ".part", path)
            digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
            sys.stderr.write(f"received {path} ({os.path.getsize(path)} bytes, sha256 {digest})\n")
            self._reply(digest)
            return
        if "offset" in query:
            # BusyBox wget sends a C string, so chunks arrive hex-encoded.
            try:
                offset = int(query["offset"][0])
                data = bytes.fromhex(re.sub(rb"[^0-9a-fA-F]", b"", body).decode())
            except ValueError:
                self.send_error(400, "bad offset or hex data")
                return
            with open(path + ".part", "r+b" if offset and os.path.exists(path + ".part") else "wb") as out:
                out.seek(offset)
                out.write(data)
            self._reply(hashlib.sha256(data).hexdigest())
            return
        # A whole binary file in one request (e.g. curl --data-binary).
        with open(path, "wb") as out:
            out.write(body)
        digest = hashlib.sha256(body).hexdigest()
        sys.stderr.write(f"received {path} ({len(body)} bytes, sha256 {digest})\n")
        self._reply(digest)

    do_POST = _receive
    do_PUT = _receive


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    print(f"serving {os.getcwd()} on port {port}; backups are saved in {os.path.join(os.getcwd(), 'uploads')}")
    http.server.ThreadingHTTPServer(("", port), Handler).serve_forever()
