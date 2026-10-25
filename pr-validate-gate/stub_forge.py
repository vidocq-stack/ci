#!/usr/bin/env python3
"""A stub of the Forgejo API for the offline tests: stub_forge.py ROUTES_JSON CALLS_LOG.

Prints the port it listens on, then serves until killed. ROUTES_JSON is read again on every request, so a
test changes the forge between two calls by rewriting it. It maps "<METHOD> <path>" (the path with its query
string first, then without it; a bare path means GET) to either a JSON body, answered with 200, or
{"status": <code>, "body": <json>} or {"status": <code>, "text": <plain text>}. An unknown GET answers 404; an unknown write answers 200 {}. Every call
is logged as "<METHOD> <path> <body>". A route "_on <METHOD> <path>" holds routes that the call replaces,
after answering it: the forge after a merge, say.
"""
import http.server
import json
import sys

ROUTES, LOG = sys.argv[1], sys.argv[2]


class Stub(http.server.BaseHTTPRequestHandler):
    def answer(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(f"{method} {self.path} {body}".rstrip() + "\n")
        with open(ROUTES, encoding="utf-8") as fh:
            routes = json.load(fh)
        bare = self.path.split("?", 1)[0]
        keys = [f"{method} {self.path}", f"{method} {bare}"]
        if method == "GET":
            keys += [self.path, bare]
        hit = next((routes[k] for k in keys if k in routes), None)
        if hit is None:
            status, doc = (404, {"message": "not found"}) if method == "GET" else (200, {})
        elif isinstance(hit, dict) and set(hit) <= {"status", "text"} and "text" in hit:
            status, doc = hit["status"], None
        elif isinstance(hit, dict) and set(hit) <= {"status", "body"} and "status" in hit:
            status, doc = hit["status"], hit.get("body", {})
        else:
            status, doc = 200, hit
        effect = routes.get(f"_on {method} {bare}")
        if isinstance(effect, dict):
            routes.update(effect)
            with open(ROUTES, "w", encoding="utf-8") as fh:
                json.dump(routes, fh)
        text = isinstance(hit, dict) and "text" in hit and doc is None
        data = hit["text"].encode() if text else json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8" if text else "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.answer("GET")

    def do_POST(self):
        self.answer("POST")

    def do_PATCH(self):
        self.answer("PATCH")

    def do_PUT(self):
        self.answer("PUT")

    def do_DELETE(self):
        self.answer("DELETE")

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Stub)
print(server.server_address[1], flush=True)
server.serve_forever()
