// 假的 Microsoft 登入＋Graph 伺服器，只供端對端測試使用。
import { createServer } from "node:http";
import { zipSync, strToU8 } from "fflate";

export const ACCESS_1 = "ms-access-1";
export const ACCESS_2 = "ms-access-2";
export const REFRESH = "ms-refresh";

const docx = zipSync({
  "word/document.xml": strToU8(
    `<w:document><w:body><w:p><w:r><w:t>第一段 A&amp;B</w:t></w:r></w:p><w:p><w:r><w:t xml:space="preserve">第二段</w:t></w:r></w:p></w:body></w:document>`,
  ),
});
const xlsx = zipSync({
  "xl/workbook.xml": strToU8(`<workbook><sheets><sheet name="預算" sheetId="1" r:id="rId1"/></sheets></workbook>`),
  "xl/sharedStrings.xml": strToU8(`<sst><si><t>項目</t></si><si><t>金額</t></si></sst>`),
  "xl/worksheets/sheet1.xml": strToU8(
    `<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>房租</t></is></c><c r="C2"><v>12000</v></c></row></sheetData></worksheet>`,
  ),
});
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
  "base64",
);

const files = new Map([
  ["f-note", { name: "筆記.txt", mime: "text/plain", data: Buffer.from("哈囉 OneDrive\n第二行") }],
  ["f-doc", { name: "報告.docx", mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", data: Buffer.from(docx) }],
  ["f-xls", { name: "預算.xlsx", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", data: Buffer.from(xlsx) }],
  ["f-img", { name: "圖.png", mime: "image/png", data: png }],
  ["f-pdf", { name: "合約.pdf", mime: "application/pdf", data: Buffer.from("%PDF-1.4") }],
]);

const item = (id, base) => {
  const file = files.get(id);
  return {
    id,
    name: file.name,
    size: file.data.length,
    lastModifiedDateTime: "2026-11-01T00:00:00Z",
    file: { mimeType: file.mime },
    parentReference: { path: "/drive/root:/%E6%96%87%E4%BB%B6" },
    "@microsoft.graph.downloadUrl": `${base}/download/${id}`,
  };
};

export function startMock(port, { email = "owner@outlook.com" } = {}) {
  const state = { email, expireFirstToken: false, uploads: [], folders: [], calls: [] };
  const base = `http://127.0.0.1:${port}`;

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, base);
    const path = decodeURIComponent(url.pathname);
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const json = (status, data) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(data));
    };
    state.calls.push(`${req.method} ${path}`);

    // --- 登入 ---
    if (path === "/auth/authorize") {
      const back = new URL(url.searchParams.get("redirect_uri"));
      back.searchParams.set("code", "ms-code");
      back.searchParams.set("state", url.searchParams.get("state"));
      res.writeHead(302, { Location: back.toString() });
      return res.end();
    }
    if (path === "/auth/token") {
      const form = new URLSearchParams(body.toString());
      if (form.get("client_secret") !== "test-secret") return json(401, { error: "invalid_client" });
      if (form.get("grant_type") === "authorization_code") {
        if (form.get("code") !== "ms-code" || !form.get("code_verifier")) return json(400, { error: "invalid_grant" });
        return json(200, { access_token: ACCESS_1, refresh_token: REFRESH });
      }
      if (form.get("refresh_token") !== REFRESH) return json(400, { error: "invalid_grant" });
      return json(200, { access_token: ACCESS_2, refresh_token: REFRESH });
    }

    if (path.startsWith("/download/")) {
      res.writeHead(200);
      return res.end(files.get(path.slice("/download/".length)).data);
    }

    // --- Graph ---
    if (!path.startsWith("/graph/")) return json(404, { error: { code: "notFound", message: "no route" } });
    const token = (req.headers.authorization ?? "").replace("Bearer ", "");
    const valid = token === ACCESS_2 || (token === ACCESS_1 && !state.expireFirstToken);
    if (!valid) return json(401, { error: { code: "InvalidAuthenticationToken", message: "expired" } });
    const p = path.slice("/graph".length);

    if (p === "/me") return json(200, { id: "user-1", displayName: "測試者", userPrincipalName: state.email });
    if (p === "/me/drive/root/children" && req.method === "GET") {
      return json(200, { value: [{ id: "d-docs", name: "文件", folder: { childCount: 5 }, parentReference: { path: "/drive/root:" } }] });
    }
    if (p === "/me/drive/root:/文件:/children" && req.method === "GET") {
      return json(200, { value: [...files.keys()].map((id) => item(id, base)) });
    }
    if (p.startsWith("/me/drive/root/search(q='")) {
      state.lastSearch = p;
      return json(200, { value: [item("f-note", base)] });
    }
    if (p === "/me/drive/root:/文件:/children" && req.method === "POST") {
      const data = JSON.parse(body.toString());
      state.folders.push(data);
      return json(201, { id: "d-new", name: data.name, folder: { childCount: 0 }, parentReference: { path: "/drive/root:/%E6%96%87%E4%BB%B6" } });
    }
    const upload = p.match(/^\/me\/drive\/root:\/(.+):\/content$/);
    if (upload && req.method === "PUT") {
      const behavior = url.searchParams.get("@microsoft.graph.conflictBehavior");
      if (upload[1].endsWith("已存在.txt") && behavior === "fail") {
        return json(409, { error: { code: "nameAlreadyExists", message: "exists" } });
      }
      state.uploads.push({ path: upload[1], behavior, body: body.toString() });
      return json(201, { id: "f-up", name: upload[1].split("/").pop(), size: body.length, file: { mimeType: "text/plain" }, parentReference: { path: "/drive/root:/%E6%96%87%E4%BB%B6" } });
    }
    const byPath = p.match(/^\/me\/drive\/root:\/文件\/(.+)$/);
    if (byPath) {
      const found = [...files.entries()].find(([, file]) => file.name === byPath[1]);
      return found ? json(200, item(found[0], base)) : json(404, { error: { code: "itemNotFound", message: "not found" } });
    }
    const byId = p.match(/^\/me\/drive\/items\/([^/]+)(\/content)?$/);
    if (byId && files.has(byId[1])) {
      if (!byId[2]) return json(200, item(byId[1], base));
      res.writeHead(302, { Location: `${base}/download/${byId[1]}` });
      return res.end();
    }
    return json(404, { error: { code: "itemNotFound", message: "not found" } });
  });

  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve({ server, state, base })));
}
