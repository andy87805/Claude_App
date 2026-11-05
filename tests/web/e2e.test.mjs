// 網頁版端對端測試：在真的瀏覽器（Playwright Chromium）裡選檔、轉換，再檢查輸出檔。
// 執行：node --test tests/web/
// 需要：playwright（npm i -D playwright && npx playwright install chromium）、python3（Pillow、pillow-heif）、ffmpeg

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEB_ROOT = path.resolve(HERE, '../../web');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'mediaconv-web-'));
const FIX = path.join(TMP, 'fixtures');
const OUT = path.join(TMP, 'out');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.webmanifest': 'application/manifest+json',
  '.png': 'image/png',
  '.wasm': 'application/wasm',
};

let server;
let browser;
let baseUrl;

before(async () => {
  execFileSync('python3', [path.join(HERE, 'make_fixtures.py'), FIX]);
  fs.mkdirSync(OUT);
  server = http.createServer((req, res) => {
    const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    let file = path.join(WEB_ROOT, urlPath);
    if (!file.startsWith(WEB_ROOT)) return res.writeHead(403).end();
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) return res.writeHead(404).end();
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  baseUrl = `http://localhost:${server.address().port}/`;
  // 使用 UTF-8 語系，中文檔名的下載才不會被改成 download
  browser = await chromium.launch({ env: { ...process.env, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' } });
});

after(async () => {
  await browser?.close();
  server?.close();
  fs.rmSync(TMP, { recursive: true, force: true });
});

/** 用指定設定轉換檔案，回傳每個檔案的結果（輸出檔會存到 OUT 並附上檢查資訊）。 */
async function convert(files, settings = {}, { initScript } = {}) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e));
  if (initScript) await page.addInitScript(initScript);
  await page.addInitScript((s) => localStorage.setItem('mediaconv-settings', JSON.stringify(s)), settings);
  await page.goto(baseUrl);
  await page.setInputFiles('#fileInput', files.map((f) => path.join(FIX, f)));
  await page.click('#convertBtn');
  await page.waitForFunction(
    () => window.__app.items.length && window.__app.items.every((i) => i.status === 'done' || i.status === 'failed'),
    null,
    { timeout: 180_000 },
  );
  const results = await page.evaluate(async () => {
    const toB64 = async (blob) => {
      const bytes = new Uint8Array(await blob.arrayBuffer());
      let s = '';
      for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      return btoa(s);
    };
    return Promise.all(
      window.__app.items.map(async (i) => ({
        src: i.file.name,
        status: i.status,
        msg: i.el.querySelector('.msg').textContent,
        name: i.result?.file.name,
        b64: i.result ? await toB64(i.result.file) : null,
      })),
    );
  });
  const summary = await page.textContent('#summary');
  await page.close();
  assert.deepEqual(errors, [], `頁面發生錯誤：${errors.join('\n')}`);

  const bySrc = {};
  for (const r of results) {
    if (r.b64) {
      const file = path.join(OUT, `${Date.now()}-${r.name}`);
      fs.writeFileSync(file, Buffer.from(r.b64, 'base64'));
      r.info = JSON.parse(execFileSync('python3', [path.join(HERE, 'inspect_media.py'), file], { encoding: 'utf8' }));
    }
    delete r.b64;
    bySrc[r.src] = r;
  }
  return { results: bySrc, summary };
}

const isBlue = ([r, g, b]) => b > 150 && r < 100 && g < 100;

test('照片轉 JPG：保留 EXIF、自動轉正、透明變白底、壞檔不中斷', async () => {
  const { results: r, summary } = await convert(
    ['rotated.jpg', 'photo.heic', 'photo.png', 'photo.webp', 'alpha.png', 'broken.jpg'],
    { imageFormat: 'jpg', metadata: 'keep' },
  );

  const rot = r['rotated.jpg'];
  assert.equal(rot.status, 'done');
  assert.equal(rot.info.format, 'JPEG');
  assert.deepEqual(rot.info.size, [300, 400], '方向 6 的照片要轉成直的');
  assert.equal(rot.info.orientation, 1, '方向標記要重設成 1');
  assert.ok(isBlue(rot.info.topRight), '原本左上角的藍色轉正後應在右上角');
  assert.equal(rot.info.taken, '2024:05:01 10:20:30');
  assert.equal(rot.info.make, 'TestCam');
  assert.equal(rot.info.gps, true);

  for (const name of ['photo.heic', 'photo.png', 'photo.webp']) {
    const x = r[name];
    assert.equal(x.status, 'done', `${name}: ${x.msg}`);
    assert.equal(x.info.format, 'JPEG');
    assert.deepEqual(x.info.size, [400, 300]);
    assert.equal(x.info.taken, '2024:05:01 10:20:30', `${name} 的拍攝時間`);
    assert.equal(x.info.gps, true, `${name} 的 GPS`);
    assert.ok(isBlue(x.info.topLeft), `${name} 的方向`);
  }
  assert.equal(r['photo.heic'].name, 'photo.jpg');

  assert.ok(r['alpha.png'].info.center.every((c) => c > 245), '透明背景應變成白色');

  assert.equal(r['broken.jpg'].status, 'failed');
  assert.match(r['broken.jpg'].msg, /失敗/);
  assert.match(summary, /成功 5 個，失敗 1 個/);
});

test('照片：移除位置只拿掉 GPS；全部移除則沒有 EXIF', async () => {
  const nogps = (await convert(['rotated.jpg'], { metadata: 'nogps' })).results['rotated.jpg'];
  assert.equal(nogps.info.gps, false);
  assert.equal(nogps.info.taken, '2024:05:01 10:20:30');
  assert.equal(nogps.info.make, 'TestCam');

  const none = (await convert(['rotated.jpg'], { metadata: 'none' })).results['rotated.jpg'];
  assert.equal(none.info.gps, false);
  assert.equal(none.info.taken ?? null, null);
  assert.deepEqual(none.info.size, [300, 400], '沒有 EXIF 時像素仍要轉正');
});

test('照片：縮小尺寸與品質', async () => {
  const big = (await convert(['large.jpg'], { maxSize: '1920', quality: 70 })).results['large.jpg'];
  assert.deepEqual(big.info.size, [1920, 1280]);
  assert.equal(big.info.taken, '2024:05:01 10:20:30');
});

test('照片反向轉換：JPG 轉 PNG、WebP，並保留 EXIF', async () => {
  for (const [fmt, pil] of [['png', 'PNG'], ['webp', 'WEBP']]) {
    const x = (await convert(['rotated.jpg'], { imageFormat: fmt })).results['rotated.jpg'];
    assert.equal(x.info.format, pil);
    assert.equal(x.name, `rotated.${fmt}`);
    assert.deepEqual(x.info.size, [300, 400]);
    assert.equal(x.info.taken, '2024:05:01 10:20:30', `${fmt} 的拍攝時間`);
    assert.equal(x.info.gps, true, `${fmt} 的 GPS`);
  }
});

test('WebP：瀏覽器不支援 WebP 編碼時（像 iPhone Safari）改用內附編碼器', async () => {
  // 模擬 Safari：canvas 要求 WebP 時回傳 PNG
  const initScript = () => {
    const orig = HTMLCanvasElement.prototype.toBlob;
    HTMLCanvasElement.prototype.toBlob = function (cb, type, q) {
      return orig.call(this, cb, type === 'image/webp' ? 'image/png' : type, q);
    };
  };
  const x = (await convert(['photo.png'], { imageFormat: 'webp' }, { initScript })).results['photo.png'];
  assert.equal(x.status, 'done', x.msg);
  assert.equal(x.info.format, 'WEBP');
  assert.equal(x.info.taken, '2024:05:01 10:20:30');
});

test('影片轉 MP4（H.264）：MOV、MKV（Opus 音訊）、WebM；AVI 給出清楚的錯誤', async () => {
  const { results: r } = await convert(['clip.mov', 'opus.mkv', 'clip.webm', 'old.avi'], { videoFormat: 'mp4' });

  for (const name of ['clip.mov', 'opus.mkv', 'clip.webm']) {
    const x = r[name];
    assert.equal(x.status, 'done', `${name}: ${x.msg}`);
    assert.equal(x.info.vcodec, 'h264', `${name} 的影像編碼`);
    assert.equal(x.info.acodec, 'aac', `${name} 的聲音編碼`);
    assert.deepEqual(x.info.size, [1280, 720]);
    assert.ok(Math.abs(x.info.duration - 3) < 0.3, `${name} 長度 ${x.info.duration}`);
  }
  assert.equal(r['clip.mov'].name, 'clip.mp4');
  assert.doesNotMatch(r['clip.mov'].msg, /聲音/);
  assert.ok(r['clip.mov'].info.creation_time, '拍攝時間要保留');
  assert.equal(r['old.avi'].status, 'failed');
  assert.match(r['old.avi'].msg, /AVI|不支援|無法/);
});

test('影片：解析度只縮小、直式影片方向正確', async () => {
  const { results: r } = await convert(['clip.mov', 'portrait.mp4'], { resolution: '480p' });
  assert.deepEqual(r['clip.mov'].info.size, [854, 480]);
  assert.deepEqual(r['portrait.mp4'].info.size, [480, 854]);

  const up = (await convert(['clip.mov'], { resolution: '1080p' })).results['clip.mov'];
  assert.deepEqual(up.info.size, [1280, 720], '不應放大');
});

test('影片：畫質「高」且已是 H.264 時直接搬移；「中」「低」會重新壓縮', async () => {
  const run = (q) => convert(['clip.mov'], { videoQuality: q });
  const medium = (await run('medium')).results['clip.mov'];
  const low = (await run('low')).results['clip.mov'];
  const size = (r) => Number(r.msg.match(/([\d.]+) (KB|MB)/).slice(1).reduce((n, u) => n * (u === 'MB' ? 1024 : 1)));
  assert.equal(low.info.vcodec, 'h264');
  assert.equal(low.info.acodec, 'aac');
  assert.ok(size(low) < size(medium), `低畫質 ${low.msg} 應小於中畫質 ${medium.msg}`);
});

test('影片轉 WebM 與 MOV', async () => {
  const webm = (await convert(['clip.mov'], { videoFormat: 'webm' })).results['clip.mov'];
  assert.equal(webm.info.vcodec, 'vp9');
  assert.equal(webm.info.acodec, 'opus');

  const mov = (await convert(['clip.webm'], { videoFormat: 'mov' })).results['clip.webm'];
  assert.equal(mov.name, 'clip.mov');
  assert.equal(mov.info.vcodec, 'h264');
});

test('影片轉 GIF：擷取指定片段與寬度', async () => {
  const x = (
    await convert(['clip.mov'], { videoFormat: 'gif', gifStart: 1, gifDuration: 1, gifWidth: '320', gifFps: '10' })
  ).results['clip.mov'];
  assert.equal(x.status, 'done', x.msg);
  assert.equal(x.info.format, 'GIF');
  assert.deepEqual(x.info.size, [320, 180]);
  assert.ok(Math.abs(x.info.duration - 1) < 0.2, `GIF 長度 ${x.info.duration}`);
});

test('加到主畫面後可以離線開啟並轉換照片', async () => {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(baseUrl);
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload(); // 讓 service worker 接管頁面
  await context.setOffline(true);
  await page.reload();
  assert.equal(await page.textContent('h1'), '轉檔工具');
  await page.setInputFiles('#fileInput', [path.join(FIX, 'photo.png')]);
  await page.click('#convertBtn');
  await page.waitForFunction(() => window.__app.items.every((i) => i.status === 'done' || i.status === 'failed'));
  assert.equal(await page.evaluate(() => window.__app.items[0].status), 'done');
  await context.close();
});

// ---------------- 壓縮模式 ----------------

const fileSize = (name) => fs.statSync(path.join(FIX, name)).size;
const outSize = (r) => {
  const m = r.msg.match(/([\d.]+) (B|KB|MB)/);
  return m ? Number(m[1]) * { B: 1, KB: 1024, MB: 1024 * 1024 }[m[2]] : null;
};

test('壓縮照片：標準程度縮到最長邊 2048、保留 EXIF；已經很小的照片保留原檔', async () => {
  const { results: r, summary } = await convert(['noisy.jpg', 'photo.webp'], { mode: 'compress', level: 'standard' });
  const n = r['noisy.jpg'];
  assert.equal(n.status, 'done', n.msg);
  assert.equal(n.info.format, 'JPEG');
  assert.deepEqual(n.info.size, [2048, 1365]);
  assert.equal(n.info.taken, '2024:05:01 10:20:30');
  assert.ok(outSize(n) < fileSize('noisy.jpg') / 3, n.msg);

  // 很小的 WebP 轉成 JPG 反而變大 -> 保留原本的 WebP
  const tiny = r['photo.webp'];
  assert.match(tiny.msg, /保留原檔/);
  assert.equal(tiny.name, 'photo.webp');
  assert.equal(tiny.info.format, 'WEBP');
  assert.match(summary, /總大小/);
});

test('壓縮照片：上限很寬鬆時仍照壓縮程度處理', async () => {
  const x = (await convert(['noisy.jpg'], { mode: 'compress', level: 'standard', targetSize: '26214400' })).results['noisy.jpg'];
  assert.deepEqual(x.info.size, [2048, 1365]);
});

test('壓縮照片：指定目標大小', async () => {
  const x = (await convert(['noisy.jpg'], { mode: 'compress', targetSize: '512000' })).results['noisy.jpg'];
  assert.equal(x.status, 'done', x.msg);
  assert.ok(outSize(x) <= 500 * 1024, x.msg);
  assert.equal(x.info.taken, '2024:05:01 10:20:30');
});

test('壓縮影片：標準 720p，目標大小也能符合', async () => {
  const std = (await convert(['hd.mov'], { mode: 'compress', level: 'standard' })).results['hd.mov'];
  assert.equal(std.status, 'done', std.msg);
  assert.equal(std.name, 'hd.mp4');
  assert.equal(std.info.vcodec, 'h264');
  assert.equal(std.info.acodec, 'aac');
  assert.deepEqual(std.info.size, [1280, 720]);
  assert.ok(outSize(std) < fileSize('hd.mov'), std.msg);

  const target = 300 * 1024;
  const t = (await convert(['hd.mov'], { mode: 'compress', targetSize: String(target) })).results['hd.mov'];
  assert.equal(t.status, 'done', t.msg);
  assert.ok(outSize(t) <= target, t.msg);
  assert.equal(t.info.vcodec, 'h264');
  assert.equal(t.info.acodec, 'aac');
});

test('壓縮 PDF：重新壓縮圖片（JPEG 與無損圖片），文字 PDF 保留原檔，加密 PDF 給出清楚錯誤', async () => {
  const { results: r } = await convert(['scan.pdf', 'flate.pdf', 'text.pdf', 'locked.pdf'], { mode: 'compress' });

  const scan = r['scan.pdf'];
  assert.equal(scan.status, 'done', scan.msg);
  assert.equal(scan.info.pages, 1);
  assert.deepEqual(scan.info.filters, ['/DCTDecode']);
  assert.ok(outSize(scan) < fileSize('scan.pdf') * 0.6, scan.msg);

  const flate = r['flate.pdf'];
  assert.equal(flate.status, 'done', flate.msg);
  assert.deepEqual(flate.info.filters, ['/DCTDecode'], '無損圖片應轉成 JPG');
  assert.ok(outSize(flate) < fileSize('flate.pdf') * 0.5, flate.msg);

  const text = r['text.pdf'];
  assert.equal(text.status, 'done', text.msg);
  assert.match(text.msg, /沒有可以壓縮的圖片|保留原檔/);
  assert.equal(text.info.pages, 2);
  assert.equal(text.info.fonts, 2, '文字 PDF 不能被破壞');

  assert.equal(r['locked.pdf'].status, 'failed');
  assert.match(r['locked.pdf'].msg, /密碼/);
});

test('壓縮 PDF：強力模式把每頁轉成圖片', async () => {
  const x = (await convert(['scan.pdf'], { mode: 'compress', level: 'strong' })).results['scan.pdf'];
  assert.equal(x.status, 'done', x.msg);
  assert.equal(x.info.pages, 1);
  assert.equal(x.info.fonts, 0);
  assert.ok(outSize(x) < fileSize('scan.pdf') * 0.3, x.msg);
  assert.match(x.msg, /文字無法選取/);
});

test('轉換格式模式選到 PDF 會提示改用壓縮模式', async () => {
  const x = (await convert(['scan.pdf'], { mode: 'convert' })).results['scan.pdf'];
  assert.equal(x.status, 'failed');
  assert.match(x.msg, /壓縮檔案/);
});

// ---------------- 移除與全部下載 ----------------

test('選錯檔案可以個別按叉叉移除，剩下的照常轉換', async () => {
  const page = await browser.newPage();
  await page.goto(baseUrl);
  await page.setInputFiles('#fileInput', ['rotated.jpg', 'photo.png', 'broken.jpg'].map((f) => path.join(FIX, f)));
  assert.equal(await page.textContent('#count'), '(3)');

  await page.locator('.file', { hasText: 'broken.jpg' }).locator('.remove').click();
  await page.waitForFunction(() => document.querySelectorAll('.file').length === 2);
  assert.equal(await page.textContent('#count'), '(2)');
  assert.deepEqual(await page.evaluate(() => window.__app.items.map((i) => i.file.name)), ['rotated.jpg', 'photo.png']);

  await page.click('#convertBtn');
  await page.waitForFunction(() => window.__app.items.every((i) => i.status === 'done' || i.status === 'failed'));
  assert.match(await page.textContent('#summary'), /成功 2 個/);
  assert.doesNotMatch(await page.textContent('#summary'), /失敗/);

  // 全部移除後清單隱藏
  for (let n = 0; n < 2; n++) await page.locator('.file:not(.leaving) .remove').first().click();
  await page.waitForFunction(() => document.querySelectorAll('.file').length === 0);
  assert.equal(await page.isHidden('#listSection'), true);
  await page.close();
});

test('全部下載：一個檔案直接下載，多個檔案打包成 ZIP（中文檔名不亂碼）', async () => {
  const page = await browser.newPage({ acceptDownloads: true });
  await page.goto(baseUrl);

  // 一個檔案
  await page.setInputFiles('#fileInput', [path.join(FIX, 'rotated.jpg')]);
  await page.click('#convertBtn');
  await page.waitForSelector('#downloadAllBtn:not([hidden])');
  assert.equal(await page.isHidden('#saveAllBtn'), true, '不能分享的瀏覽器不顯示「全部儲存／分享」');
  assert.equal((await page.textContent('#downloadAllBtn')).trim(), '下載');
  const [single] = await Promise.all([page.waitForEvent('download'), page.click('#downloadAllBtn')]);
  assert.equal(single.suggestedFilename(), 'rotated.jpg');

  // 多個檔案（含中文檔名）
  await page.click('#clearBtn');
  await page.waitForFunction(() => window.__app.items.length === 0);
  await page.setInputFiles('#fileInput', [
    { name: '旅行照片.png', mimeType: 'image/png', buffer: fs.readFileSync(path.join(FIX, 'photo.png')) },
    { name: 'photo.webp', mimeType: 'image/webp', buffer: fs.readFileSync(path.join(FIX, 'photo.webp')) },
    { name: 'clip.mov', mimeType: 'video/quicktime', buffer: fs.readFileSync(path.join(FIX, 'clip.mov')) },
  ]);
  await page.click('#convertBtn');
  await page.waitForFunction(() => window.__app.items.every((i) => i.status === 'done' || i.status === 'failed'));
  assert.equal((await page.textContent('#downloadAllBtn')).trim(), '全部下載');
  const expected = await page.evaluate(async () =>
    Promise.all(window.__app.items.map(async (i) => ({
      name: i.result.file.name,
      size: i.result.file.size,
      sha: [...new Uint8Array(await crypto.subtle.digest('SHA-256', await i.result.file.arrayBuffer()))]
        .map((b) => b.toString(16).padStart(2, '0')).join(''),
    }))),
  );
  const [zip] = await Promise.all([page.waitForEvent('download'), page.click('#downloadAllBtn')]);
  assert.match(zip.suggestedFilename(), /^轉檔結果-\d{8}-\d{4}\.zip$/);
  const zipPath = path.join(OUT, 'all.zip');
  await zip.saveAs(zipPath);
  const listing = JSON.parse(execFileSync('python3', ['-c', `
import hashlib, json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.testzip() is None
    print(json.dumps([{"name": i.filename, "size": i.file_size, "sha": hashlib.sha256(z.read(i)).hexdigest()} for i in z.infolist()]))
`, zipPath], { encoding: 'utf8' }));
  assert.deepEqual(listing, expected);
  assert.ok(listing.some((f) => f.name === '旅行照片.jpg'));
  await page.close();
});

// ---------------- 預覽 ----------------

async function prepared(files, settings = {}) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e));
  await page.addInitScript((s) => localStorage.setItem('mediaconv-settings', JSON.stringify(s)), settings);
  await page.goto(baseUrl);
  await page.setInputFiles('#fileInput', files.map((f) => path.join(FIX, f)));
  await page.click('#convertBtn');
  await page.waitForFunction(() => window.__app.items.every((i) => i.status === 'done' || i.status === 'failed'));
  return { page, errors };
}

