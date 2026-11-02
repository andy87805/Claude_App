// PDF 壓縮
// - 輕度／標準：只重新壓縮 PDF 裡的圖片（文字、向量圖完全不動，仍可選取、搜尋）
// - 強力：每一頁轉成圖片再重組成 PDF（掃描檔效果最好，但文字會變成圖片）

const LIB = '../vendor/pdf-lib.esm.min.js';
const PDFJS_DIR = new URL('../vendor/pdfjs/', import.meta.url).href;

// 圖片的 [最長邊, JPG 品質]
const IMAGE_PRESETS = { light: [2400, 0.8], standard: [1600, 0.7] };
// 強力：每頁轉圖片的解析度（dpi）與 JPG 品質
const RASTER_DPI = 110;
const RASTER_QUALITY = 0.6;
const MAX_PAGE_AREA = 4096 * 4096;

export const LEVEL_ORDER = ['light', 'standard', 'strong'];

function canvasToBlob(canvas, quality) {
  return new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality));
}

function release(canvas) {
  canvas.width = 0;
  canvas.height = 0;
}

async function loadPdf(bytes) {
  const lib = await import(LIB);
  try {
    return { lib, doc: await lib.PDFDocument.load(bytes, { updateMetadata: false }) };
  } catch (err) {
    if (/encrypt/i.test(err.message)) throw new Error('這個 PDF 有密碼保護，無法壓縮');
    throw new Error(`無法讀取這個 PDF：${err.message}`);
  }
}

// ---------- 輕度／標準：重新壓縮圖片 ----------

function nameOf(obj) {
  return obj?.toString?.();
}

/** 回傳圖片的色彩通道數（1 = 灰階、3 = RGB），不支援的色彩空間回傳 0。 */
function channelsOf(colorSpace, lookup) {
  const name = nameOf(colorSpace);
  if (name === '/DeviceRGB' || name === '/CalRGB') return 3;
  if (name === '/DeviceGray' || name === '/CalGray') return 1;
  // [/ICCBased <stream>]：看 N 決定通道數
  if (colorSpace?.asArray) {
    const arr = colorSpace.asArray();
    if (nameOf(arr[0]) === '/ICCBased') {
      const n = lookup(arr[1])?.dict?.get?.(lookup.PDFName.of('N'))?.asNumber?.();
      return n === 1 || n === 3 ? n : 0;
    }
  }
  return 0;
}

async function inflate(data) {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** 還原 PNG 預測（Predictor >= 10）。 */
function unpredict(data, columns, bpp) {
  const rowLen = columns * bpp;
  const rows = Math.floor(data.length / (rowLen + 1));
  const out = new Uint8Array(rows * rowLen);
  for (let r = 0; r < rows; r++) {
    const type = data[r * (rowLen + 1)];
    const src = r * (rowLen + 1) + 1;
    const dst = r * rowLen;
    for (let i = 0; i < rowLen; i++) {
      const raw = data[src + i];
      const left = i >= bpp ? out[dst + i - bpp] : 0;
      const up = r > 0 ? out[dst - rowLen + i] : 0;
      const ul = r > 0 && i >= bpp ? out[dst - rowLen + i - bpp] : 0;
      let v;
      if (type === 0) v = raw;
      else if (type === 1) v = raw + left;
      else if (type === 2) v = raw + up;
      else if (type === 3) v = raw + ((left + up) >> 1);
      else {
        const p = left + up - ul;
        const pa = Math.abs(p - left);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - ul);
        v = raw + (pa <= pb && pa <= pc ? left : pb <= pc ? up : ul);
      }
      out[dst + i] = v & 255;
    }
  }
  return out;
}

