#!/usr/bin/env python3
"""Generate a same-origin offline cache of compiled public assets only."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/web').resolve()
if not (root / 'index.html').is_file():
    raise SystemExit('Build the Flutter web app first.')
excluded = {'sw.js', 'offline_register.js', '_headers', 'flutter_service_worker.js'}
paths = sorted(p for p in root.rglob('*') if p.is_file() and p.name not in excluded
               and not p.name.endswith(('.map', '.svlt')))
version = hashlib.sha256(b''.join(hashlib.sha256(p.read_bytes()).digest() for p in paths)).hexdigest()[:20]
assets = ['./' + p.relative_to(root).as_posix() for p in paths]
worker = """'use strict';
const CACHE = 'spar-static-VERSION';
const ASSETS = ASSET_LIST;
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(ASSETS)));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys
    .filter(key => (key.startsWith('spar-static-') || key.startsWith('sable-static-')) && key !== CACHE)
    .map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;
  const relative = './' + url.pathname.slice(new URL(self.registration.scope).pathname.length);
  if (event.request.mode === 'navigate') {
    event.respondWith(fetch(event.request).catch(() => caches.match('./index.html')));
  } else if (ASSETS.includes(relative)) {
    event.respondWith(caches.match(event.request).then(cached => cached || fetch(event.request)));
  }
});
""".replace('VERSION', version).replace('ASSET_LIST', json.dumps(assets))
(root / 'sw.js').write_text(worker)
(root / 'offline_register.js').write_text("""'use strict';
if ('serviceWorker' in navigator && window.isSecureContext) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {
      console.warn('Offline asset caching unavailable. Keep an encrypted vault backup.');
    });
  });
}
""")
index = (root / 'index.html').read_text()
if 'offline_register.js' not in index:
    index = index.replace('</body>', '<script src="offline_register.js" defer></script>\n</body>')
(root / 'index.html').write_text(index)
# Update the cache version/index bytes once after injecting the static script.
# The list includes the registration script; it contains no vault data or keys.
assets.append('./offline_register.js')
(root / 'sw.js').write_text(worker.replace(json.dumps(assets[:-1]), json.dumps(assets)))
headers = """/*
  Content-Security-Policy: default-src 'none'; base-uri 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; worker-src 'self' blob:; manifest-src 'self'; object-src 'none'; frame-ancestors 'none'
  X-Content-Type-Options: nosniff
  Referrer-Policy: no-referrer
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()
  Cache-Control: no-cache
"""
(root / '_headers').write_text(headers)
print(f'Prepared offline static cache: {len(assets)} assets. No vault data is included.')