test('預覽照片：點擊檔案開啟、可切換原檔比較、可左右切換、可關閉', async () => {
  const { page, errors } = await prepared(['noisy.jpg', 'rotated.jpg'], { mode: 'compress' });

  // 點下載按鈕不會開預覽
  await page.locator('.file', { hasText: 'noisy.jpg' }).locator('a.small').click();
  assert.equal(await page.evaluate(() => document.querySelector('#preview').open), false);

  await page.locator('.file', { hasText: 'noisy.jpg' }).locator('.name').click();
  await page.waitForFunction(() => document.querySelector('#preview').open);
  await page.waitForFunction(() => document.querySelector('.pv-image')?.naturalWidth > 0);
  assert.equal(await page.textContent('.pv-name'), 'noisy.jpg');
  assert.match(await page.textContent('.pv-sub'), /2048 × 1365/);
  assert.match(await page.textContent('.pv-sub'), /小了 \d+%/);
  assert.equal(await page.textContent('.pv-count'), '1 / 2');

  // 原檔比較
  await page.click('.pv-toggle button[data-view="original"]');
  await page.waitForFunction(() => document.querySelector('.pv-image')?.naturalWidth === 3000);
  assert.match(await page.textContent('.pv-sub'), /3000 × 2000/);

  // 下一個
  await page.click('.pv-next');
  await page.waitForFunction(() => document.querySelector('.pv-name').textContent === 'rotated.jpg');
  await page.waitForFunction(() => document.querySelector('.pv-image')?.naturalWidth > 0);

  // 點照片放大、再點縮回
  await page.click('.pv-image');
  assert.equal(await page.evaluate(() => document.querySelector('.pv-stage').classList.contains('zoomed')), true);
  await page.click('.pv-image');
  assert.equal(await page.evaluate(() => document.querySelector('.pv-stage').classList.contains('zoomed')), false);

  // 鍵盤 Esc 關閉
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('#preview').open);
  assert.deepEqual(errors, []);
  await page.close();
});

