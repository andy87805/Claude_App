// EXIF 處理：從各種格式讀出原始 EXIF（TIFF 結構），修改後再寫進新檔案。
// 直接搬移原始位元組，所以拍攝時間、相機、GPS、MakerNote 等所有欄位都會完整保留。

const TAG_ORIENTATION = 0x0112;
const TAG_EXIF_IFD = 0x8769;
const TAG_GPS_IFD = 0x8825;
const TAG_PIXEL_X = 0xa002;
const TAG_PIXEL_Y = 0xa003;

// TIFF 資料型別 -> 每個值的位元組數
const TYPE_SIZE = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4 };

const EXIF_HEADER = [0x45, 0x78, 0x69, 0x66, 0, 0]; // "Exif\0\0"

const ascii = (bytes, start, len) => String.fromCharCode(...bytes.subarray(start, start + len));

function startsWithExifHeader(bytes, offset = 0) {
  return EXIF_HEADER.every((b, i) => bytes[offset + i] === b);
}

function isTiff(bytes) {
  return (
    bytes.length >= 8 &&
    ((bytes[0] === 0x49 && bytes[1] === 0x49 && bytes[2] === 0x2a && bytes[3] === 0) ||
      (bytes[0] === 0x4d && bytes[1] === 0x4d && bytes[2] === 0 && bytes[3] === 0x2a))
  );
}

function normalizeTiff(data) {
  if (!data) return null;
  if (startsWithExifHeader(data)) data = data.subarray(6);
  return isTiff(data) ? data.slice() : null;
}

// ---------- 讀取 ----------

function extractFromJpeg(bytes) {
  let i = 2;
  while (i + 4 <= bytes.length) {
    if (bytes[i] !== 0xff) return null;
    const marker = bytes[i + 1];
    if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) {
      i += 2;
      continue;
    }
    if (marker === 0xda || marker === 0xd9) return null; // 影像資料開始，後面不會有 EXIF
    const len = (bytes[i + 2] << 8) | bytes[i + 3];
    if (marker === 0xe1 && startsWithExifHeader(bytes, i + 4)) {
      return normalizeTiff(bytes.subarray(i + 4, i + 2 + len));
    }
    i += 2 + len;
  }
  return null;
}

function extractFromPng(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let i = 8;
  while (i + 8 <= bytes.length) {
    const len = dv.getUint32(i);
    const type = ascii(bytes, i + 4, 4);
    if (type === 'eXIf') return normalizeTiff(bytes.subarray(i + 8, i + 8 + len));
    if (type === 'IEND') return null;
    i += 12 + len;
  }
  return null;
}

function extractFromWebp(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let i = 12;
  while (i + 8 <= bytes.length) {
    const type = ascii(bytes, i, 4);
    const len = dv.getUint32(i + 4, true);
    if (type === 'EXIF') return normalizeTiff(bytes.subarray(i + 8, i + 8 + len));
    i += 8 + len + (len & 1);
  }
  return null;
}

