import { convertImage, compressImage } from './image.js';
import { createPreview } from './preview.js';

const DEFAULTS = {
  mode: 'convert',
  bgColor: 'transparent',
  bgCustom: '#4f86f7',
  bgMaxSize: '',
  level: 'standard',
  targetSize: '',
  imageFormat: 'jpg',
  quality: 85,
  maxSize: '',
  videoFormat: 'mp4',
  resolution: '',
  videoQuality: 'high',
  gifStart: 0,
  gifDuration: 5,
  gifWidth: '480',
  gifFps: '12',
  metadata: 'keep',
};
const STORAGE_KEY = 'mediaconv-settings';

const IMAGE_EXT = /\.(jpe?g|jfif|png|webp|heic|heif|hif|avif|gif|bmp|tiff?)$/i;
const PDF_EXT = /\.pdf$/i;
const VIDEO_EXT = /\.(mp4|m4v|mov|qt|mkv|webm|3gp|3g2|ts|mts|m2ts|ogv|avi|wmv|flv)$/i;

const LEVEL_NOTES = {
  light: '照片最長邊 3000、影片 1080p、PDF 裡的圖片約 2400 像素。畫質幾乎看不出差別。',
  standard: '照片最長邊 2048、影片 720p、PDF 裡的圖片約 1600 像素。適合傳 LINE、寄 email。',
  strong: '照片最長邊 1280、影片 480p；PDF 每一頁轉成圖片（文字無法選取，適合掃描檔）。',
};

const ACCEPT_CONVERT = 'image/*,video/*,.heic,.heif,image/heic,image/heif,.mov,.mkv,.webm';
const ACCEPT_COMPRESS = `${ACCEPT_CONVERT},application/pdf,.pdf`;
const ACCEPT_REMOVEBG = 'image/*,.heic,.heif,image/heic,image/heif';
const MODES = {
  convert: { verb: '轉換', picker: '選擇要轉換的照片或影片', accept: ACCEPT_CONVERT, title: '轉檔工具', zip: '轉檔結果' },
  compress: { verb: '壓縮', picker: '選擇要壓縮的照片、影片或 PDF', accept: ACCEPT_COMPRESS, title: '壓縮檔案 · 轉檔工具', zip: '壓縮結果' },
  removebg: { verb: '去背', picker: '選擇要去背的照片', accept: ACCEPT_REMOVEBG, title: '去背 · 轉檔工具', zip: '去背結果' },
};
const BG_LABELS = { transparent: '透明背景', '#ffffff': '白色背景', '#000000': '黑色背景', custom: '自訂背景' };
const BG_NOTES = {
  transparent: '輸出透明背景的 PNG，可以直接貼到其他圖片或簡報上。',
  '#ffffff': '輸出白色背景的 JPG，適合證件照、商品照。',
  '#000000': '輸出黑色背景的 JPG。',
  custom: '輸出自訂顏色背景的 JPG。',
};
const modeInfo = () => MODES[settings.mode] || MODES.convert;

const METADATA_NOTES = {
  keep: '保留拍攝時間、相機型號、GPS 位置等資訊，存回相簿時會依拍攝時間排列。',
  nogps: '移除 GPS 位置，保留拍攝時間等其他資訊。分享給別人時建議用這個。',
  none: '移除所有拍攝資訊（時間、相機、位置）。',
};

const FORMAT_LABELS = { jpg: 'JPG', png: 'PNG', webp: 'WebP', mp4: 'MP4', mov: 'MOV', webm: 'WebM', gif: 'GIF' };
const LEVEL_LABELS = { light: '輕度', standard: '標準', strong: '強力' };
const METADATA_LABELS = { keep: '保留拍攝資訊', nogps: '移除位置', none: '移除拍攝資訊' };
const KIND_ICONS = { image: 'i-photo', video: 'i-video', pdf: 'i-pdf' };

