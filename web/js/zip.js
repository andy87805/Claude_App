// 把多個檔案打包成一個 ZIP（不再壓縮，因為照片、影片、PDF 本身已經壓縮過，存放模式最快）。
// 回傳 Blob；檔案內容直接引用原本的 Blob，不會額外複製一份到記憶體。

let crcTable;
function crc32(bytes, crc = 0xffffffff) {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  for (let i = 0; i < bytes.length; i++) crc = crcTable[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  return crc;
}

async function crcOfBlob(blob) {
  let crc = 0xffffffff;
  const chunk = 8 * 1024 * 1024; // 分段讀，避免大影片一次佔用太多記憶體
  for (let pos = 0; pos < blob.size; pos += chunk) {
    crc = crc32(new Uint8Array(await blob.slice(pos, pos + chunk).arrayBuffer()), crc);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function dosDateTime(date) {
  const time = (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2);
  const day = ((date.getFullYear() - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate();
  return { time, day };
}

/**
 * @param {File[]} files
 * @param {(fraction:number)=>void} onProgress
 * @returns {Promise<Blob>}
 */
export async function makeZip(files, onProgress = () => {}) {
  const encoder = new TextEncoder();
  const parts = [];
  const central = [];
  let offset = 0;

  for (let n = 0; n < files.length; n++) {
    const file = files[n];
    if (file.size >= 0xffffffff || offset >= 0xffffffff) throw new Error('檔案太大，無法打包成 ZIP');
    const name = encoder.encode(file.name);
    const crc = await crcOfBlob(file);
    const { time, day } = dosDateTime(new Date(file.lastModified || Date.now()));

    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true); // 檔案標頭
    local.setUint16(4, 20, true); // 需要的版本
    local.setUint16(6, 0x0800, true); // 檔名使用 UTF-8（中文檔名才不會亂碼）
    local.setUint16(8, 0, true); // 存放，不壓縮
    local.setUint16(10, time, true);
    local.setUint16(12, day, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, file.size, true);
    local.setUint32(22, file.size, true);
    local.setUint16(26, name.length, true);
    local.setUint16(28, 0, true);
    parts.push(local.buffer, name, file);

    const entry = new DataView(new ArrayBuffer(46));
    entry.setUint32(0, 0x02014b50, true); // 中央目錄
    entry.setUint16(4, 20, true);
    entry.setUint16(6, 20, true);
    entry.setUint16(8, 0x0800, true);
    entry.setUint16(10, 0, true);
    entry.setUint16(12, time, true);
    entry.setUint16(14, day, true);
    entry.setUint32(16, crc, true);
    entry.setUint32(20, file.size, true);
    entry.setUint32(24, file.size, true);
    entry.setUint16(28, name.length, true);
    entry.setUint32(42, offset, true);
    central.push(entry.buffer, name);

    offset += 30 + name.length + file.size;
    onProgress((n + 1) / files.length);
  }

  const centralSize = central.reduce((s, p) => s + (p.byteLength ?? p.length), 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true); // 結尾
  end.setUint16(8, files.length, true);
  end.setUint16(10, files.length, true);
  end.setUint32(12, centralSize, true);
  end.setUint32(16, offset, true);

  return new Blob([...parts, ...central, end.buffer], { type: 'application/zip' });
}
