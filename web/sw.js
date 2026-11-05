// 讓網頁加到主畫面後可以離線使用。
// 更新網站內容時，記得把 VERSION 改掉，手機才會抓新版。
const VERSION = 'v1';
const CACHE = `mediaconv-${VERSION}`;
// 去背 AI 的執行程式（從 CDN 下載，約 28 MB）另外存，網站更新時不用重新下載
const RUNTIME_CACHE = 'mediaconv-runtime';
const RUNTIME_HOSTS = ['cdn.jsdelivr.net'];

// 幫網頁補上「跨來源隔離」標頭（GitHub Pages 不能自己設定），
// 這樣瀏覽器才允許 AI 模型用多執行緒執行，去背會快很多。
function isolate(res) {
  if (!res || res.type === 'opaque' || res.type === 'error') return res;
  const headers = new Headers(res.headers);
  headers.set('Cross-Origin-Opener-Policy', 'same-origin');
  headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
  headers.set('Cross-Origin-Resource-Policy', 'cross-origin');
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}

// 一開始就先存好的檔案（核心功能）
const PRECACHE = [
  './',
  'index.html',
  'css/style.css',
  'js/app.js',
  'js/image.js',
  'js/exif.js',
  'js/video.js',
  'js/pdf.js',
  'js/zip.js',
  'js/preview.js',
  'js/bgremove.js',
  'manifest.webmanifest',
  'icons/icon-192.png',
  'icons/apple-touch-icon.png',
  'vendor/mediabunny.min.mjs',
  'vendor/gifenc.esm.js',
];
// 其他檔案（PDF 函式庫、HEIC/WebP/AAC 備援編碼器）用到時才下載並快取

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(PRECACHE)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((k) => k.startsWith('mediaconv-') && k !== CACHE && k !== RUNTIME_CACHE)
            .map((k) => caches.delete(k)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (RUNTIME_HOSTS.includes(url.hostname)) {
    event.respondWith(
      caches.open(RUNTIME_CACHE).then((cache) =>
        cache.match(request).then(
          (cached) =>
            cached ||
            fetch(request).then((res) => {
              if (res.ok) cache.put(request, res.clone());
              return res;
            }),
        ).then(isolate),
      ),
    );
    return;
  }
  if (url.origin !== location.origin) return; // 模型檔由 Transformers.js 自己存在瀏覽器裡

  // 網頁本身：先試網路（拿到最新版），離線時用快取
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put('index.html', copy));
          return res;
        })
        .catch(() => caches.match('index.html'))
        .then(isolate),
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
    ).then(isolate),
  );
});
