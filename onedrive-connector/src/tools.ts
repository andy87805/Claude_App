// Claude 看得到的 OneDrive 工具。

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { Buffer } from "node:buffer";
import { z } from "zod";
import { extractOfficeText, officeKind } from "./extract";
import { Graph, GraphError, MsTokenError } from "./microsoft";

const MB = 1024 * 1024;
const MAX_TEXT_BYTES = 5 * MB;
const MAX_OFFICE_BYTES = 15 * MB;
const MAX_INLINE_IMAGE_BYTES = 1 * MB;
const MAX_BASE64_BYTES = 1 * MB;
const MAX_UPLOAD_BYTES = 4 * MB;
const DEFAULT_MAX_CHARS = 100_000;

const INLINE_IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"]);
const TEXT_EXTENSIONS = new Set(
  "txt md markdown csv tsv json jsonl xml html htm css js mjs ts tsx jsx py rb go rs java kt c h cpp hpp cs php sh bat ps1 sql yaml yml toml ini cfg conf log tex srt vtt svg rtf".split(
    " ",
  ),
);

interface DriveItem {
  id: string;
  name: string;
  size?: number;
  webUrl?: string;
  lastModifiedDateTime?: string;
  folder?: { childCount?: number };
  file?: { mimeType?: string };
  parentReference?: { path?: string };
  "@microsoft.graph.downloadUrl"?: string;
}

const SELECT = "$select=id,name,size,webUrl,lastModifiedDateTime,folder,file,parentReference";

const target = {
  path: z
    .string()
    .optional()
    .describe('OneDrive 內的路徑，例如 "/文件/報告.docx"。"/" 代表根目錄。'),
  item_id: z.string().optional().describe("項目的 id（來自列出或搜尋的結果）。和 path 擇一。"),
};