const $ = (sel) => document.querySelector(sel);
const reduceMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
const isReady = () => document.documentElement.classList.contains('ready');

/**
 * 滾動數字：每個數字像計數器一樣轉到新的值（非數字的字元直接換掉）。
 * 螢幕閱讀器讀 aria-label，不會唸出 0–9 的捲軸。
 */
function roll(el, value) {
  const str = String(value);
  const isDigit = (c) => c >= '0' && c <= '9';
  el.setAttribute('aria-label', str);
  const same = el._s && el._s.length === str.length && [...str].every((c, i) => isDigit(c) === isDigit(el._s[i]));
  if (same) {
    [...str].forEach((c, i) => {
      const node = el.children[i];
      if (isDigit(c)) node.firstChild.style.transform = `translateY(${-c * 10}%)`;
      else node.textContent = c === ' ' ? '\u00a0' : c;
    });
  } else {
    const prev = el._s || '';
    el.innerHTML = [...str]
      .map((c, i) =>
        isDigit(c)
          ? `<span class="dg" aria-hidden="true"><span class="st" style="transition-delay:${(str.length - 1 - i) * 45}ms;transform:translateY(${isDigit(prev[i] || '') ? -prev[i] * 10 : 0}%)">${'0123456789'.split('').map((d) => `<i>${d}</i>`).join('')}</span></span>`
          : `<span aria-hidden="true">${c === ' ' ? '&nbsp;' : c}</span>`,
      )
      .join('');
    void el.offsetWidth;
    [...str].forEach((c, i) => {
      if (isDigit(c)) el.children[i].firstChild.style.transform = `translateY(${-c * 10}%)`;
    });
  }
  el._s = str;
}

/** 從上方彈出的通知，新的在最上面、舊的往後疊。 */
function toast(title, sub = '', { error = false, iconId } = {}) {
  const box = $('#toasts');
  const t = document.createElement('div');
  t.className = `toast new${error ? ' err' : ''}`;
  t.setAttribute('role', error ? 'alert' : 'status');
  t.innerHTML = `<i>${icon(iconId || (error ? 'i-alert' : 'i-check'))}</i><div></div>`;
  const text = t.querySelector('div');
  text.textContent = title;
  if (sub) text.append(Object.assign(document.createElement('small'), { textContent: sub }));
  [...box.children].forEach((x) => {
    const k = Number(x.style.getPropertyValue('--k') || 0) + 1;
    x.style.setProperty('--k', k);
    if (k > 2) {
      x.classList.add('bye');
      setTimeout(() => x.remove(), 400);
    }
  });
  box.prepend(t);
  void t.offsetWidth;
  t.classList.remove('new');
  setTimeout(() => {
    t.classList.add('bye');
    setTimeout(() => t.remove(), 400);
  }, error ? 6000 : 3200);
}

/** 重新觸發元素上的 CSS 動畫 class。 */
function replay(el, cls) {
  el.classList.remove(cls);
  void el.offsetWidth; // 讓瀏覽器重新計算，動畫才會重播
  el.classList.add(cls);
}

function icon(id, cls = '') {
  return `<svg class="${cls}" aria-hidden="true"><use href="#${id}"/></svg>`;
}
const settings = loadSettings();
const items = [];
let busy = false;

// 給自動化測試用
window.__app = { items, settings };

// ---------- 設定 ----------

function loadSettings() {
  try {
    return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}') };
  } catch {
    return { ...DEFAULTS };
  }
}

function saveSettings() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
  } catch {
    /* 私密瀏覽等情況下無法儲存，沒關係 */
  }
}

function bindSettings() {
  for (const group of document.querySelectorAll('.seg[data-setting]')) {
    const key = group.dataset.setting;
    for (const btn of group.querySelectorAll('button')) {
      btn.setAttribute('role', 'radio');
      btn.addEventListener('click', () => {
        settings[key] = btn.dataset.value;
        saveSettings();
        render();
      });
    }
  }
  for (const el of document.querySelectorAll('input[data-setting], select[data-setting]')) {
    const key = el.dataset.setting;
    el.value = settings[key];
    el.addEventListener('input', () => {
      settings[key] = el.type === 'range' || el.type === 'number' ? Number(el.value) : el.value;
      saveSettings();
      render();
    });
  }
}

