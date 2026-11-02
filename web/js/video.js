// 影片轉換：用 Mediabunny（瀏覽器內建的 WebCodecs，iPhone 上有硬體加速）轉 MP4/MOV/WebM，
// 用 gifenc 轉 GIF。

import {
  Input,
  Output,
  Conversion,
  ALL_FORMATS,
  BlobSource,
  BufferTarget,
  Mp4OutputFormat,
  MovOutputFormat,
  WebMOutputFormat,
  CanvasSink,
  canEncodeAudio,
  QUALITY_HIGH,
  QUALITY_MEDIUM,
  QUALITY_LOW,
} from 'mediabunny';

export const VIDEO_FORMATS = {
  mp4: { ext: '.mp4', mime: 'video/mp4', videoCodec: 'avc', audioCodec: 'aac' },
  mov: { ext: '.mov', mime: 'video/quicktime', videoCodec: 'avc', audioCodec: 'aac' },
  webm: { ext: '.webm', mime: 'video/webm', videoCodec: 'vp9', audioCodec: 'opus' },
  gif: { ext: '.gif', mime: 'image/gif' },
};

export const RESOLUTIONS = { '480p': 480, '720p': 720, '1080p': 1080, '2160p': 2160 };
const QUALITIES = { high: QUALITY_HIGH, medium: QUALITY_MEDIUM, low: QUALITY_LOW };

const LOCATION_KEY = /location|©xyz|gps/i;

export function supportsVideo() {
  return typeof VideoDecoder !== 'undefined' && typeof VideoEncoder !== 'undefined';
}

/** 依「短邊不超過 N」計算輸出尺寸（只縮小不放大，寬高為偶數）。 */
export function fitResolution(width, height, shortSide) {
  const even = (n) => Math.max(2, Math.round(n / 2) * 2);
  if (!shortSide || Math.min(width, height) <= shortSide) return { width: even(width), height: even(height) };
  const scale = shortSide / Math.min(width, height);
  return { width: even(width * scale), height: even(height * scale) };
}

function openInput(file) {
  return new Input({ source: new BlobSource(file), formats: ALL_FORMATS });
}

async function getVideoTrack(input) {
  let track;
  try {
    track = await input.getPrimaryVideoTrack();
  } catch {
    throw new Error('無法讀取這個影片（檔案可能損壞，或網頁版不支援這種格式，例如 AVI/WMV）');
  }
  if (!track) throw new Error('這個檔案沒有影像');
  if (!(await track.canDecode())) {
    throw new Error(`這台裝置的瀏覽器無法解碼這個影片（${track.codec || '未知編碼'}）`);
  }
  return track;
}

let aacRegistered = false;
async function ensureAacEncoder() {
  if (aacRegistered || (await canEncodeAudio('aac'))) return;
  // 有些瀏覽器不能編碼 AAC，載入內附的編碼器
  const { registerAacEncoder } = await import('../vendor/mediabunny-aac-encoder.min.mjs');
  registerAacEncoder();
  aacRegistered = true;
}

/**
 * 轉換影片。
 * @param {File} file
 * @param {{format:string, resolution:string|null, quality:'high'|'medium'|'low', metadata:'keep'|'nogps'|'none',
 *          start?:number, duration?:number, gifWidth?:number, gifFps?:number}} opts
 * @param {(fraction:number)=>void} onProgress
 * @param {{signal?: AbortSignal}} control
 */
