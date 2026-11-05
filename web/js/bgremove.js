// 照片去背：用 RMBG-1.4 AI 模型（在手機上執行，照片不會上傳）找出主體，
// 再把遮罩套回原尺寸的照片，輸出透明背景的 PNG，或換成指定底色的 JPG。
//
// 模型（約 84 MB）與執行模型的程式（約 28 MB）第一次使用時從網路下載，之後會存在瀏覽器裡，離線也能用。
// 使用 fp16 版本：比 q8 量化版（42 MB）大一倍，但 q8 版的遮罩在背景上會有很多雜點，品質差很多。

import { openImage, closeImage, fitSize, canvasToBlob, applyExif, releaseCanvas, IOS_MAX_CANVAS_AREA } from './image.js';

// Transformers.js 從 CDN 載入（固定版本）；service worker 會把它和模型執行程式一起快取起來，之後離線也能用
const TRANSFORMERS = 'https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.1/dist/transformers.min.js';
const MODEL_ID = 'briaai/RMBG-1.4';
const MODEL_INPUT = 1024; // 模型的輸入尺寸

// RMBG-1.4 的前處理設定（模型庫裡的設定檔是給 Python 用的，這裡直接寫明）
const PROCESSOR_CONFIG = {
  do_normalize: true,
  do_pad: false,
  do_rescale: true,
  do_resize: true,
  image_mean: [0.5, 0.5, 0.5],
  image_std: [1, 1, 1],
  feature_extractor_type: 'ImageFeatureExtractor',
  resample: 2,
  rescale_factor: 1 / 255,
  size: { width: MODEL_INPUT, height: MODEL_INPUT },
};

let loading = null;

/**
 * 載入模型（只會載入一次）。
 * @param {(fraction:number)=>void} onDownload 下載進度（0–1），已經下載過時不會呼叫
 */
export function loadModel(onDownload = () => {}) {
  if (!loading) {
    loading = (async () => {
      const { AutoModel, AutoProcessor, RawImage, env } = await import(TRANSFORMERS);
      env.allowLocalModels = false;
      env.useBrowserCache = true;
      const files = new Map();
      const report = (p) => {
        if (p.status === 'progress' && p.total) {
          files.set(p.file, [p.loaded, p.total]);
          let loaded = 0;
          let total = 0;
          for (const [l, t] of files.values()) {
            loaded += l;
            total += t;
          }
          onDownload(total ? loaded / total : 0);
        }
      };
      const [model, processor] = await Promise.all([
        AutoModel.from_pretrained(MODEL_ID, {
          config: { model_type: 'custom' },
          dtype: 'fp16',
          device: 'wasm',
          progress_callback: report,
        }),
        AutoProcessor.from_pretrained(MODEL_ID, { config: PROCESSOR_CONFIG }),
      ]);
      return { model, processor, RawImage };
    })().catch((err) => {
      loading = null; // 下次再試
      throw new Error(`無法載入去背模型（第一次使用需要網路）：${err.message || err}`);
    });
  }
  return loading;
}

/** 回傳 0–255 的遮罩（Uint8Array，MODEL_INPUT × MODEL_INPUT）。 */
async function predictMask(source, width, height, ai) {
  // 先縮小到模型需要的大小再交給模型，比讓它處理原尺寸照片快很多
  const small = document.createElement('canvas');
  const s = fitSize(width, height, MODEL_INPUT);
  small.width = s.width;
  small.height = s.height;
  small.getContext('2d').drawImage(source, 0, 0, s.width, s.height);
  const image = await ai.RawImage.fromCanvas(small);
  releaseCanvas(small);
  const { pixel_values } = await ai.processor(image);
  const { output } = await ai.model({ input: pixel_values });
  const mask = output[0].mul(255).to('uint8');
  const [, h, w] = mask.dims;
  return { data: mask.data, width: w, height: h };
}

/** 把遮罩變成可以拿來畫的 canvas（alpha = 遮罩值）。 */
function maskCanvas(mask) {
  const c = document.createElement('canvas');
  c.width = mask.width;
  c.height = mask.height;
  const ctx = c.getContext('2d');
  const img = ctx.createImageData(mask.width, mask.height);
  // 清理遮罩：幾乎透明的雜點直接去掉、幾乎不透明的補滿，中間保留柔和的邊緣
  const LOW = 24;
  const HIGH = 232;
  const lut = new Uint8Array(256);
  for (let v = 0; v < 256; v++) {
    lut[v] = v <= LOW ? 0 : v >= HIGH ? 255 : Math.round(((v - LOW) / (HIGH - LOW)) * 255);
  }
  for (let i = 0; i < mask.data.length; i++) img.data[i * 4 + 3] = lut[mask.data[i]];
  ctx.putImageData(img, 0, 0);
  return c;
}

/**
 * 去背一張照片。
 * @param {File} file
 * @param {{background:string, maxSize:number|null, metadata:string}} opts
 *   background：'transparent' 或 CSS 顏色（例如 '#ffffff'）
 * @param {(stage:'download'|'process', fraction:number)=>void} onProgress
 */
export async function removeBackground(file, opts, onProgress = () => {}) {
  const ai = await loadModel((p) => onProgress('download', p));
  onProgress('process', 0.1);

  const img = await openImage(file);
  const warnings = [];
  try {
    const mask = await predictMask(img.source, img.width, img.height, ai);
    onProgress('process', 0.8);

    // 輸出尺寸（iPhone 的 canvas 有面積上限）
    const { width, height } = fitSize(img.width, img.height, opts.maxSize, IOS_MAX_CANVAS_AREA);
    if (!opts.maxSize && (width < img.width || height < img.height)) {
      warnings.push(`照片太大，已縮小為 ${width}×${height}（iPhone 瀏覽器的限制）`);
    }

    const out = document.createElement('canvas');
    out.width = width;
    out.height = height;
    const ctx = out.getContext('2d');
    if (!ctx) throw new Error('照片太大，瀏覽器無法處理');
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(img.source, 0, 0, width, height);
    // 用遮罩挖掉背景：只留下遮罩不透明的地方（放大遮罩時的平滑處理讓邊緣自然）
    const m = maskCanvas(mask);
    ctx.globalCompositeOperation = 'destination-in';
    ctx.drawImage(m, 0, 0, width, height);
    releaseCanvas(m);

    let format = 'png';
    let final = out;
    if (opts.background && opts.background !== 'transparent') {
      // 換成指定底色：鋪底色再把主體畫上去，存成 JPG（比透明 PNG 小很多）
      final = document.createElement('canvas');
      final.width = width;
      final.height = height;
      const fctx = final.getContext('2d');
      fctx.fillStyle = opts.background;
      fctx.fillRect(0, 0, width, height);
      fctx.drawImage(out, 0, 0);
      releaseCanvas(out);
      format = 'jpg';
    }

    let blob = await canvasToBlob(final, format === 'png' ? 'image/png' : 'image/jpeg', 0.92);
    releaseCanvas(final);
    if (!blob) throw new Error('照片太大，瀏覽器無法處理');
    blob = await applyExif(blob, img, format, width, height, opts.metadata, warnings);
    onProgress('process', 1);
    return { blob, ext: format === 'png' ? '.png' : '.jpg', width, height, warnings };
  } finally {
    closeImage(img);
  }
}
