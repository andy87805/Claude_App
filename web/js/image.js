// 照片轉換與壓縮：瀏覽器解碼 -> canvas 縮放 -> 編碼成 JPG/PNG/WebP，再把 EXIF 放回去。

import { extractExif, patchExif, insertExifJpeg, insertExifPng, insertExifWebp } from './exif.js';

export const IMAGE_FORMATS = {
  jpg: { mime: 'image/jpeg', ext: '.jpg' },
  png: { mime: 'image/png', ext: '.png' },
  webp: { mime: 'image/webp', ext: '.webp' },
};

// 壓縮程度：[最長邊, JPG 品質]
export const COMPRESS_PRESETS = {
  light: [3000, 80],
  standard: [2048, 75],
  strong: [1280, 65],
};

// iPhone Safari 的 canvas 面積上限（約 1600 萬像素）
export const IOS_MAX_CANVAS_AREA = 4096 * 4096;

function isHeicLike(file, bytes) {
  if (/\.(heic|heif|hif)$/i.test(file.name) || /hei[cf]/i.test(file.type)) return true;
  const brand = String.fromCharCode(...bytes.subarray(8, 12));
  return /^(heic|heix|hevc|hevx|heim|heis|mif1|msf1)$/.test(brand);
}

async function decodeWithBrowser(blob) {
  if ('createImageBitmap' in window) {
    try {
      return await createImageBitmap(blob, { imageOrientation: 'from-image' });
    } catch {
      /* 改用 <img> 再試一次 */
    }
  }
  const url = URL.createObjectURL(blob);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return img;
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** 讀取照片：回傳原始位元組、可繪製的影像與尺寸。 */
export async function openImage(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  let source;
  try {
    source = await decodeWithBrowser(file);
  } catch {
    // 非 Safari 的瀏覽器多半不能直接讀 HEIC，改用內附的 libheif 解碼
    if (!isHeicLike(file, bytes)) {
      throw new Error('無法讀取這張照片（檔案可能損壞，或是瀏覽器不支援這種格式）');
    }
    const { heicTo } = await import('../vendor/heic-to.js');
    source = await heicTo({ blob: file, type: 'bitmap' });
  }
  const width = source.naturalWidth || source.width;
  const height = source.naturalHeight || source.height;
  if (!width || !height) throw new Error('無法讀取照片尺寸');
  return { bytes, source, width, height };
}

export function closeImage(img) {
  img.source.close?.();
}

export function fitSize(width, height, maxSize, maxArea) {
  let scale = 1;
  if (maxSize && Math.max(width, height) > maxSize) scale = maxSize / Math.max(width, height);
  if (maxArea && width * height * scale * scale > maxArea) scale = Math.sqrt(maxArea / (width * height));
  return {
    width: Math.max(1, Math.floor(width * scale)),
    height: Math.max(1, Math.floor(height * scale)),
  };
}

export function canvasToBlob(canvas, mime, quality) {
  return new Promise((resolve) => canvas.toBlob(resolve, mime, quality));
}

function draw(source, width, height, flatten) {
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d');
  if (!ctx) return null; // 超過瀏覽器 canvas 上限
  if (flatten) {
    // JPG 不支援透明，先鋪白底
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, width, height);
  }
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(source, 0, 0, width, height);
  return canvas;
}

export function releaseCanvas(canvas) {
  // iOS 對 canvas 總記憶體有限制，用完要立刻釋放
  if (canvas) {
    canvas.width = 0;
    canvas.height = 0;
  }
}

/**
 * 把照片畫到指定最長邊的 canvas 上，並確認瀏覽器真的能輸出（iPhone 有面積上限）。
 * 回傳 { canvas, width, height, blob, warnings }。
 */
async function render(img, maxSize, mime, quality, flatten) {
  const warnings = [];
  let { width, height } = fitSize(img.width, img.height, maxSize);
  let canvas = draw(img.source, width, height, flatten);
  let blob = canvas && (await canvasToBlob(canvas, mime, quality));
  if (!blob) {
    releaseCanvas(canvas);
    ({ width, height } = fitSize(img.width, img.height, maxSize, IOS_MAX_CANVAS_AREA));
    canvas = draw(img.source, width, height, flatten);
    blob = canvas && (await canvasToBlob(canvas, mime, quality));
    if (!blob) throw new Error('照片太大，瀏覽器無法處理');
    warnings.push(`照片太大，已縮小為 ${width}×${height}（iPhone 瀏覽器的限制）`);
  }
  return { canvas, width, height, blob, warnings };
}