// HEIC / AVIF（ISOBMFF）：meta -> iinf 找 Exif 項目 -> iloc 找位置
function extractFromIsobmff(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

  function* boxes(start, end) {
    let i = start;
    while (i + 8 <= end) {
      let size = dv.getUint32(i);
      const type = ascii(bytes, i + 4, 4);
      let header = 8;
      if (size === 1) {
        size = Number(dv.getBigUint64(i + 8));
        header = 16;
      } else if (size === 0) {
        size = end - i;
      }
      if (size < header) return;
      yield { type, start: i, body: i + header, end: Math.min(i + size, end) };
      i += size;
    }
  }

  const readUint = (pos, size) => {
    if (size === 0) return 0;
    if (size === 2) return dv.getUint16(pos);
    if (size === 4) return dv.getUint32(pos);
    if (size === 8) return Number(dv.getBigUint64(pos));
    throw new Error('bad size');
  };

  const meta = [...boxes(0, bytes.length)].find((b) => b.type === 'meta');
  if (!meta) return null;
  const children = [...boxes(meta.body + 4, meta.end)]; // meta 是 full box，跳過 version/flags

  // iinf：找出類型為 'Exif' 的項目 ID
  const iinf = children.find((b) => b.type === 'iinf');
  if (!iinf) return null;
  const iinfVersion = bytes[iinf.body];
  const entriesStart = iinf.body + 4 + (iinfVersion === 0 ? 2 : 4);
  let exifId = null;
  for (const infe of boxes(entriesStart, iinf.end)) {
    if (infe.type !== 'infe') continue;
    const v = bytes[infe.body];
    if (v < 2) continue;
    let p = infe.body + 4;
    const id = v === 2 ? dv.getUint16(p) : dv.getUint32(p);
    p += v === 2 ? 2 : 4;
    p += 2; // item_protection_index
    if (ascii(bytes, p, 4) === 'Exif') {
      exifId = id;
      break;
    }
  }
  if (exifId === null) return null;

  // iloc：找出該項目的檔案位置
  const iloc = children.find((b) => b.type === 'iloc');
  if (!iloc) return null;
  const v = bytes[iloc.body];
  let p = iloc.body + 4;
  const offsetSize = bytes[p] >> 4;
  const lengthSize = bytes[p] & 15;
  const baseOffsetSize = bytes[p + 1] >> 4;
  const indexSize = v === 1 || v === 2 ? bytes[p + 1] & 15 : 0;
  p += 2;
  const itemCount = v < 2 ? dv.getUint16(p) : dv.getUint32(p);
  p += v < 2 ? 2 : 4;
  for (let n = 0; n < itemCount; n++) {
    const id = v < 2 ? dv.getUint16(p) : dv.getUint32(p);
    p += v < 2 ? 2 : 4;
    let method = 0;
    if (v === 1 || v === 2) {
      method = dv.getUint16(p) & 15;
      p += 2;
    }
    p += 2; // data_reference_index
    const baseOffset = readUint(p, baseOffsetSize);
    p += baseOffsetSize;
    const extentCount = dv.getUint16(p);
    p += 2;
    const extents = [];
    for (let e = 0; e < extentCount; e++) {
      p += indexSize;
      const off = readUint(p, offsetSize);
      p += offsetSize;
      const len = readUint(p, lengthSize);
      p += lengthSize;
      extents.push([baseOffset + off, len]);
    }
    if (id !== exifId) continue;
    if (method !== 0) return null; // 不支援 idat 等其他存放方式（實務上很少見）
    const total = extents.reduce((s, [, len]) => s + len, 0);
    const data = new Uint8Array(total);
    let w = 0;
    for (const [off, len] of extents) {
      data.set(bytes.subarray(off, off + len), w);
      w += len;
    }
    // 前 4 個位元組是到 TIFF 標頭的位移
    const skip = 4 + new DataView(data.buffer).getUint32(0);
    return normalizeTiff(data.subarray(skip));
  }
  return null;
}

/** 從圖片檔的位元組中取出 EXIF（TIFF 格式的 Uint8Array），沒有則回傳 null。 */
export function extractExif(bytes) {
  try {
    if (bytes[0] === 0xff && bytes[1] === 0xd8) return extractFromJpeg(bytes);
    if (bytes[0] === 0x89 && ascii(bytes, 1, 3) === 'PNG') return extractFromPng(bytes);
    if (ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 4) === 'WEBP') return extractFromWebp(bytes);
    if (ascii(bytes, 4, 4) === 'ftyp') return extractFromIsobmff(bytes);
    if (isTiff(bytes)) return null; // TIFF 檔本身就是 EXIF 結構，太複雜，略過
  } catch (err) {
    console.warn('讀取 EXIF 失敗', err);
  }
  return null;
}

// ---------- 修改 ----------

class Tiff {
  constructor(bytes) {
    this.bytes = bytes;
    this.dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    this.le = bytes[0] === 0x49;
  }
  u16(p) { return this.dv.getUint16(p, this.le); }
  u32(p) { return this.dv.getUint32(p, this.le); }
  set16(p, v) { this.dv.setUint16(p, v, this.le); }
  set32(p, v) { this.dv.setUint32(p, v, this.le); }
  inRange(p, len) { return p >= 0 && p + len <= this.bytes.length; }

