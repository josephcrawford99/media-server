#!/usr/bin/env python3
"""Tiny dashboard server — serves static files and /api/services from Docker socket."""

import http.client
import http.server
import json
import os
import socket

STATIC_DIR = os.path.dirname(os.path.abspath(__file__))
DOCKER_SOCKET = "/var/run/docker.sock"


def query_docker(path):
    """Query the Docker Engine API over the Unix socket."""
    conn = http.client.HTTPConnection("localhost")
    conn.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.sock.connect(DOCKER_SOCKET)
    conn.request("GET", path)
    resp = conn.getresponse()
    data = json.loads(resp.read())
    conn.close()
    return data


def get_services():
    """Return list of services with dashboard labels from running containers."""
    containers = query_docker("/containers/json")
    services = []
    for c in containers:
        labels = c.get("Labels", {})
        if labels.get("dashboard.enabled") != "true":
            continue
        services.append({
            "name": labels.get("dashboard.name", c["Names"][0].strip("/")),
            "port": labels.get("dashboard.port", ""),
            "path": labels.get("dashboard.path", ""),
            "color": labels.get("dashboard.color", "#444"),
            "external": labels.get("dashboard.external", "false") == "true",
            "status": c.get("State", "unknown"),
        })
    # Sort by name for consistent ordering
    services.sort(key=lambda s: s["name"])
    return services


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def do_GET(self):
        if self.path == "/api/services":
            try:
                services = get_services()
                payload = json.dumps(services).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", len(payload))
                self.end_headers()
                self.wfile.write(payload)
            except Exception as e:
                err = json.dumps({"error": str(e)}).encode()
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", len(err))
                self.end_headers()
                self.wfile.write(err)
        else:
            super().do_GET()

    def log_message(self, format, *args):
        # Quiet logs — only errors
        if args and str(args[0]).startswith("2"):
            return
        super().log_message(format, *args)


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", 80), Handler)
    print("Dashboard running on :80")
    server.serve_forever()
