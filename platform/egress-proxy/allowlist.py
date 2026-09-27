"""
Halden egress proxy — default-deny allowlist addon for mitmproxy.

Enforces the customer's egress policy: every outbound request is checked against a
mounted allowlist. Anything not explicitly allowed is DENIED with a 403 and logged.
An empty allowlist == full air-gap (nothing egresses) — this is what `make air-gap`
switches to, to prove the app still serves with zero egress.

The proxy terminates TLS (mitmproxy's CA signs per-host certs on the fly), so clients
MUST trust the proxy CA — exactly the "proxy that rewrites certs" failure the install
has to survive (see the CA injected into Cap via NODE_EXTRA_CA_CERTS).

Allowlist file format (one entry per line):
    registry-1.docker.io          # exact host
    .docker.io                    # suffix match (any host ending in .docker.io)
    # comments and blank lines ignored
"""
import logging
import os

from mitmproxy import http

ALLOWLIST_PATH = os.environ.get("ALLOWLIST_PATH", "/etc/proxy/allowlist.txt")


def _load(path):
    hosts = []
    try:
        with open(path) as f:
            for line in f:
                line = line.split("#", 1)[0].strip().lower()
                if line:
                    hosts.append(line)
    except FileNotFoundError:
        logging.warning(f"[cage-proxy] allowlist {path} not found -> DENY ALL")
    return hosts


class Allowlist:
    def __init__(self):
        self.hosts = _load(ALLOWLIST_PATH)
        logging.warning(f"[cage-proxy] loaded {len(self.hosts)} allow entries: {self.hosts}")

    def _allowed(self, host: str) -> bool:
        host = (host or "").lower()
        for h in self.hosts:
            if h.startswith("."):
                if host == h[1:] or host.endswith(h):
                    return True
            elif host == h:
                return True
        return False

    # HTTPS: decision happens at the CONNECT before we bump TLS.
    def http_connect(self, flow: http.HTTPFlow):
        host, port = flow.request.host, flow.request.port
        if self._allowed(host):
            logging.warning(f"[cage-proxy] ALLOW CONNECT {host}:{port}")
        else:
            logging.warning(f"[cage-proxy] DENY CONNECT {host}:{port}")
            flow.response = http.Response.make(
                403, b"Blocked by Halden egress proxy: host not in allowlist\n"
            )

    # Plain HTTP (and the bumped inner request).
    def request(self, flow: http.HTTPFlow):
        if flow.request.method == "CONNECT":
            return
        host = flow.request.pretty_host
        if self._allowed(host):
            logging.warning(f"[cage-proxy] ALLOW {flow.request.method} {host}{flow.request.path}")
        else:
            logging.warning(f"[cage-proxy] DENY {flow.request.method} {host}{flow.request.path}")
            flow.response = http.Response.make(
                403, b"Blocked by Halden egress proxy: host not in allowlist\n"
            )


addons = [Allowlist()]
