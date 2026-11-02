// 讓網頁加到主畫面後可以離線使用。
// 更新網站內容時，記得把 VERSION 改掉，手機才會抓新版。
const VERSION = 'v1';
const CACHE = `mediaconv-${VERSION}`;

// 一開始就先存好的檔案（核心功能）
const PRECACHE = [
  './',
  'index.html',
  'css/style.css',
  'js/app.js',
  'js/image.js',
  'js/exif.js',
  'js/video.js',
  'manifest.webmanifest',
  'icons/icon-192.png',
  'icons/apple-touch-icon.png',
  'vendor/mediabunny.min.mjs',
  'vendor/gifenc.esm.js',
];
// 其他檔案（HEIC/WebP/AAC 備援編碼器）用到時才下載並快取

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(PRECACHE)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('mediaconv-') && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET' || new URL(request.url).origin !== location.origin) return;

  // 網頁本身：先試網路（拿到最新版），離線時用快取
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put('index.html', copy));
          return res;
        })
        .catch(() => caches.match('index.html')),
    );
    return;
  }

  // 其他檔案：先用快取（快），沒有再下載並存起來
  event.respondWith(
    caches.match(request).then(
      (cached) =>
        cached ||
        fetch(request).then((res) => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(request, copy));
          }
          return res;
        }),
    ),
  );
});