let lastMode = null;

function render() {
  for (const group of document.querySelectorAll('.seg[data-setting]')) {
    const value = settings[group.dataset.setting];
    const buttons = [...group.querySelectorAll('button')];
    buttons.forEach((btn) => btn.setAttribute('aria-checked', String(btn.dataset.value === value)));
    // 滑動的選取底色：告訴 CSS 有幾個選項、選到第幾個
    group.style.setProperty('--n', buttons.length);
    group.style.setProperty('--i', Math.max(0, buttons.findIndex((b) => b.dataset.value === value)));
  }
  roll($('#qualityOut'), settings.quality);
  for (const range of document.querySelectorAll('input[type="range"]')) {
    const v = ((range.value - range.min) / (range.max - range.min)) * 100;
    range.style.setProperty('--v', `${v}%`);
  }
  $('#qualityRow').hidden = settings.imageFormat === 'png';
  const isGif = settings.videoFormat === 'gif';
  for (const el of document.querySelectorAll('.gif-only')) el.hidden = !isGif;
  for (const el of document.querySelectorAll('.video-only')) el.hidden = isGif;
  $('#metadataNote').textContent = METADATA_NOTES[settings.metadata];
  if (!MODES[settings.mode]) settings.mode = 'convert';
  const modeChanged = lastMode !== null && lastMode !== settings.mode;
  lastMode = settings.mode;
  for (const el of document.querySelectorAll('.convert-only, .compress-only, .removebg-only')) {
    // 有標記哪些模式要顯示的區塊，只在那些模式出現
    const show = el.classList.contains(`${settings.mode}-only`);
    el.hidden = !show;
    // 切換模式時，新出現的區塊淡入
    if (show && modeChanged) replay(el, 'enter');
  }
  $('#levelNote').textContent = LEVEL_NOTES[settings.level];
  $('#pickerText').textContent = modeInfo().picker;
  $('#bgCustomRow').hidden = settings.bgColor !== 'custom';
  $('#bgNote').textContent = BG_NOTES[settings.bgColor] || '';
  renderChips();
  $('#fileInput').accept = modeInfo().accept;
  document.title = modeInfo().title;
  updateButtons();
}

/** 設定區摺起來時，用小標籤顯示目前的設定。 */
function renderChips() {
  const chips = [];
  if (settings.mode === 'removebg') {
    chips.push(BG_LABELS[settings.bgColor] || '透明背景');
    if (settings.bgMaxSize) chips.push(`最長邊 ${settings.bgMaxSize}`);
  } else if (settings.mode === 'compress') {
    chips.push(LEVEL_LABELS[settings.level]);
    if (settings.targetSize) chips.push(`上限 ${formatBytes(Number(settings.targetSize))}`);
  } else {
    chips.push(`照片 → ${FORMAT_LABELS[settings.imageFormat]}`);
    if (settings.imageFormat !== 'png') chips.push(`品質 ${settings.quality}`);
    if (settings.maxSize) chips.push(`最長邊 ${settings.maxSize}`);
    chips.push(`影片 → ${FORMAT_LABELS[settings.videoFormat]}`);
    if (settings.videoFormat !== 'gif' && settings.resolution) chips.push(settings.resolution);
  }
  chips.push(METADATA_LABELS[settings.metadata]);
  const box = $('#settingsChips');
  const key = chips.join('|');
  if (box.dataset.key === key) return;
  box.dataset.key = key;
  box.replaceChildren(
    ...chips.map((text) => Object.assign(document.createElement('span'), { className: 'chip', textContent: text })),
  );
  if (isReady()) replay(box, 'changed');
}

