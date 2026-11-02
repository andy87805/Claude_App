// 照片轉換：瀏覽器解碼 -> canvas 縮放 -> 編碼成 JPG/PNG/WebP，再把 EXIF 放回去。

import { extractExif, patchExif, insertExifJpeg, insertExifPng, insertExifWebp } from './exif.js';

export const IMAGE_FORMATS = {
  jpg: { mime: 'image/jpeg', ext: '.jpg' },
  png: { mime: 'image/png', ext: '.png' },
  webp: { mime: 'image/webp', ext: '.webp' },
};

// iPhone Safari 的 canvas 面積上限（約 1600 萬像素）
const IOS_MAX_CANVAS_AREA = 4096 * 4096;

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

async function decode(file, bytes) {
  try {
    return await decodeWithBrowser(file);
  } catch (err) {
    // 非 Safari 的瀏覽器多半不能直接讀 HEIC，改用內附的 libheif 解碼
    if (isHeicLike(file, bytes)) {
      const { heicTo } = await import('../vendor/heic-to.js');
      return heicTo({ blob: file, type: 'bitmap' });
    }
    throw new Error('無法讀取這張照片（檔案可能損壞，或是瀏覽器不支援這種格式）');
  }
}

function sizeOf(source) {
  return {
    width: source.naturalWidth || source.width,
    height: source.naturalHeight || source.height,
  };
}

function targetSize(width, height, maxSize, maxArea) {
  let scale = 1;
  if (maxSize && Math.max(width, height) > maxSize) scale = maxSize / Math.max(width, height);
  if (maxArea && width * height * scale * scale > maxArea) scale = Math.sqrt(maxArea / (width * height));
  return {
    width: Math.max(1, Math.floor(width * scale)),
    height: Math.max(1, Math.floor(height * scale)),
  };
}

function canvasToBlob(canvas, mime, quality) {
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

function releaseCanvas(canvas) {
  // iOS 對 canvas 總記憶體有限制，用完要立刻釋放
  if (canvas) {
    canvas.width = 0;
    canvas.height = 0;
  }
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
  const warnings = [];
  const bytes = new Uint8Array(await file.arrayBuffer());
  const source = await decode(file, bytes);
  const { width: srcW, height: srcH } = sizeOf(source);
  if (!srcW || !srcH) throw new Error('無法讀取照片尺寸');

  const quality = opts.quality / 100;
  const flatten = opts.format === 'jpg';
  let { width, height } = targetSize(srcW, srcH, opts.maxSize);
  let canvas = draw(source, width, height, flatten);
  let blob = canvas && (await canvasToBlob(canvas, fmt.mime, quality));

  if (!blob) {
    // iPhone 對 canvas 有面積上限，超過就縮小到上限內再試
    releaseCanvas(canvas);
    ({ width, height } = targetSize(srcW, srcH, opts.maxSize, IOS_MAX_CANVAS_AREA));
    canvas = draw(source, width, height, flatten);
    blob = canvas && (await canvasToBlob(canvas, fmt.mime, quality));
    if (!blob) throw new Error('照片太大，瀏覽器無法處理');
    warnings.push(`照片太大，已縮小為 ${width}×${height}（iPhone 瀏覽器的限制）`);
  }

  // Safari 的 canvas 不會輸出 WebP（會偷偷給 PNG），改用內附的 WebP 編碼器
  if (opts.format === 'webp' && blob.type !== 'image/webp') {
    blob = await encodeWebpFallback(canvas, opts.quality);
  }
  releaseCanvas(canvas);
  if (source.close) source.close();

  if (opts.metadata !== 'none') {
    const exif = extractExif(bytes);
    if (exif) {
      const patched = patchExif(exif, { width, height, removeGps: opts.metadata === 'nogps' });
      const out = new Uint8Array(await blob.arrayBuffer());
      let result;
      if (opts.format === 'jpg') result = insertExifJpeg(out, patched);
      else if (opts.format === 'png') result = insertExifPng(out, patched);
      else result = insertExifWebp(out, patched, width, height);
      if (result.ok) blob = new Blob([result.bytes], { type: fmt.mime });
      else warnings.push('EXIF 資料太大，無法保留');
    }
  }

  return { blob, ext: fmt.ext, width, height, warnings };
}