export async function convertVideo(file, opts, onProgress = () => {}, control = {}) {
  if (opts.format === 'gif') return convertToGif(file, opts, onProgress, control);

  const fmt = VIDEO_FORMATS[opts.format];
  if (!fmt) throw new Error(`不支援的格式：${opts.format}`);
  const input = openInput(file);
  const warnings = [];
  try {
    const track = await getVideoTrack(input);
    const audioTrack = await input.getPrimaryAudioTrack().catch(() => null);
    if (audioTrack && audioTrack.codec !== fmt.audioCodec && fmt.audioCodec === 'aac') {
      await ensureAacEncoder();
    }

    const shortSide = RESOLUTIONS[opts.resolution] || null;
    const size = fitResolution(track.displayWidth, track.displayHeight, shortSide);
    const resizing = size.width !== track.displayWidth || size.height !== track.displayHeight;

    const format =
      opts.format === 'mov'
        ? new MovOutputFormat({ fastStart: 'in-memory' })
        : opts.format === 'webm'
          ? new WebMOutputFormat()
          : new Mp4OutputFormat({ fastStart: 'in-memory' });
    const output = new Output({ format, target: new BufferTarget() });

    // 已經是目標編碼、不用縮放、畫質選「高」時，直接搬移影像資料（快又不損失畫質）；
    // 其他情況才重新壓縮。指定 quality 會強制重新壓縮，所以只在需要時才給。
    const quality = QUALITIES[opts.quality] || QUALITY_HIGH;
    const transcode = resizing || track.codec !== fmt.videoCodec || quality !== QUALITY_HIGH;

    const conversion = await Conversion.init({
      input,
      output,
      tracks: 'primary',
      video: {
        codec: fmt.videoCodec,
        ...(transcode ? { quality } : {}),
        ...(resizing ? { width: size.width, height: size.height, fit: 'contain' } : {}),
      },
      // 聲音能直接搬就直接搬，不行才轉成目標格式
      audio: { codec: fmt.audioCodec },
      trim: opts.start || opts.duration ? trimRange(opts) : undefined,
      tags: (tags) => cleanTags(tags, opts.metadata),
      showWarnings: false,
    });

    for (const d of conversion.discardedTracks) {
      if (d.track.type === 'audio') warnings.push('聲音無法轉換，輸出的影片沒有聲音');
    }
    if (!conversion.isValid) {
      const reason = conversion.discardedTracks.map((d) => d.reason).join(', ');
      throw new Error(`這台裝置無法轉換這個影片（${reason}）`);
    }

    conversion.onProgress = (p) => onProgress(Math.min(1, p));
    const abort = () => conversion.cancel();
    control.signal?.addEventListener('abort', abort);
    try {
      await conversion.execute();
    } finally {
      control.signal?.removeEventListener('abort', abort);
    }
    onProgress(1);

    const buffer = output.target.buffer;
    if (opts.format !== 'webm' && opts.metadata !== 'none') {
      const created = await readCreationTime(file);
      if (created) writeCreationTime(buffer, created);
    }
    const blob = new Blob([buffer], { type: fmt.mime });
    return { blob, ext: fmt.ext, width: size.width, height: size.height, warnings };
  } finally {
    input.dispose?.();
  }
}

// ---------- 建立時間（MP4/MOV 的 mvhd/tkhd/mdhd）----------
// Mediabunny 會把輸出的建立時間設為「現在」，這裡改回原影片的拍攝時間，
// 存回相簿時才會排在正確的日期。

const CONTAINERS = new Set(['moov', 'trak', 'mdia']);

function* isoBoxes(view, start, end) {
  let i = start;
  while (i + 8 <= end) {
    let size = view.getUint32(i);
    const type = String.fromCharCode(view.getUint8(i + 4), view.getUint8(i + 5), view.getUint8(i + 6), view.getUint8(i + 7));
    let header = 8;
    if (size === 1) {
      size = Number(view.getBigUint64(i + 8));
      header = 16;
    } else if (size === 0) {
      size = end - i;
    }
    if (size < header) return;
    yield { type, start: i, body: i + header, end: Math.min(i + size, end) };
    i += size;
  }
}