test('預覽影片與 PDF', async () => {
  const { page, errors } = await prepared(['clip.mov', 'scan.pdf'], { mode: 'compress' });

  await page.locator('.file', { hasText: 'clip.mov' }).click();
  await page.waitForFunction(() => document.querySelector('#preview').open);
  assert.equal(await page.locator('.pv-video').count(), 1);
  assert.match(await page.getAttribute('.pv-video', 'src'), /^blob:/);

  await page.click('.pv-next');
  await page.waitForFunction(() => document.querySelectorAll('.pv-page').length === 1, null, { timeout: 30_000 });
  assert.ok(await page.evaluate(() => document.querySelector('.pv-page').width > 100));
  assert.match(await page.textContent('.pv-sub'), /1 頁/);

  await page.click('.pv-close');
  await page.waitForFunction(() => !document.querySelector('#preview').open);
  assert.equal(await page.locator('.pv-stage > *').count(), 0, '關閉後要清掉預覽內容');
  assert.deepEqual(errors, []);
  await page.close();
});

// ---------------- 去背 ----------------
// 第一次執行會從 Hugging Face 下載 AI 模型（約 42 MB），需要網路。

test('去背：透明背景 PNG、白色背景 JPG，非照片給出清楚錯誤', { timeout: 600_000 }, async () => {
  const { results: r } = await convert(['apple.jpg', 'scan.pdf'], { mode: 'removebg', bgColor: 'transparent' });
  const a = r['apple.jpg'];
  assert.equal(a.status, 'done', a.msg);
  assert.equal(a.name, 'apple.png');
  assert.equal(a.info.format, 'PNG');
  assert.equal(a.info.mode, 'RGBA');
  assert.deepEqual(a.info.size, [1200, 900]);
  assert.ok(a.info.alpha.corner < 20, `背景應該透明：${a.info.alpha.corner}`);
  assert.ok(a.info.alpha.center > 235, `主體應該保留：${a.info.alpha.center}`);
  assert.equal(a.info.taken, '2024:05:01 10:20:30', '拍攝時間要保留');
  assert.equal(r['scan.pdf'].status, 'failed');
  assert.match(r['scan.pdf'].msg, /只支援照片/);

  const w = (await convert(['apple.jpg'], { mode: 'removebg', bgColor: '#ffffff', bgMaxSize: '512' })).results['apple.jpg'];
  assert.equal(w.status, 'done', w.msg);
  assert.equal(w.name, 'apple.jpg');
  assert.equal(w.info.format, 'JPEG');
  assert.deepEqual(w.info.size, [512, 384]);
  assert.ok(w.info.topLeft.every((c) => c > 240), `背景應該是白色：${w.info.topLeft}`);
  const [r0, g0, b0] = w.info.center;
  assert.ok(r0 > 150 && g0 < 90 && b0 < 90, `中間應該還是紅色蘋果：${w.info.center}`);
});

