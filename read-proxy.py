#!/usr/bin/env python3
"""Read-only front door for a local Artifactory OSS instance.

Why this exists
---------------
Artifactory OSS blocks the whole security REST API ("This REST API is available
only in Artifactory Pro"), so a read-only user cannot be scripted, and an access
token cannot be minted (the token endpoint itself needs a token). Spec Kit, in
turn, only knows two credential shapes in ~/.specify/auth.json: Bearer, or Basic
with an EMPTY username. Neither can express "admin + password".

So the anonymous read path is opened here instead, without touching Spec Kit:

  developer / specify  --GET-->  :8083 (this proxy)  --GET + Basic-->  :8082
  CI / release.py      --PUT-->  :8082 directly, with the same credentials

Writes are refused on this port (405), so the anonymous door cannot change
anything. On a licensed Artifactory (Pro/Enterprise) this proxy is unnecessary -
create a real read-only user and a token instead; see docs/ARTIFACTORY.md in
rbal-speckit-toolkit.

Configuration (env):
  UPSTREAM      e.g. http://artifactory:8082    (required)
  ART_USER      user to impersonate upstream    (required)
  ART_PASSWORD  that user's password            (required)
  LISTEN_PORT   default 8083
  LISTEN_ADDR   default 0.0.0.0
"""
from __future__ import annotations

import base64
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("UPSTREAM", "").rstrip("/")
ART_USER = os.environ.get("ART_USER", "")
ART_PASSWORD = os.environ.get("ART_PASSWORD", "")
PORT = int(os.environ.get("LISTEN_PORT", "8083"))
ADDR = os.environ.get("LISTEN_ADDR", "0.0.0.0")

if not UPSTREAM or not ART_USER or not ART_PASSWORD:
    sys.exit("read-proxy: UPSTREAM, ART_USER and ART_PASSWORD must all be set")

AUTH = "Basic " + base64.b64encode(f"{ART_USER}:{ART_PASSWORD}".encode()).decode()
ALLOWED = {"GET", "HEAD"}

# Hop-by-hop headers are never forwarded (RFC 9110 7.6.1). Authorization is
# dropped from the request so a client's own credentials are never honoured
# here, and WWW-Authenticate is dropped from the response so clients do not
# start a challenge they cannot answer.
DROP_REQUEST = {"authorization", "host", "connection", "keep-alive",
                "proxy-authenticate", "proxy-authorization", "te", "trailer",
                "transfer-encoding", "upgrade"}
DROP_RESPONSE = {"www-authenticate", "connection", "keep-alive",
                 "proxy-authenticate", "proxy-authorization", "te", "trailer",
                 "transfer-encoding", "upgrade", "content-encoding", "content-length"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "speckit-read-proxy"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()

    def _refuse(self, code, message):
        body = message.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Allow", "GET, HEAD")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _proxy(self):
        if self.command not in ALLOWED:
            return self._refuse(
                405, "This port is read-only. Publish to Artifactory directly.\n")

        req = urllib.request.Request(UPSTREAM + self.path, method=self.command)
        for key, value in self.headers.items():
            if key.lower() not in DROP_REQUEST:
                req.add_header(key, value)
        req.add_header("Authorization", AUTH)
        # identity encoding keeps the Content-Length we recompute below truthful
        req.add_header("Accept-Encoding", "identity")

        try:
            resp = urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as exc:
            resp = exc
        except Exception as exc:
            return self._refuse(502, f"upstream unreachable: {exc}\n")

        with resp:
            body = resp.read() if self.command != "HEAD" else b""
            self.send_response(resp.status)
            for key, value in resp.headers.items():
                if key.lower() not in DROP_RESPONSE:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

    do_GET = do_HEAD = _proxy
    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _proxy


if __name__ == "__main__":
    print(f"read-proxy: {ADDR}:{PORT} -> {UPSTREAM} as {ART_USER} (GET/HEAD only)",
          flush=True)
    ThreadingHTTPServer((ADDR, PORT), Handler).serve_forever()