/** 把 "/文件/報告.docx" 編成 Graph 的路徑定址；空路徑是根目錄。 */
export function encodePath(path: string): string {
  return path
    .split("/")
    .filter((segment) => segment && segment !== ".")
    .map((segment) => {
      if (segment === "..") throw new GraphError(400, "invalidRequest", '路徑不能包含 ".."');
      return encodeURIComponent(segment).replace(/'/g, "%27");
    })
    .join("/");
}

/** 項目的 Graph 網址；suffix 例如 "/children"、"/content"。 */
export function itemUrl(where: { path?: string; item_id?: string }, suffix = ""): string {
  if (where.item_id) return `/me/drive/items/${encodeURIComponent(where.item_id)}${suffix}`;
  const encoded = encodePath(where.path ?? "/");
  if (!encoded) return `/me/drive/root${suffix}`;
  return `/me/drive/root:/${encoded}${suffix ? `:${suffix}` : ""}`;
}

function summarize(item: DriveItem) {
  const parent = item.parentReference?.path?.replace(/^\/drives?\/[^/]+\/root:|^\/drive\/root:/, "");
  return {
    name: item.name,
    type: item.folder ? "folder" : "file",
    path: parent === undefined ? undefined : `${decodeURIComponent(parent)}/${item.name}`,
    id: item.id,
    size: item.folder ? undefined : item.size,
    children: item.folder?.childCount,
    mime_type: item.file?.mimeType,
    modified: item.lastModifiedDateTime,
    web_url: item.webUrl,
  };
}

const text = (value: unknown) => ({
  content: [{ type: "text" as const, text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }],
});

const fail = (message: string) => ({ content: [{ type: "text" as const, text: message }], isError: true });

function describeError(error: unknown): string {
  if (error instanceof GraphError) {
    if (error.status === 404) return "找不到這個檔案或資料夾，請確認路徑或 id。";
    if (error.status === 409) return "同名的項目已經存在。";
    return `OneDrive 回報錯誤（${error.status} ${error.code}）：${error.message}`;
  }
  if (error instanceof MsTokenError) return "Microsoft 登入已失效，請到 Claude 的連接器設定重新連接 OneDrive。";
  return `發生錯誤：${error instanceof Error ? error.message : String(error)}`;
}

const guard =
  <A>(run: (args: A) => Promise<ReturnType<typeof text> | ReturnType<typeof fail> | any>) =>
  async (args: A) => {
    try {
      return await run(args);
    } catch (error) {
      return fail(describeError(error));
    }
  };

const formatSize = (bytes: number) => (bytes >= MB ? `${(bytes / MB).toFixed(1)} MB` : `${Math.ceil(bytes / 1024)} KB`);

function isTextFile(item: DriveItem): boolean {
  const mime = item.file?.mimeType ?? "";
  const ext = item.name.toLowerCase().split(".").pop() ?? "";
  return mime.startsWith("text/") || /json|xml|javascript|yaml/.test(mime) || TEXT_EXTENSIONS.has(ext);
}

function slice(full: string, offset: number, maxChars: number, header: string) {
  const part = full.slice(offset, offset + maxChars);
  const end = offset + part.length;
  const more = end < full.length ? `\n\n［內容未完：共 ${full.length} 字，已顯示 ${offset}–${end}。用 offset=${end} 繼續讀。］` : "";
  return text(`${header}\n\n${part}${more}`);
}

export function createServer(graph: Graph): McpServer {
  const server = new McpServer({ name: "onedrive", version: "1.0.0" });

  server.registerTool(
    "onedrive_list",
    {
      title: "列出 OneDrive 資料夾",
      description: "列出 OneDrive 某個資料夾裡的檔案與子資料夾。不給 path 與 item_id 時列出根目錄。",
      inputSchema: {
        ...target,
        limit: z.number().int().min(1).max(200).optional().describe("一次最多幾筆，預設 50。"),
        cursor: z.string().optional().describe("上一次結果的 next_cursor，用來取得下一頁。"),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    guard(async ({ path, item_id, limit, cursor }) => {
      const url = cursor ?? `${itemUrl({ path, item_id }, "/children")}?${SELECT}&$top=${limit ?? 50}&$orderby=name`;
      const page = await graph.json<{ value: DriveItem[]; "@odata.nextLink"?: string }>(url);
      return text({ items: page.value.map(summarize), next_cursor: page["@odata.nextLink"] });
    }),
  );

  server.registerTool(
    "onedrive_search",
    {
      title: "搜尋 OneDrive",
      description: "用關鍵字搜尋整個 OneDrive 的檔案與資料夾（比對檔名與內容）。",
      inputSchema: {
        query: z.string().min(1).describe("搜尋關鍵字。"),
        limit: z.number().int().min(1).max(100).optional().describe("最多幾筆，預設 25。"),
        cursor: z.string().optional().describe("上一次結果的 next_cursor，用來取得下一頁。"),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    guard(async ({ query, limit, cursor }) => {
      const q = encodeURIComponent(query.replace(/'/g, "''"));
      const url = cursor ?? `/me/drive/root/search(q='${q}')?${SELECT}&$top=${limit ?? 25}`;
      const page = await graph.json<{ value: DriveItem[]; "@odata.nextLink"?: string }>(url);
      return text({ items: page.value.map(summarize), next_cursor: page["@odata.nextLink"] });
    }),
  );

  server.registerTool(
    "onedrive_get_item",
    {
      title: "取得檔案資訊",
      description:
        "取得單一檔案或資料夾的詳細資訊。檔案會附上 download_url：不需登入、約一小時內有效的暫時下載連結，可用來下載任何大小與格式的原始檔。",
      inputSchema: target,
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    guard(async (where) => {
      const item = await graph.json<DriveItem>(itemUrl(where));
      return text({ ...summarize(item), download_url: item["@microsoft.graph.downloadUrl"] });
    }),
  );

  server.registerTool(
    "onedrive_read_file",
    {
      title: "讀取檔案內容",
      description:
        "讀取 OneDrive 檔案的內容。文字檔直接回傳文字；Word／PowerPoint／Excel 會抽出文字；圖片回傳圖片（太大或 HEIC 會回傳縮圖）。" +
        "其他格式（例如 PDF、影片）無法直接讀，會回傳暫時下載連結。format=base64 可取得 1 MB 以內任何檔案的原始位元組。",
      inputSchema: {
        ...target,
        format: z.enum(["auto", "base64"]).optional().describe("auto（預設）依檔案類型處理；base64 回傳原始位元組。"),
        offset: z.number().int().min(0).optional().describe("文字從第幾個字開始，預設 0。長檔案分段讀取用。"),
        max_chars: z.number().int().min(1).max(400_000).optional().describe(`最多回傳幾個字，預設 ${DEFAULT_MAX_CHARS}。`),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    guard(async ({ path, item_id, format, offset, max_chars }) => {
      const item = await graph.json<DriveItem>(itemUrl({ path, item_id }));
      if (item.folder) return fail("這是資料夾，請改用 onedrive_list。");
      const size = item.size ?? 0;
      const mime = item.file?.mimeType ?? "application/octet-stream";
      const header = `檔案：${item.name}（${formatSize(size)}，${mime}）`;
      const content = `/me/drive/items/${encodeURIComponent(item.id)}/content`;
      const bytes = async () => new Uint8Array(await (await graph.fetch(content)).arrayBuffer());
      const link = `暫時下載連結（約一小時內有效）：${item["@microsoft.graph.downloadUrl"] ?? "無"}`;

      if (format === "base64") {
        if (size > MAX_BASE64_BYTES) return fail(`${header}\n檔案超過 1 MB，無法以 base64 回傳。\n${link}`);
        return text(`${header}\nbase64:\n${Buffer.from(await bytes()).toString("base64")}`);
      }

      const kind = officeKind(item.name);
      if (kind) {
        if (size > MAX_OFFICE_BYTES) return fail(`${header}\n檔案太大，無法抽取文字。\n${link}`);
        return slice(extractOfficeText(kind, await bytes()), offset ?? 0, max_chars ?? DEFAULT_MAX_CHARS, header);
      }

      if (mime.startsWith("image/") && !mime.includes("svg")) {
        if (INLINE_IMAGE_TYPES.has(mime) && size <= MAX_INLINE_IMAGE_BYTES) {
          return {
            content: [
              { type: "text" as const, text: header },
              { type: "image" as const, data: Buffer.from(await bytes()).toString("base64"), mimeType: mime },
            ],
          };
        }
        const thumbs = await graph.json<{ value: { c1600x1600?: { url: string } }[] }>(
          `/me/drive/items/${encodeURIComponent(item.id)}/thumbnails?select=c1600x1600`,
        );
        const thumbUrl = thumbs.value[0]?.c1600x1600?.url;
        if (!thumbUrl) return fail(`${header}\n無法產生這張圖片的預覽。\n${link}`);
        const thumb = await fetch(thumbUrl);
        if (!thumb.ok) return fail(`${header}\n無法下載圖片預覽。\n${link}`);
        return {
          content: [
            { type: "text" as const, text: `${header}\n（以下是縮小到最長邊 1600 像素的預覽）` },
            {
              type: "image" as const,
              data: Buffer.from(await thumb.arrayBuffer()).toString("base64"),
              mimeType: thumb.headers.get("Content-Type")?.split(";")[0] || "image/jpeg",
            },
          ],
        };
      }

      if (isTextFile(item)) {
        if (size > MAX_TEXT_BYTES) return fail(`${header}\n文字檔超過 5 MB，無法直接讀取。\n${link}`);
        const full = new TextDecoder("utf-8").decode(await bytes());
        return slice(full, offset ?? 0, max_chars ?? DEFAULT_MAX_CHARS, header);
      }

      return text(`${header}\n這種格式無法直接讀成文字。\n${link}`);
    }),
  );

  server.registerTool(
    "onedrive_upload_file",
    {
      title: "上傳檔案到 OneDrive",
      description:
        "把內容存成 OneDrive 上的檔案（上限 4 MB）。預設遇到同名檔案會失敗，不會覆蓋；只有使用者明確要求時才用 if_exists=replace。",
      inputSchema: {
        path: z.string().min(1).describe('要存放的完整路徑（含檔名），例如 "/文件/筆記.md"。上層資料夾必須已存在。'),
        content: z.string().describe("檔案內容。encoding=text 時是文字，base64 時是 base64 編碼的位元組。"),
        encoding: z.enum(["text", "base64"]).optional().describe("content 的編碼，預設 text。"),
        if_exists: z
          .enum(["fail", "rename", "replace"])
          .optional()
          .describe("同名檔案已存在時：fail（預設）失敗、rename 自動改名、replace 覆蓋。"),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    },
    guard(async ({ path, content, encoding, if_exists }) => {
      if (!encodePath(path)) return fail("path 必須包含檔名。");
      const body = encoding === "base64" ? new Uint8Array(Buffer.from(content, "base64")) : new TextEncoder().encode(content);
      if (body.byteLength > MAX_UPLOAD_BYTES) return fail("內容超過 4 MB 上限。");
      const item = await graph.json<DriveItem>(
        `${itemUrl({ path }, "/content")}?@microsoft.graph.conflictBehavior=${if_exists ?? "fail"}`,
        { method: "PUT", headers: { "Content-Type": "application/octet-stream" }, body },
      );
      return text({ uploaded: summarize(item) });
    }),
  );

  server.registerTool(
    "onedrive_create_upload_session",
    {
      title: "建立大檔案上傳連結",
      description:
        "為任何大小的檔案（Word、PDF、圖片等二進位檔，或超過 4 MB 的檔案）建立暫時的上傳連結 upload_url。" +
        "拿到後用 curl 把本機檔案直接 PUT 到 upload_url，檔案內容不必經過工具參數。" +
        "上傳連結不需登入即可寫入這一個檔案，過期前請勿外流。預設不覆蓋同名檔案；只有使用者明確要求時才用 if_exists=replace。",
      inputSchema: {
        path: z.string().min(1).describe('要存放的完整路徑（含檔名），例如 "/文件/報告.docx"。上層資料夾必須已存在。'),
        if_exists: z
          .enum(["fail", "rename", "replace"])
          .optional()
          .describe("同名檔案已存在時：fail（預設）上傳完成時失敗、rename 自動改名、replace 覆蓋。"),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    },
    guard(async ({ path, if_exists }) => {
      if (!encodePath(path)) return fail("path 必須包含檔名。");
      const session = await graph.json<{ uploadUrl: string; expirationDateTime?: string }>(
        itemUrl({ path }, "/createUploadSession"),
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ item: { "@microsoft.graph.conflictBehavior": if_exists ?? "fail" } }),
        },
      );
      return text({
        upload_url: session.uploadUrl,
        expires: session.expirationDateTime,
        how_to_upload: [
          "不要加 Authorization 標頭；upload_url 本身已含授權。",
          "60 MB 以內的檔案一次送完（SIZE 是檔案的位元組數）：",
          'curl -sS -X PUT -H "Content-Range: bytes 0-$((SIZE-1))/$SIZE" --data-binary @檔案 "<upload_url>"',
          "更大的檔案要分段：每段大小必須是 327680 位元組的倍數（最後一段除外），每段各自帶 Content-Range，依序上傳。",
          "回應 201 或 200 並帶有檔案資訊（id、name）表示完成；202 表示還有後續分段；409 表示同名檔案已存在。",
          "要放棄時對 upload_url 送 DELETE。",
        ],
      });
    }),
  );

  server.registerTool(
    "onedrive_create_folder",
    {
      title: "建立 OneDrive 資料夾",
      description: "在 OneDrive 建立新資料夾。同名資料夾已存在時會失敗。",
      inputSchema: {
        parent_path: z.string().optional().describe('上層資料夾的路徑，預設根目錄 "/"。'),
        name: z.string().min(1).describe("新資料夾的名稱。"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    },
    guard(async ({ parent_path, name }) => {
      const item = await graph.json<DriveItem>(itemUrl({ path: parent_path }, "/children"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, folder: {}, "@microsoft.graph.conflictBehavior": "fail" }),
      });
      return text({ created: summarize(item) });
    }),
  );

  return server;
}