/** 依設定處理 EXIF：保留、移除 GPS 或全部移除。回傳新的 blob。 */
export async function applyExif(blob, img, format, width, height, metadata, warnings) {
  if (metadata === 'none') return blob;
  const exif = extractExif(img.bytes);
  if (!exif) return blob;
  const patched = patchExif(exif, { width, height, removeGps: metadata === 'nogps' });
  const out = new Uint8Array(await blob.arrayBuffer());
  let result;
  if (format === 'jpg') result = insertExifJpeg(out, patched);
  else if (format === 'png') result = insertExifPng(out, patched);
  else result = insertExifWebp(out, patched, width, height);
  if (!result.ok) {
    warnings.push('EXIF 資料太大，無法保留');
    return blob;
  }
  return new Blob([result.bytes], { type: IMAGE_FORMATS[format].mime });
}

async function encodeWebpFallback(canvas, quality) {
  const { default: encode } = await import('../vendor/jsquash-webp/encode.js');
  const ctx = canvas.getContext('2d');
  const data = ctx.getImageData(0, 0, canvas.width, canvas.height);
  const buf = await encode(data, { quality });
  return new Blob([buf], { type: 'image/webp' });
}

/**
 * 轉換一張照片。
 * @param {File} file
 * @param {{format:'jpg'|'png'|'webp', quality:number, maxSize:number|null, metadata:'keep'|'nogps'|'none'}} opts
 * @returns {Promise<{blob: Blob, ext: string, width: number, height: number, warnings: string[]}>}
 */
export async function convertImage(file, opts) {
  const fmt = IMAGE_FORMATS[opts.format];
  if (!fmt) throw new Error(`不支援的格式：${opts.format}`);
  const img = await openImage(file);
  try {
    const r = await render(img, opts.maxSize, fmt.mime, opts.quality / 100, opts.format === 'jpg');
    let blob = r.blob;
    // Safari 的 canvas 不會輸出 WebP（會偷偷給 PNG），改用內附的 WebP 編碼器
    if (opts.format === 'webp' && blob.type !== 'image/webp') {
      blob = await encodeWebpFallback(r.canvas, opts.quality);
    }
    releaseCanvas(r.canvas);
    blob = await applyExif(blob, img, opts.format, r.width, r.height, opts.metadata, r.warnings);
    return { blob, ext: fmt.ext, width: r.width, height: r.height, warnings: r.warnings };
  } finally {
    closeImage(img);
  }
}

/**
 * 壓縮一張照片成 JPG。
 * - 先依壓縮程度的尺寸與品質處理
 * - 有設定上限而且還是太大：找出符合大小的最高品質，品質降到 40 還太大就再縮小尺寸
 * @param {{level:'light'|'standard'|'strong', targetSize:number|null, metadata:string}} opts
 */
export async function compressImage(file, opts) {
  const [maxSize, quality] = COMPRESS_PRESETS[opts.level] || COMPRESS_PRESETS.standard;
  // 先照壓縮程度處理；有設定上限而且超過時，才再壓得更小
  const first = await convertImage(file, { format: 'jpg', quality, maxSize, metadata: opts.metadata });
  if (!opts.targetSize || first.blob.size <= opts.targetSize) return first;

  const img = await openImage(file);
  try {
    // EXIF 也佔空間，要預留
    const exif = opts.metadata === 'none' ? null : extractExif(img.bytes);
    const budget = opts.targetSize - (exif ? exif.length + 16 : 0);
    let longest = Math.min(maxSize, Math.max(img.width, img.height));
    let best = null;
    const warnings = [];

    for (let round = 0; round < 8 && !best; round++) {
      const r = await render(img, longest, 'image/jpeg', 0.9, true);
      warnings.push(...r.warnings.filter((w) => !warnings.includes(w)));
      let lo = 40;
      let hi = 90;
      while (lo <= hi) {
        const q = Math.floor((lo + hi) / 2);
        const blob = await canvasToBlob(r.canvas, 'image/jpeg', q / 100);
        if (blob.size <= budget) {
          best = { blob, width: r.width, height: r.height };
          lo = q + 1;
        } else {
          hi = q - 1;
        }
      }
      if (!best && round === 7) {
        best = { blob: await canvasToBlob(r.canvas, 'image/jpeg', 0.4), width: r.width, height: r.height };
        warnings.push('無法壓到目標大小以下，已盡量壓縮');
      }
      releaseCanvas(r.canvas);
      longest = Math.floor(Math.min(longest, Math.max(r.width, r.height)) * 0.75);
    }
    if (Math.max(best.width, best.height) < Math.min(maxSize, Math.max(img.width, img.height)) && !warnings.length) {
      warnings.push(`為了符合目標大小，尺寸縮小為 ${best.width}×${best.height}`);
    }
    const blob = await applyExif(best.blob, img, 'jpg', best.width, best.height, opts.metadata, warnings);
    return { blob, ext: '.jpg', width: best.width, height: best.height, warnings };
  } finally {
    closeImage(img);
  }
}