  /** 回傳 IFD 中每個欄位：{ tag, type, count, entry(欄位位置), valuePos(值的位置), size } */
  entries(ifd) {
    if (!this.inRange(ifd, 2)) return [];
    const n = this.u16(ifd);
    if (!this.inRange(ifd + 2, n * 12 + 4)) return [];
    const list = [];
    for (let k = 0; k < n; k++) {
      const entry = ifd + 2 + k * 12;
      const tag = this.u16(entry);
      const type = this.u16(entry + 2);
      const count = this.u32(entry + 4);
      const size = (TYPE_SIZE[type] || 1) * count;
      const valuePos = size <= 4 ? entry + 8 : this.u32(entry + 8);
      list.push({ tag, type, count, entry, valuePos, size });
    }
    return list;
  }

  ifd0() { return this.u32(4); }

  find(ifd, tag) { return this.entries(ifd).find((e) => e.tag === tag); }

  /** 從 IFD 移除一個欄位：把後面的欄位往前搬。 */
  removeEntry(ifd, entry) {
    const n = this.u16(ifd);
    const end = ifd + 2 + n * 12 + 4; // 含 next-IFD 位移
    this.bytes.copyWithin(entry, entry + 12, end);
    this.bytes.fill(0, end - 12, end);
    this.set16(ifd, n - 1);
  }

  /** 把整個子 IFD（含它指向的資料）清成 0，確保資料真的不在檔案裡。 */
  wipeIfd(ifd) {
    for (const e of this.entries(ifd)) {
      if (e.size > 4 && this.inRange(e.valuePos, e.size)) this.bytes.fill(0, e.valuePos, e.valuePos + e.size);
    }
    if (this.inRange(ifd, 2)) {
      const n = this.u16(ifd);
      const len = Math.min(2 + n * 12 + 4, this.bytes.length - ifd);
      this.bytes.fill(0, ifd, ifd + len);
    }
  }

  setNumber(e, value) {
    if (e.type === 3 && e.count === 1) this.set16(e.valuePos, Math.min(value, 0xffff));
    else if (e.type === 4 && e.count === 1) this.set32(e.valuePos, value);
  }
}

/**
 * 修改 EXIF（會複製一份，不改到原本的）。
 * - 方向重設為 1（因為像素已經轉正）
 * - 更新寬高欄位
 * - removeGps：移除 GPS 並清除資料
 */
export function patchExif(tiffBytes, { width, height, removeGps = false } = {}) {
  const t = new Tiff(tiffBytes.slice());
  const ifd0 = t.ifd0();

  const orientation = t.find(ifd0, TAG_ORIENTATION);
  if (orientation && orientation.type === 3) t.set16(orientation.valuePos, 1);

  const exifPtr = t.find(ifd0, TAG_EXIF_IFD);
  if (exifPtr && width && height) {
    const exifIfd = t.u32(exifPtr.valuePos);
    const px = t.find(exifIfd, TAG_PIXEL_X);
    const py = t.find(exifIfd, TAG_PIXEL_Y);
    if (px) t.setNumber(px, width);
    if (py) t.setNumber(py, height);
  }

  if (removeGps) {
    const gps = t.find(ifd0, TAG_GPS_IFD);
    if (gps) {
      t.wipeIfd(t.u32(gps.valuePos));
      t.removeEntry(ifd0, gps.entry);
    }
  }
  return t.bytes;
}

/** 讀出幾個常用欄位（給測試和畫面顯示用）。 */
export function readExifSummary(tiffBytes) {
  const t = new Tiff(tiffBytes);
  const ifd0 = t.ifd0();
  const str = (e) => (e ? ascii(t.bytes, e.valuePos, e.count).replace(/\0+$/, '') : undefined);
  const out = {};
  const o = t.find(ifd0, TAG_ORIENTATION);
  if (o) out.orientation = t.u16(o.valuePos);
  out.make = str(t.find(ifd0, 0x010f));
  out.model = str(t.find(ifd0, 0x0110));
  const exifPtr = t.find(ifd0, TAG_EXIF_IFD);
  if (exifPtr) out.dateTimeOriginal = str(t.find(t.u32(exifPtr.valuePos), 0x9003));
  out.hasGps = !!t.find(ifd0, TAG_GPS_IFD);
  return out;
}

// ---------- 寫入 ----------

const MAX_APP1 = 65533 - 6;