/** 把 PDF 圖片解碼成可以畫到 canvas 上的東西；不支援的格式回傳 null。 */
async function decodePdfImage(stream, lib, lookup) {
  const { PDFName } = lib;
  const dict = stream.dict;
  const get = (k) => dict.lookup(PDFName.of(k));
  if (nameOf(get('Subtype')) !== '/Image') return null;
  if (get('ImageMask')?.asBoolean?.() || get('Decode') || get('Mask')) return null;

  let filter = get('Filter');
  if (filter?.asArray) {
    const arr = filter.asArray();
    if (arr.length !== 1) return null;
    filter = arr[0];
  }
  const filterName = nameOf(filter);
  const width = get('Width')?.asNumber?.();
  const height = get('Height')?.asNumber?.();
  if (!width || !height) return null;
  const channels = channelsOf(get('ColorSpace'), lookup);
  if (!channels) return null; // CMYK、Indexed 等：保持原樣

  if (filterName === '/DCTDecode') {
    return { source: await createImageBitmap(new Blob([stream.contents], { type: 'image/jpeg' })), width, height };
  }
  if (filterName === '/FlateDecode' && get('BitsPerComponent')?.asNumber?.() === 8) {
    let data = await inflate(stream.contents);
    let parms = get('DecodeParms');
    if (parms?.asArray) parms = parms.asArray()[0];
    const predictor = parms?.lookup?.(PDFName.of('Predictor'))?.asNumber?.() || 1;
    if (predictor >= 10) data = unpredict(data, width, channels);
    else if (predictor !== 1) return null;
    if (data.length < width * height * channels) return null;
    const rgba = new Uint8ClampedArray(width * height * 4);
    for (let i = 0, j = 0; i < width * height; i++, j += channels) {
      rgba[i * 4] = data[j];
      rgba[i * 4 + 1] = data[j + (channels === 3 ? 1 : 0)];
      rgba[i * 4 + 2] = data[j + (channels === 3 ? 2 : 0)];
      rgba[i * 4 + 3] = 255;
    }
    return { source: await createImageBitmap(new ImageData(rgba, width, height)), width, height };
  }
  return null;
}

async function recompressImages(bytes, level, onProgress) {
  const { lib, doc } = await loadPdf(bytes);
  const { PDFName, PDFRawStream } = lib;
  const [maxSide, quality] = IMAGE_PRESETS[level];
  const lookup = (x) => doc.context.lookup(x);
  lookup.PDFName = PDFName;

  const entries = doc.context.enumerateIndirectObjects().filter(([, obj]) => obj instanceof PDFRawStream);
  let changed = 0;
  for (let n = 0; n < entries.length; n++) {
    const [ref, stream] = entries[n];
    onProgress((n + 1) / entries.length * 0.9);
    let decoded;
    try {
      decoded = await decodePdfImage(stream, lib, lookup);
    } catch {
      decoded = null; // 解不開的圖片保持原樣
    }
    if (!decoded) continue;

    const scale = Math.min(1, maxSide / Math.max(decoded.width, decoded.height));
    const w = Math.max(1, Math.round(decoded.width * scale));
    const h = Math.max(1, Math.round(decoded.height * scale));
    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(decoded.source, 0, 0, w, h);
    decoded.source.close?.();
    const blob = await canvasToBlob(canvas, quality);
    release(canvas);
    if (!blob || blob.size >= stream.contents.length) continue; // 沒變小就不換

    const keep = {};
    for (const key of ['SMask', 'Intent', 'Interpolate', 'Metadata']) {
      const v = stream.dict.get(PDFName.of(key));
      if (v) keep[key] = v;
    }
    const jpeg = new Uint8Array(await blob.arrayBuffer());
    const replacement = doc.context.stream(jpeg, {
      Type: 'XObject',
      Subtype: 'Image',
      Width: w,
      Height: h,
      ColorSpace: 'DeviceRGB',
      BitsPerComponent: 8,
      Filter: 'DCTDecode',
      ...keep,
    });
    doc.context.assign(ref, replacement);
    changed++;
  }
  const out = await doc.save({ useObjectStreams: true });
  onProgress(1);
  return { bytes: out, changed };
}

// ---------- 強力：每頁轉圖片 ----------

