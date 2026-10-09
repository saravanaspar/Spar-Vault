#!/usr/bin/env python3
"""Local-only static server for a compiled web vault, with security headers."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('directory', nargs='?', default='build/web')
parser.add_argument('--port', type=int, default=8080)
args = parser.parse_args()
root = Path(args.directory).resolve()
if not (root / 'index.html').is_file():
    raise SystemExit('Missing index.html. Build the Flutter web app first.')

class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Content-Security-Policy', "default-src 'none'; base-uri 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; worker-src 'self' blob:; manifest-src 'self'; object-src 'none'; frame-ancestors 'none'")
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(), usb=()')
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()

    def list_directory(self, path):
        self.send_error(403, 'Directory listing disabled.')
        return None

    def log_message(self, *_):
        pass

server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(root)))
print(f'Spar Vault is available at http://127.0.0.1:{args.port} (local computer only)', flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    server.server_close()