test('跨來源隔離（多執行緒）模式下，轉換、壓縮、PDF、預覽、ZIP 都正常', { timeout: 300_000 }, async () => {
  const context = await browser.newContext({ acceptDownloads: true });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e));
  await page.goto(baseUrl);
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload(); // 讓 service worker 接管頁面並補上隔離標頭
  assert.equal(await page.evaluate(() => crossOriginIsolated), true);

  const run = async (files, mode) => {
    await page.evaluate((m) => document.querySelector(`.mode button[data-value="${m}"]`).click(), mode);
    await page.setInputFiles('#fileInput', files.map((f) => path.join(FIX, f)));
    await page.click('#convertBtn');
    await page.waitForFunction(() => window.__app.items.every((i) => i.status === 'done' || i.status === 'failed'));
    return page.evaluate(() => window.__app.items.map((i) => `${i.file.name}:${i.status}`));
  };
  assert.deepEqual(await run(['photo.heic', 'clip.mov'], 'convert'), ['photo.heic:done', 'clip.mov:done']);
  await page.click('#clearBtn');
  await page.waitForFunction(() => window.__app.items.length === 0);
  assert.deepEqual(await run(['scan.pdf', 'noisy.jpg'], 'compress'), ['scan.pdf:done', 'noisy.jpg:done']);

  await page.locator('.file', { hasText: 'scan.pdf' }).locator('.name').click();
  await page.waitForFunction(() => document.querySelectorAll('.pv-page').length === 1, null, { timeout: 30_000 });
  await page.click('.pv-close');
  await page.waitForFunction(() => !document.querySelector('#preview').open);

  const [zip] = await Promise.all([page.waitForEvent('download'), page.click('#downloadAllBtn')]);
  assert.match(zip.suggestedFilename(), /\.zip$/);
  assert.deepEqual(errors, []);
  await context.close();
});

test('按「清除」後馬上加新檔案，新檔案不會被清掉', async () => {
  const page = await browser.newPage();
  await page.goto(baseUrl);
  await page.setInputFiles('#fileInput', [path.join(FIX, 'rotated.jpg')]);
  await page.click('#clearBtn');
  await page.setInputFiles('#fileInput', [path.join(FIX, 'photo.png')]);
  await page.waitForTimeout(500); // 等清除動畫結束
  assert.deepEqual(await page.evaluate(() => [...document.querySelectorAll('.file .name')].map((e) => e.textContent)), ['photo.png']);
  assert.equal(await page.isHidden('#listSection'), false);
  await page.close();
});