// ---------- 檔案清單 ----------

function kindOf(file) {
  if (file.type === 'application/pdf' || PDF_EXT.test(file.name)) return 'pdf';
  if (file.type.startsWith('image/') || IMAGE_EXT.test(file.name)) return 'image';
  if (file.type.startsWith('video/') || VIDEO_EXT.test(file.name)) return 'video';
  return null;
}

function formatBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

function addFiles(fileList) {
  let order = 0;
  for (const file of fileList) {
    const kind = kindOf(file);
    const li = $('#itemTemplate').content.firstElementChild.cloneNode(true);
    const item = { file, kind, status: 'queued', el: li, result: null };
    li.style.setProperty('--d', Math.min(order++, 10)); // 依序進場
    li.querySelector('.name').textContent = file.name;
    const label = { video: '影片', image: '照片', pdf: 'PDF' }[kind] || '不支援';
    li.querySelector('.meta').textContent = `${label} · ${formatBytes(file.size)}`;
    const thumb = li.querySelector('.thumb');
    thumb.dataset.kind = kind || 'unknown';
    thumb.insertAdjacentHTML('afterbegin', icon(KIND_ICONS[kind] || 'i-x', 'kind-icon'));
    thumb.classList.toggle('no-img', kind !== 'image');
    if (kind === 'image') {
      // 縮圖蓋在圖示上面；瀏覽器讀不了的格式（例如電腦上的 HEIC）就留下圖示
      item.thumbUrl = URL.createObjectURL(file);
      const img = Object.assign(document.createElement('img'), { src: item.thumbUrl, alt: '', decoding: 'async' });
      img.addEventListener('error', () => {
        img.remove();
        thumb.classList.add('no-img');
      });
      thumb.prepend(img);
      thumb.append(thumb.querySelector('.badge'));
    }
    if (!kind) setStatus(item, 'failed', '不是照片、影片或 PDF', 'err');
    li.querySelector('.remove').addEventListener('click', () => removeItem(item));
    // 完成後點擊檔案（按鈕以外的地方）就預覽
    li.addEventListener('click', (e) => {
      if (item.status === 'done' && !e.target.closest('button, a')) preview.open(item);
    });
    li.addEventListener('keydown', (e) => {
      if (item.status === 'done' && (e.key === 'Enter' || e.key === ' ') && e.target === li) {
        e.preventDefault();
        preview.open(item);
      }
    });
    items.push(item);
    $('#fileList').append(li);
  }
  $('#listSection').hidden = items.length === 0;
  $('#count').textContent = items.length ? `(${items.length})` : '';
  $('#summary').hidden = true;
  updateButtons();
  if (items.length) $('#listSection').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function refreshList() {
  $('#listSection').hidden = items.length === 0;
  $('#count').textContent = items.length ? `(${items.length})` : '';
  $('#summary').hidden = true; // 清單變了，舊的統計就不準了
  updateButtons();
}

function releaseItem(item) {
  if (item.thumbUrl) URL.revokeObjectURL(item.thumbUrl);
  if (item.result?.url) URL.revokeObjectURL(item.result.url);
  if (item.result) usedNames.delete(item.result.file.name.toLowerCase());
}

/** 移除單一檔案（選錯檔案時用）。 */
async function removeItem(item) {
  if (busy || !items.includes(item)) return;
  items.splice(items.indexOf(item), 1);
  refreshList();
  if (!reduceMotion()) {
    item.el.classList.add('leaving');
    await new Promise((r) => setTimeout(r, 250));
  }
  item.el.remove();
  releaseItem(item);
}

async function clearFiles() {
  if (busy) return;
  const old = items.splice(0);
  updateButtons();
  if (!reduceMotion()) {
    old.forEach((item) => item.el.classList.add('leaving'));
    await new Promise((r) => setTimeout(r, 250));
  }
  // 只移除舊的項目：動畫期間如果又加了新檔案，新檔案要留著
  old.forEach((item) => {
    item.el.remove();
    releaseItem(item);
  });
  refreshList();
}

function setStatus(item, status, message = '', tone = '') {
  item.status = status;
  item.el.classList.toggle('done', status === 'done');
  item.el.classList.toggle('failed', status === 'failed');
  item.el.classList.toggle('working', status === 'working');
  const badge = item.el.querySelector('.badge');
  badge.innerHTML = status === 'done' ? icon('i-check') : status === 'failed' ? icon('i-x') : '';
  const msg = item.el.querySelector('.msg');
  msg.textContent = message;
  msg.className = `msg ${tone}`;
}

function setProgress(item, fraction) {
  const pct = Math.round(fraction * 100);
  item.el.querySelector('.bar span').style.width = `${pct}%`;
  roll(item.el.querySelector('.pct'), `${pct}%`);
}

function updateButtons() {
  const pending = items.some((i) => i.status === 'queued');
  const done = items.filter((i) => i.status === 'done');
  const btn = $('#convertBtn');
  const wasDisabled = btn.disabled;
  btn.disabled = busy || finishing || !pending;
  btn.classList.toggle('load', busy);
  // 有檔案可以處理時，按鈕輕輕彈一下提示
  if (wasDisabled && !btn.disabled && isReady()) replay(btn, 'nudge');
  const verb = modeInfo().verb;
  const pendingCount = items.filter((i) => i.status === 'queued').length;
  btn.querySelector('.btn-label').textContent = pendingCount > 1 ? `開始${verb}（${pendingCount} 個）` : `開始${verb}`;
  btn.querySelector('.busy-label').textContent = `${verb}中`;
  btn.hidden = !busy && !finishing && !pending && done.length > 0;
  const finished = !busy && !finishing && !pending && done.length > 0;
  $('#saveAllBtn').hidden = !finished || !canShare(done.map((i) => i.result.file));
  const dl = $('#downloadAllBtn');
  dl.hidden = !finished;
  if (!zipping) dl.querySelector('span').textContent = done.length > 1 ? '全部下載' : '下載';
  $('#clearBtn').disabled = busy;
  document.body.classList.toggle('is-busy', busy);
}

// ---------- 轉換 ----------

const usedNames = new Set();
function outputName(file, ext) {
  const stem = file.name.replace(/\.[^.]+$/, '') || 'file';
  let name = `${stem}${ext}`;
  for (let n = 2; usedNames.has(name.toLowerCase()); n++) name = `${stem}_${n}${ext}`;
  usedNames.add(name.toLowerCase());
  return name;
}

let videoModule;
async function loadVideoModule() {
  videoModule ??= await import('./video.js');
  return videoModule;
}

let pdfModule;
async function loadPdfModule() {
  pdfModule ??= await import('./pdf.js');
  return pdfModule;
}

async function compressItem(item, onProgress) {
  const opts = {
    level: settings.level,
    targetSize: Number(settings.targetSize) || null,
    metadata: settings.metadata,
  };
  if (item.kind === 'image') return compressImage(item.file, opts);
  if (item.kind === 'pdf') return (await loadPdfModule()).compressPdf(item.file, opts, onProgress);
  const video = await loadVideoModule();
  if (!video.supportsVideo()) {
    throw new Error('這個瀏覽器不支援影片處理，請更新 iOS 或改用新版 Safari / Chrome');
  }
  return video.compressVideo(item.file, opts, onProgress);
}

let bgModule;

async function removeBgItem(item) {
  if (item.kind !== 'image') throw new Error('去背只支援照片');
  bgModule ??= await import('./bgremove.js');
  const background = settings.bgColor === 'custom' ? settings.bgCustom : settings.bgColor;
  return bgModule.removeBackground(item.file, {
    background,
    maxSize: Number(settings.bgMaxSize) || null,
    metadata: settings.metadata,
  }, (stage, p) => {
    if (stage === 'download') {
      item.el.querySelector('.msg').textContent = `下載 AI 模型 ${Math.round(p * 100)}%（只有第一次需要）`;
      setProgress(item, Math.max(0.02, p * 0.5));
    } else {
      item.el.querySelector('.msg').textContent = '去背中…';
      setProgress(item, 0.5 + p * 0.5);
    }
  });
}

async function convertItem(item) {
  const compressing = settings.mode === 'compress';
  setStatus(item, 'working', `${modeInfo().verb}中…`);
  setProgress(item, 0.02);
  const onProgress = (p) => setProgress(item, Math.max(0.02, p));
  let result;
  if (settings.mode === 'removebg') {
    result = await removeBgItem(item);
  } else if (compressing) {
    result = await compressItem(item, onProgress);
    if (result.blob.size >= item.file.size) {
      // 壓縮後沒有比較小：保留原檔
      const ext = item.file.name.match(/\.[^.]+$/)?.[0] || '';
      result = { blob: item.file, ext, warnings: [], kept: true };
    }
  } else if (item.kind === 'pdf') {
    throw new Error('PDF 請切換到「壓縮檔案」模式');
  } else if (item.kind === 'image') {
    result = await convertImage(item.file, {
      format: settings.imageFormat,
      quality: settings.quality,
      maxSize: Number(settings.maxSize) || null,
      metadata: settings.metadata,
    });
  } else {
    const video = await loadVideoModule();
    if (!video.supportsVideo()) {
      throw new Error('這個瀏覽器不支援影片轉檔，請更新 iOS 或改用新版 Safari / Chrome');
    }
    const isGif = settings.videoFormat === 'gif';
    result = await video.convertVideo(
      item.file,
      {
        format: settings.videoFormat,
        resolution: settings.resolution || null,
        quality: settings.videoQuality,
        metadata: settings.metadata,
        ...(isGif
          ? {
              start: Number(settings.gifStart) || 0,
              duration: Number(settings.gifDuration) || 5,
              gifWidth: Number(settings.gifWidth),
              gifFps: Number(settings.gifFps),
            }
          : {}),
      },
      onProgress,
    );
  }
  const name = outputName(item.file, result.ext);
  const file = new File([result.blob], name, { type: result.blob.type, lastModified: item.file.lastModified });
  item.result = { file, url: URL.createObjectURL(file), warnings: result.warnings };
  setProgress(item, 1);

  const diff = item.file.size ? Math.round((1 - file.size / item.file.size) * 100) : 0;
  // 去背的透明 PNG 本來就比原本的 JPG 大，比較大小沒有意義
  const change = settings.mode === 'removebg' ? '' : diff > 0 ? `，小了 ${diff}%` : diff < 0 ? `，大了 ${-diff}%` : '';
  const text = result.kept
    ? `原檔已經很小，保留原檔：${name}`
    : `完成：${name} · ${formatBytes(file.size)}${change}`;
  const warn = result.warnings.length ? `\n${result.warnings.join('；')}` : '';
  setStatus(item, 'done', text + warn, result.warnings.length ? 'warn' : 'ok');
  item.el.tabIndex = 0;
  if (settings.mode === 'removebg') showResultThumb(item);
  item.el.setAttribute('aria-label', `${name}，點擊預覽`);
  addItemActions(item);
}

/** 去背後縮圖改顯示結果（透明的地方用格子底表示）。 */
function showResultThumb(item) {
  const thumb = item.el.querySelector('.thumb');
  thumb.classList.add('checker');
  let img = thumb.querySelector('img');
  if (!img) {
    img = Object.assign(document.createElement('img'), { alt: '', decoding: 'async' });
    thumb.prepend(img);
  }
  img.src = item.result.url;
}

function addItemActions(item) {
  const box = item.el.querySelector('.item-actions');
  box.replaceChildren();
  const { file, url } = item.result;
  if (canShare([file])) {
    const share = document.createElement('button');
    share.className = 'small';
    share.textContent = '儲存';
    share.addEventListener('click', () => shareFiles([file]));
    box.append(share);
  }
  const a = document.createElement('a');
  a.className = 'small';
  a.href = url;
  a.download = file.name;
  a.textContent = '下載';
  box.append(a);
}

function canShare(files) {
  try {
    return !!navigator.canShare && navigator.canShare({ files });
  } catch {
    return false;
  }
}

async function shareFiles(files) {
  try {
    await navigator.share({ files });
  } catch (err) {
    if (err.name !== 'AbortError') toast('無法分享', err.message, { error: true });
  }
}

async function saveAll() {
  const done = items.filter((i) => i.status === 'done').map((i) => i.result.file);
  if (done.length && canShare(done)) await shareFiles(done);
}

function triggerDownload(url, name) {
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
}

let zipping = false;
let finishing = false; // 按鈕正在顯示「完成」

/** 全部下載：一個檔案就直接下載，多個檔案打包成一個 ZIP（iPhone 一次只能可靠地下載一個檔案）。 */
async function downloadAll() {
  const done = items.filter((i) => i.status === 'done');
  if (!done.length || zipping) return;
  if (done.length === 1) {
    triggerDownload(done[0].result.url, done[0].result.file.name);
    toast('已開始下載', done[0].result.file.name, { iconId: 'i-download' });
    return;
  }
  const btn = $('#downloadAllBtn');
  const label = btn.querySelector('span');
  zipping = true;
  btn.disabled = true;
  try {
    const { makeZip } = await import('./zip.js');
    const zip = await makeZip(done.map((i) => i.result.file), (p) => {
      label.textContent = `打包中 ${Math.round(p * 100)}%`;
    });
    const d = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`;
    const name = `${modeInfo().zip}-${stamp}.zip`;
    const url = URL.createObjectURL(zip);
    triggerDownload(url, name);
    toast('已開始下載', `${name} · ${formatBytes(zip.size)}`, { iconId: 'i-download' });
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  } catch (err) {
    toast('無法打包下載', String(err.message || err), { error: true });
  } finally {
    zipping = false;
    btn.disabled = false;
    updateButtons();
  }
}

async function convertAll() {
  if (busy) return;
  busy = true;
  updateButtons();
  let wakeLock = null;
  try {
    wakeLock = await navigator.wakeLock?.request('screen'); // 轉換時不要讓螢幕關掉
  } catch {
    /* 不支援就算了 */
  }
  for (const item of items) {
    if (item.status !== 'queued') continue;
    try {
      await convertItem(item);
    } catch (err) {
      console.error(err);
      setStatus(item, 'failed', `失敗：${err.message || err}`, 'err');
    }
  }
  wakeLock?.release?.().catch(() => {});
  busy = false;
  const ok = items.some((i) => i.status === 'done');
  if (ok && !reduceMotion()) {
    // 按鈕先翻成綠色的「完成」，再換成儲存／下載
    finishing = true;
    const btn = $('#convertBtn');
    btn.classList.remove('load');
    btn.classList.add('done');
    setTimeout(() => {
      finishing = false;
      btn.classList.remove('done');
      updateButtons();
    }, 1300);
  }
  updateButtons();

  const doneItems = items.filter((i) => i.status === 'done');
  const failed = items.filter((i) => i.status === 'failed').length;
  const summary = $('#summary');
  summary.hidden = false;
  const status = `成功 ${doneItems.length} 個${failed ? `，失敗 ${failed} 個` : ''}`;
  const before = doneItems.reduce((n, i) => n + i.file.size, 0);
  const after = doneItems.reduce((n, i) => n + i.result.file.size, 0);
  const saved = before - after;
  const pct = before ? Math.round((saved / before) * 100) : 0;
  summary.replaceChildren();
  summary.classList.toggle('has-failed', failed > 0);
  replay(summary, 'pop');
  const verb = modeInfo().verb;
  if (settings.mode === 'compress' && doneItems.length) {
    summary.innerHTML = `
      <div class="ring" aria-hidden="true">
        <svg viewBox="0 0 120 120"><circle cx="60" cy="60" r="52"/><circle class="v" cx="60" cy="60" r="52"/></svg>
        <div><strong><span class="roll ring-pct"></span><sup>%</sup></strong><small>省下</small></div>
      </div>
      <div class="sum-text">
        <div class="sum-label">壓縮完成</div>
        <div class="sum-big"></div>
        <div class="sum-line"></div>
        <div class="sum-status"></div>
      </div>`;
    const big = summary.querySelector('.sum-big');
    if (saved > 0) {
      big.innerHTML = '省下 <span class="roll"></span>';
      roll(big.querySelector('.roll'), formatBytes(saved));
    } else {
      big.textContent = '已經很小了';
    }
    summary.querySelector('.sum-line').textContent = `總大小 ${formatBytes(before)} → ${formatBytes(after)}`;
    roll(summary.querySelector('.ring-pct'), Math.max(0, pct));
    // 圓環從 0 長到省下的比例
    const arc = summary.querySelector('.ring .v');
    requestAnimationFrame(() => requestAnimationFrame(() => {
      arc.style.strokeDashoffset = 326.7 * (1 - Math.max(0, pct) / 100);
    }));
  } else {
    const allFailed = failed && !doneItems.length;
    summary.innerHTML = `
      <div class="done-ic" aria-hidden="true">${icon(allFailed ? 'i-alert' : 'i-check')}</div>
      <div class="sum-text">
        <div class="sum-label">${verb}${allFailed ? '失敗' : '完成'}</div>
        <div class="sum-big">${allFailed ? '沒有成功的檔案' : '完成！'}</div>
        <div class="sum-status"></div>
      </div>`;
  }
  summary.querySelector('.sum-status').textContent = status;
  summary.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

// ---------- 初始化 ----------

let preview;

function init() {
  preview = createPreview({
    getItems: () => items,
    formatBytes,
    canShare,
    shareFiles,
    triggerDownload,
    reduceMotion,
  });
  bindSettings();
  render();
  // 第一次畫面出來之後才開啟過場動畫，避免一打開就看到元件滑來滑去
  requestAnimationFrame(() => requestAnimationFrame(() => document.documentElement.classList.add('ready')));

  $('#fileInput').addEventListener('change', (e) => {
    addFiles(e.target.files);
    e.target.value = '';
  });
  $('#convertBtn').addEventListener('click', convertAll);
  $('#settingsToggle').addEventListener('click', () => {
    const open = $('#settingsPanel').classList.toggle('open');
    $('#settingsToggle').setAttribute('aria-expanded', String(open));
  });
  $('#saveAllBtn').addEventListener('click', saveAll);
  $('#downloadAllBtn').addEventListener('click', downloadAll);
  $('#clearBtn').addEventListener('click', clearFiles);

  // 電腦上可以直接把檔案拖進來
  const picker = $('#picker');
  for (const type of ['dragenter', 'dragover']) {
    document.addEventListener(type, (e) => {
      e.preventDefault();
      picker.classList.add('drag');
    });
  }
  for (const type of ['dragleave', 'drop']) {
    document.addEventListener(type, () => picker.classList.remove('drag'));
  }
  document.addEventListener('drop', (e) => {
    e.preventDefault();
    if (e.dataTransfer?.files?.length) addFiles(e.dataTransfer.files);
  });

  window.addEventListener('beforeunload', (e) => {
    if (busy) e.preventDefault();
  });

  if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
    navigator.serviceWorker.register('sw.js').catch((err) => console.warn('Service worker 註冊失敗', err));
  }
}

init();
