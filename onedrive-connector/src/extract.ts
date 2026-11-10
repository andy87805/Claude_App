// 從 Word / PowerPoint / Excel（都是 ZIP 裡包 XML）抽出純文字。

import { unzipSync, strFromU8 } from "fflate";

const decodeEntities = (text: string) =>
  text
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(Number(dec)))
    .replace(/&amp;/g, "&");

/** 取出所有 <tag>…</tag> 的文字並接起來。 */
function textOf(xml: string, tag: string): string {
  const re = new RegExp(`<${tag}(?:\\s[^>]*)?>([^<]*)</${tag}>`, "g");
  let out = "";
  for (const match of xml.matchAll(re)) out += match[1];
  return decodeEntities(out);
}

const numbered = (name: string) => Number(name.match(/(\d+)\.xml$/)?.[1] ?? 0);

function docx(files: Record<string, Uint8Array>): string {
  const xml = strFromU8(files["word/document.xml"] ?? new Uint8Array());
  return xml
    .split(/<\/w:p>/)
    .map((paragraph) =>
      textOf(paragraph.replace(/<w:tab\/>/g, "<w:t>\t</w:t>").replace(/<w:br\/>/g, "<w:t>\n</w:t>"), "w:t"),
    )
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function pptx(files: Record<string, Uint8Array>): string {
  return Object.keys(files)
    .filter((name) => /^ppt\/slides\/slide\d+\.xml$/.test(name))
    .sort((a, b) => numbered(a) - numbered(b))
    .map((name, index) => {
      const lines = strFromU8(files[name])
        .split(/<\/a:p>/)
        .map((paragraph) => textOf(paragraph, "a:t"))
        .filter((line) => line.trim());
      return `--- 投影片 ${index + 1} ---\n${lines.join("\n")}`;
    })
    .join("\n\n");
}

function xlsx(files: Record<string, Uint8Array>): string {
  const shared = strFromU8(files["xl/sharedStrings.xml"] ?? new Uint8Array())
    .split(/<\/si>/)
    .slice(0, -1)
    .map((item) => textOf(item, "t"));

  // 工作表名稱依 workbook.xml 的順序；對應不到時退回檔名。
  const names = [...strFromU8(files["xl/workbook.xml"] ?? new Uint8Array()).matchAll(/<sheet\s[^>]*name="([^"]*)"/g)].map(
    (match) => decodeEntities(match[1]),
  );

  return Object.keys(files)
    .filter((name) => /^xl\/worksheets\/sheet\d+\.xml$/.test(name))
    .sort((a, b) => numbered(a) - numbered(b))
    .map((name, index) => {
      const rows = strFromU8(files[name])
        .split(/<\/row>/)
        .slice(0, -1)
        .map((row) => {
          const cells: string[] = [];
          for (const cell of row.matchAll(/<c\s([^>]*?)(?:\/>|>(.*?)<\/c>)/gs)) {
            const attrs = cell[1];
            const inner = cell[2] ?? "";
            const column = columnIndex(attrs.match(/r="([A-Z]+)\d+"/)?.[1]);
            const type = attrs.match(/t="(\w+)"/)?.[1];
            const raw = textOf(inner, "v");
            let value = raw;
            if (type === "s") value = shared[Number(raw)] ?? "";
            else if (type === "inlineStr") value = textOf(inner, "t");
            else if (type === "b") value = raw === "1" ? "TRUE" : "FALSE";
            cells[column ?? cells.length] = value.replace(/[\t\n]+/g, " ");
          }
          return Array.from(cells, (value) => value ?? "").join("\t");
        });
      return `--- 工作表：${names[index] ?? name} ---\n${rows.join("\n")}`;
    })
    .join("\n\n");
}

function columnIndex(letters?: string): number | undefined {
  if (!letters) return undefined;
  let index = 0;
  for (const char of letters) index = index * 26 + (char.charCodeAt(0) - 64);
  return index - 1;
}

const WANTED: Record<string, RegExp> = {
  docx: /^word\/document\.xml$/,
  pptx: /^ppt\/slides\/slide\d+\.xml$/,
  xlsx: /^xl\/(sharedStrings\.xml|workbook\.xml|worksheets\/sheet\d+\.xml)$/,
};

export type OfficeKind = "docx" | "pptx" | "xlsx";

export function officeKind(fileName: string): OfficeKind | undefined {
  const ext = fileName.toLowerCase().split(".").pop() ?? "";
  if (ext === "docx" || ext === "docm") return "docx";
  if (ext === "pptx" || ext === "pptm") return "pptx";
  if (ext === "xlsx" || ext === "xlsm") return "xlsx";
  return undefined;
}

export function extractOfficeText(kind: OfficeKind, data: Uint8Array): string {
  const files = unzipSync(data, { filter: (file) => WANTED[kind].test(file.name) });
  if (kind === "docx") return docx(files);
  if (kind === "pptx") return pptx(files);
  return xlsx(files);
}
