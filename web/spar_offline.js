'use strict';

// Public JS-release assets only. Bump this version with every release build.
// No broad prefix, POST, query URL, vault, transfer, or API-response caching.
const CACHE = 'spar-static-0.2.5-8';
const FILES = [
  '', 'index.html', 'flutter_bootstrap.js', 'main.dart.js',
  'spar_integrations.js', 'manifest.json', 'favicon.png',
  'icons/Icon-192.png', 'icons/Icon-512.png',
  'icons/Icon-maskable-192.png', 'icons/Icon-maskable-512.png',
  'assets/LICENSE', 'assets/NOTICES.Z',
  'assets/assets/fonts/LICENSE.txt',
  'assets/third_party/licenses/Flutter.txt',
  'assets/third_party/licenses/ZXing-Apache-2.0.txt',
  'assets/third_party/licenses/libfido2.txt',
  'assets/FontManifest.json', 'assets/AssetManifest.bin',
  'assets/AssetManifest.bin.json', 'assets/fonts/MaterialIcons-Regular.otf',
  'assets/assets/branding/app_icon.png',
  'assets/assets/fonts/DejaVuSans.ttf',
  'assets/assets/fonts/DejaVuSans-Bold.ttf',
  'assets/assets/fonts/DejaVuSansMono.ttf',
  'assets/shaders/ink_sparkle.frag', 'assets/shaders/stretch_effect.frag',
  'canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm',
  'canvaskit/chromium/canvaskit.js', 'canvaskit/chromium/canvaskit.wasm'
];
const ALLOWED = new Set(FILES.map(path => new URL(path, self.registration.scope).href));
const acceptable = response => response.status === 200 && !response.redirected &&
  response.type === 'basic' &&
  !/\b(no-store|private)\b/i.test(response.headers.get('cache-control') || '');

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    try {
      await Promise.all([...ALLOWED].map(async url => {
        const request = new Request(url, {cache: 'reload', credentials: 'omit'});
        const response = await fetch(request);
        if (!acceptable(response) || response.url !== url) throw new Error('Public asset cache unavailable');
        await cache.put(url, response);
      }));
      await self.skipWaiting();
    } catch (error) {
      await caches.delete(CACHE);
      throw error;
    }
  })());
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith('spar-static-') && name !== CACHE) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET' || !ALLOWED.has(event.request.url)) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(event.request.url);
    if (cached) return cached;
    const response = await fetch(event.request);
    if (acceptable(response) && response.url === event.request.url) await cache.put(event.request.url, response.clone());
    return response;
  })());
});