async function rasterize(bytes, onProgress) {
  const pdfjs = await import(`${PDFJS_DIR}pdf.min.mjs`);
  pdfjs.GlobalWorkerOptions.workerSrc = `${PDFJS_DIR}pdf.worker.min.mjs`;
  let src;
  let task;
  try {
    task = pdfjs.getDocument({
      data: bytes.slice(),
      cMapUrl: `${PDFJS_DIR}cmaps/`,
      cMapPacked: true,
      standardFontDataUrl: `${PDFJS_DIR}standard_fonts/`,
      wasmUrl: `${PDFJS_DIR}wasm/`,
      iccUrl: `${PDFJS_DIR}iccs/`,
      isEvalSupported: false,
    });
    src = await task.promise;
  } catch (err) {
    task?.destroy();
    if (err?.name === 'PasswordException') throw new Error('這個 PDF 有密碼保護，無法壓縮');
    throw new Error(`無法讀取這個 PDF：${err.message}`);
  }
  const { PDFDocument } = await import(LIB);
  const out = await PDFDocument.create();
  try {
    for (let i = 1; i <= src.numPages; i++) {
      const page = await src.getPage(i);
      const base = page.getViewport({ scale: 1 }); // 單位：點（1/72 吋）
      let scale = RASTER_DPI / 72;
      if (base.width * base.height * scale * scale > MAX_PAGE_AREA) {
        scale = Math.sqrt(MAX_PAGE_AREA / (base.width * base.height));
      }
      const viewport = page.getViewport({ scale });
      const canvas = document.createElement('canvas');
      canvas.width = Math.ceil(viewport.width);
      canvas.height = Math.ceil(viewport.height);
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      await page.render({ canvas, canvasContext: ctx, viewport }).promise;
      const blob = await canvasToBlob(canvas, RASTER_QUALITY);
      release(canvas);
      page.cleanup();
      const img = await out.embedJpg(new Uint8Array(await blob.arrayBuffer()));
      const p = out.addPage([base.width, base.height]);
      p.drawImage(img, { x: 0, y: 0, width: base.width, height: base.height });
      onProgress(i / src.numPages);
    }
  } finally {
    await task.destroy();
  }
  return { bytes: await out.save({ useObjectStreams: true }) };
}

// ---------- 對外 ----------

async function compressOnce(bytes, level, onProgress) {
  if (level === 'strong') {
    const r = await rasterize(bytes, onProgress);
    return { bytes: r.bytes, warnings: ['強力壓縮：每一頁已轉成圖片，文字無法選取或搜尋'] };
  }
  const r = await recompressImages(bytes, level, onProgress);
  return { bytes: r.bytes, warnings: r.changed ? [] : ['這個 PDF 沒有可以壓縮的圖片（多半是純文字 PDF）'] };
}

/**
 * 壓縮 PDF。
 * @param {File} file
 * @param {{level:'light'|'standard'|'strong', targetSize:number|null}} opts
 */
export async function compressPdf(file, opts, onProgress = () => {}) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const done = (r) => ({ blob: new Blob([r.bytes], { type: 'application/pdf' }), ext: '.pdf', warnings: r.warnings });

  if (!opts.targetSize) return done(await compressOnce(bytes, opts.level, onProgress));

  // 有設定上限：從選擇的程度開始，超過上限就改用更強的程度
  const levels = LEVEL_ORDER.slice(Math.max(0, LEVEL_ORDER.indexOf(opts.level)));
  let smallest = null;
  for (let i = 0; i < levels.length; i++) {
    const level = levels[i];
    const r = await compressOnce(bytes, level, (p) => onProgress((i + p) / levels.length));
    if (i > 0) r.warnings = [...r.warnings, '為了符合上限，改用更強的壓縮'];
    if (r.bytes.length <= opts.targetSize) return done(r);
    if (!smallest || r.bytes.length < smallest.bytes.length) smallest = r;
  }
  smallest.warnings = [...smallest.warnings, '無法壓到目標大小以下，已盡量壓縮'];
  return done(smallest);
}