/** 讀出原影片 mvhd 裡的建立時間（自 1904 年起的秒數），沒有則回傳 null。只讀檔頭，不會載入整個檔案。 */
async function readCreationTime(file) {
  try {
    let offset = 0;
    while (offset + 16 <= file.size) {
      const head = new DataView(await file.slice(offset, offset + 16).arrayBuffer());
      let size = head.getUint32(0);
      const type = String.fromCharCode(head.getUint8(4), head.getUint8(5), head.getUint8(6), head.getUint8(7));
      if (size === 1) size = Number(head.getBigUint64(8));
      else if (size === 0) size = file.size - offset;
      if (size < 8) return null;
      if (type === 'moov') {
        const moov = new DataView(await file.slice(offset, offset + size).arrayBuffer());
        for (const box of isoBoxes(moov, 8, moov.byteLength)) {
          if (box.type !== 'mvhd') continue;
          const version = moov.getUint8(box.body);
          const value = version === 1 ? Number(moov.getBigUint64(box.body + 4)) : moov.getUint32(box.body + 4);
          return value > 0 ? value : null;
        }
        return null;
      }
      offset += size;
    }
  } catch {
    /* 不是 MP4/MOV 就算了 */
  }
  return null;
}

function writeCreationTime(buffer, value) {
  const view = new DataView(buffer);
  const visit = (start, end) => {
    for (const box of isoBoxes(view, start, end)) {
      if (CONTAINERS.has(box.type)) visit(box.body, box.end);
      else if (box.type === 'mvhd' || box.type === 'tkhd' || box.type === 'mdhd') {
        const version = view.getUint8(box.body);
        if (version === 1) {
          view.setBigUint64(box.body + 4, BigInt(value));
          view.setBigUint64(box.body + 12, BigInt(value));
        } else if (value <= 0xffffffff) {
          view.setUint32(box.body + 4, value);
          view.setUint32(box.body + 8, value);
        }
      }
    }
  };
  visit(0, buffer.byteLength);
}

function trimRange(opts) {
  const start = Math.max(0, opts.start || 0);
  return opts.duration ? { start, end: start + opts.duration } : { start };
}

function cleanTags(tags, metadata) {
  if (metadata === 'none') return {};
  if (metadata === 'nogps' && tags.raw) {
    const raw = Object.fromEntries(Object.entries(tags.raw).filter(([k]) => !LOCATION_KEY.test(k)));
    return { ...tags, raw };
  }
  return tags;
}

async function convertToGif(file, opts, onProgress, control) {
  const { GIFEncoder, quantize, applyPalette } = await import('../vendor/gifenc.esm.js');
  const input = openInput(file);
  try {
    const track = await getVideoTrack(input);
    const duration = await track.computeDuration();
    const fps = opts.gifFps || 12;
    const start = Math.min(opts.start || 0, Math.max(0, duration - 0.01));
    const end = Math.min(duration, start + (opts.duration || duration));
    const width = Math.min(opts.gifWidth || 480, track.displayWidth);
    const height = Math.max(1, Math.round((track.displayHeight * width) / track.displayWidth));

    const timestamps = [];
    for (let t = start; t < end; t += 1 / fps) timestamps.push(t);
    if (!timestamps.length) throw new Error('擷取的長度是 0 秒');

    const sink = new CanvasSink(track, { width, height, fit: 'fill' });
    const gif = GIFEncoder();
    const delay = Math.round(1000 / fps);
    let n = 0;
    for await (const wrapped of sink.canvasesAtTimestamps(timestamps)) {
      if (control.signal?.aborted) throw new DOMException('已取消', 'AbortError');
      if (!wrapped) continue;
      const ctx = wrapped.canvas.getContext('2d');
      const { data } = ctx.getImageData(0, 0, width, height);
      const palette = quantize(data, 256);
      gif.writeFrame(applyPalette(data, palette), width, height, { palette, delay });
      onProgress(++n / timestamps.length);
      // 讓畫面有機會更新進度條
      if (n % 5 === 0) await new Promise((r) => setTimeout(r));
    }
    gif.finish();
    return { blob: new Blob([gif.bytes()], { type: 'image/gif' }), ext: '.gif', width, height, warnings: [] };
  } finally {
    input.dispose?.();
  }
}
