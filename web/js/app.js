import { convertImage, compressImage } from './image.js';

const DEFAULTS = {
  mode: 'convert',
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

// 預覽不同風格用：網址加上 ?style=soft 或 ?style=pro
const styleParam = new URLSearchParams(location.search).get('style');
if (styleParam) document.documentElement.dataset.style = styleParam;

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

function render() {
  for (const group of document.querySelectorAll('.seg[data-setting]')) {
    const value = settings[group.dataset.setting];
    for (const btn of group.querySelectorAll('button')) {
      btn.setAttribute('aria-checked', String(btn.dataset.value === value));
    }
  }
  $('#qualityOut').textContent = settings.quality;
  $('#qualityRow').hidden = settings.imageFormat === 'png';
  const isGif = settings.videoFormat === 'gif';
  for (const el of document.querySelectorAll('.gif-only')) el.hidden = !isGif;
  for (const el of document.querySelectorAll('.video-only')) el.hidden = isGif;
  $('#metadataNote').textContent = METADATA_NOTES[settings.metadata];
  const compressing = settings.mode === 'compress';
  for (const el of document.querySelectorAll('.convert-only')) el.hidden = compressing;
  for (const el of document.querySelectorAll('.compress-only')) el.hidden = !compressing;
  $('#levelNote').textContent = LEVEL_NOTES[settings.level];
  $('#pickerText').textContent = compressing ? '選擇要壓縮的照片、影片或 PDF' : '選擇要轉換的照片或影片';
  renderChips();
  $('#fileInput').accept = compressing ? ACCEPT_COMPRESS : ACCEPT_CONVERT;
  document.title = compressing ? '壓縮檔案 · 轉檔工具' : '轉檔工具';
  updateButtons();
}

/** 設定區摺起來時，用小標籤顯示目前的設定。 */
function renderChips() {
  const chips = [];
  if (settings.mode === 'compress') {
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
  $('#settingsChips').replaceChildren(
    ...chips.map((text) => Object.assign(document.createElement('span'), { className: 'chip', textContent: text })),
  );
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
  for (const file of fileList) {
    const kind = kindOf(file);
    const li = $('#itemTemplate').content.firstElementChild.cloneNode(true);
    const item = { file, kind, status: 'queued', el: li, result: null };
    li.querySelector('.name').textContent = file.name;
    const label = { video: '影片', image: '照片', pdf: 'PDF' }[kind] || '不支援';
    li.querySelector('.meta').textContent = `${label} · ${formatBytes(file.size)}`;
    const thumb = li.querySelector('.thumb');
    thumb.dataset.kind = kind || 'unknown';
    thumb.insertAdjacentHTML('afterbegin', icon(KIND_ICONS[kind] || 'i-x', 'kind-icon'));
    if (kind === 'image') {
      // 縮圖蓋在圖示上面；瀏覽器讀不了的格式（例如電腦上的 HEIC）就留下圖示
      item.thumbUrl = URL.createObjectURL(file);
      const img = Object.assign(document.createElement('img'), { src: item.thumbUrl, alt: '', decoding: 'async' });
      img.addEventListener('error', () => img.remove());
      thumb.prepend(img);
      thumb.append(thumb.querySelector('.badge'));
    }
    if (!kind) setStatus(item, 'failed', '不是照片、影片或 PDF', 'err');
    items.push(item);
    $('#fileList').append(li);
  }
  $('#listSection').hidden = items.length === 0;
  $('#count').textContent = items.length ? `(${items.length})` : '';
  $('#summary').hidden = true;
  updateButtons();
  if (items.length) $('#listSection').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function clearFiles() {
  if (busy) return;
  for (const item of items) {
    if (item.thumbUrl) URL.revokeObjectURL(item.thumbUrl);
    if (item.result?.url) URL.revokeObjectURL(item.result.url);
  }
  items.length = 0;
  $('#fileList').replaceChildren();
  $('#listSection').hidden = true;
  $('#summary').hidden = true;
  updateButtons();
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
  item.el.querySelector('.bar span').style.width = `${Math.round(fraction * 100)}%`;
}

function updateButtons() {
  const pending = items.some((i) => i.status === 'queued');
  const done = items.filter((i) => i.status === 'done');
  $('#convertBtn').disabled = busy || !pending;
  const verb = settings.mode === 'compress' ? '壓縮' : '轉換';
  const pendingCount = items.filter((i) => i.status === 'queued').length;
  $('#convertBtn').textContent = busy ? `${verb}中…` : pendingCount > 1 ? `開始${verb}（${pendingCount} 個）` : `開始${verb}`;
  $('#convertBtn').hidden = !busy && !pending && done.length > 0;
  $('#saveAllBtn').hidden = busy || pending || done.length === 0;
  $('#clearBtn').disabled = busy;
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

async function convertItem(item) {
  const compressing = settings.mode === 'compress';
  setStatus(item, 'working', compressing ? '壓縮中…' : '轉換中…');
  setProgress(item, 0.02);
  const onProgress = (p) => setProgress(item, Math.max(0.02, p));
  let result;
  if (compressing) {
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
  const change = diff > 0 ? `，小了 ${diff}%` : diff < 0 ? `，大了 ${-diff}%` : '';
  const text = result.kept
    ? `原檔已經很小，保留原檔：${name}`
    : `完成：${name} · ${formatBytes(file.size)}${change}`;
  const warn = result.warnings.length ? `\n${result.warnings.join('；')}` : '';
  setStatus(item, 'done', text + warn, result.warnings.length ? 'warn' : 'ok');
  addItemActions(item);
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
    if (err.name !== 'AbortError') alert(`無法分享：${err.message}`);
  }
}

async function saveAll() {
  const done = items.filter((i) => i.status === 'done').map((i) => i.result.file);
  if (!done.length) return;
  if (canShare(done)) return shareFiles(done);
  // 不能分享的環境（例如電腦），逐一下載
  for (const item of items.filter((i) => i.status === 'done')) {
    const a = document.createElement('a');
    a.href = item.result.url;
    a.download = item.result.file.name;
    document.body.append(a);
    a.click();
    a.remove();
    await new Promise((r) => setTimeout(r, 300));
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
  if (settings.mode === 'compress' && doneItems.length) {
    summary.innerHTML = `
      <div class="sum-big">${saved > 0 ? `省下 <b>${formatBytes(saved)}</b>` : '沒有可以再壓縮的空間'}</div>
      <div class="sum-meter"><span style="width:${Math.max(2, 100 - pct)}%"></span></div>
      <div class="sum-line"></div>
      <div class="sum-status"></div>`;
    summary.querySelector('.sum-line').textContent = `總大小 ${formatBytes(before)} → ${formatBytes(after)}（小了 ${pct}%）`;
  } else {
    summary.innerHTML = `<div class="sum-big">${failed && !doneItems.length ? '沒有成功的檔案' : '完成！'}</div><div class="sum-status"></div>`;
  }
  summary.querySelector('.sum-status').textContent = status;
  summary.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

// ---------- 初始化 ----------

function init() {
  bindSettings();
  render();

  $('#fileInput').addEventListener('change', (e) => {
    addFiles(e.target.files);
    e.target.value = '';
  });
  $('#convertBtn').addEventListener('click', convertAll);
  $('#saveAllBtn').addEventListener('click', saveAll);
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