/** 把 EXIF 放進 JPEG（插在 SOI 之後，並移除原本的 APP1 EXIF）。 */
export function insertExifJpeg(jpeg, tiff) {
  if (tiff.length > MAX_APP1) return { bytes: jpeg, ok: false };
  // 找出要保留的區段（跳過原有的 EXIF APP1）
  const parts = [jpeg.subarray(0, 2)];
  const app1Len = 2 + 6 + tiff.length;
  const app1 = new Uint8Array(2 + app1Len);
  app1[0] = 0xff;
  app1[1] = 0xe1;
  app1[2] = app1Len >> 8;
  app1[3] = app1Len & 0xff;
  app1.set(EXIF_HEADER, 4);
  app1.set(tiff, 10);

  let i = 2;
  let insertedAfterApp0 = false;
  while (i + 4 <= jpeg.length && jpeg[i] === 0xff) {
    const marker = jpeg[i + 1];
    if (marker === 0xda) break;
    const len = (jpeg[i + 2] << 8) | jpeg[i + 3];
    const seg = jpeg.subarray(i, i + 2 + len);
    const isExif = marker === 0xe1 && startsWithExifHeader(jpeg, i + 4);
    if (!isExif) parts.push(seg);
    if (marker === 0xe0 && !insertedAfterApp0) {
      parts.push(app1);
      insertedAfterApp0 = true;
    }
    i += 2 + len;
  }
  if (!insertedAfterApp0) parts.splice(1, 0, app1);
  parts.push(jpeg.subarray(i));
  return { bytes: concat(parts), ok: true };
}

let crcTable;
function crc32(bytes) {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** 把 EXIF 放進 PNG（eXIf 區塊，放在 IHDR 後面）。 */
export function insertExifPng(png, tiff) {
  const dv = new DataView(png.buffer, png.byteOffset, png.byteLength);
  const ihdrEnd = 8 + 12 + dv.getUint32(8);
  const chunk = new Uint8Array(12 + tiff.length);
  const cdv = new DataView(chunk.buffer);
  cdv.setUint32(0, tiff.length);
  chunk.set([0x65, 0x58, 0x49, 0x66], 4); // "eXIf"
  chunk.set(tiff, 8);
  cdv.setUint32(8 + tiff.length, crc32(chunk.subarray(4, 8 + tiff.length)));
  return { bytes: concat([png.subarray(0, ihdrEnd), chunk, png.subarray(ihdrEnd)]), ok: true };
}

/** 把 EXIF 放進 WebP（需要轉成 VP8X 延伸格式）。 */
export function insertExifWebp(webp, tiff, width, height) {
  const dv = new DataView(webp.buffer, webp.byteOffset, webp.byteLength);
  const chunks = [];
  let i = 12;
  while (i + 8 <= webp.length) {
    const type = ascii(webp, i, 4);
    const len = dv.getUint32(i + 4, true);
    const total = 8 + len + (len & 1);
    chunks.push({ type, bytes: webp.subarray(i, i + total) });
    i += total;
  }
  const others = chunks.filter((c) => c.type !== 'VP8X' && c.type !== 'EXIF');
  const vp8x = chunks.find((c) => c.type === 'VP8X');
  let flags = vp8x ? vp8x.bytes[8] : 0;
  if (chunks.some((c) => c.type === 'ALPH' || c.type === 'VP8L')) flags |= 0x10;
  flags |= 0x08; // EXIF

  const header = new Uint8Array(18);
  header.set([0x56, 0x50, 0x38, 0x58], 0); // "VP8X"
  new DataView(header.buffer).setUint32(4, 10, true);
  header[8] = flags;
  const w = width - 1;
  const h = height - 1;
  header.set([w & 255, (w >> 8) & 255, (w >> 16) & 255, h & 255, (h >> 8) & 255, (h >> 16) & 255], 12);

  const exifChunk = new Uint8Array(8 + tiff.length + (tiff.length & 1));
  exifChunk.set([0x45, 0x58, 0x49, 0x46], 0); // "EXIF"
  new DataView(exifChunk.buffer).setUint32(4, tiff.length, true);
  exifChunk.set(tiff, 8);

  const body = concat([header, ...others.map((c) => c.bytes), exifChunk]);
  const out = new Uint8Array(12 + body.length);
  out.set(webp.subarray(0, 4), 0); // "RIFF"
  new DataView(out.buffer).setUint32(4, 4 + body.length, true);
  out.set([0x57, 0x45, 0x42, 0x50], 8); // "WEBP"
  out.set(body, 12);
  return { bytes: out, ok: true };
}

function concat(parts) {
  const total = parts.reduce((s, p) => s + p.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}
