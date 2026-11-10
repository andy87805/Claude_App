// 端對端測試：在本機啟動真正的 Worker（wrangler dev）與假的 Microsoft，
// 扮演 Claude 走完「註冊 → 同意 → 登入 → 換權杖 → 呼叫工具」整個流程。
import { spawn, type ChildProcess } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
// @ts-expect-error 純 JS 的測試輔助程式
import { startMock } from "./mock-microsoft.mjs";

const WORKER_PORT = 8791;
const MOCK_PORT = 8792;
const WORKER = `http://localhost:${WORKER_PORT}`;
const REDIRECT = "https://claude.example/api/mcp/auth_callback";

let worker: ChildProcess;
let mock: Awaited<ReturnType<typeof startMock>>;

beforeAll(async () => {
  mock = await startMock(MOCK_PORT);
  await expect(fetch(WORKER), `連接埠 ${WORKER_PORT} 已被占用`).rejects.toThrow();
  worker = spawn(
    "npx",
    [
      "wrangler", "dev", "--port", String(WORKER_PORT), "--local", "--show-interactive-dev-session=false",
      "--var", "MS_CLIENT_ID:test-client",
      "--var", "MS_CLIENT_SECRET:test-secret",
      "--var", "ALLOWED_EMAILS:Owner@outlook.com",
      "--var", `MS_AUTHORITY:${mock.base}/auth`,
      "--var", `GRAPH_BASE:${mock.base}/graph`,
      "--persist-to", `.wrangler/e2e-${Date.now()}`,
    ],
    { stdio: "pipe", detached: true, env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" } },
  );
  let log = "";
  worker.stdout!.on("data", (chunk) => (log += chunk));
  worker.stderr!.on("data", (chunk) => (log += chunk));
  for (let i = 0; i < 120; i++) {
    try {
      if ((await fetch(WORKER)).ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`wrangler dev 沒有啟動：\n${log}`);
}, 90_000);

afterAll(() => {
  // wrangler 會再開子行程（workerd），所以要整組一起結束。
  if (worker?.pid) process.kill(-worker.pid, "SIGTERM");
  mock?.server.close();
});

/** 把回應的 Set-Cookie 整理成下一個請求的 Cookie 標頭。 */
const cookies = (res: Response, jar: Record<string, string> = {}) => {
  for (const line of res.headers.getSetCookie()) {
    const [pair] = line.split(";");
    const index = pair.indexOf("=");
    jar[pair.slice(0, index)] = pair.slice(index + 1);
  }
  return jar;
};
const cookieHeader = (jar: Record<string, string>) =>
  Object.entries(jar)
    .map(([name, value]) => `${name}=${value}`)
    .join("; ");

interface Session {
  accessToken: string;
  refreshToken: string;
  clientId: string;
}

async function register(): Promise<string> {
  const res = await fetch(`${WORKER}/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      client_name: "Claude <測試>",
      redirect_uris: [REDIRECT],
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
    }),
  });
  expect(res.status).toBe(201);
  return ((await res.json()) as { client_id: string }).client_id;
}

function authorizeUrl(clientId: string, verifier: string) {
  const url = new URL(`${WORKER}/authorize`);
  url.search = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: REDIRECT,
    state: "claude-state",
    code_challenge: createHash("sha256").update(verifier).digest("base64url"),
    code_challenge_method: "S256",
    resource: `${WORKER}/mcp`,
  }).toString();
  return url;
}

async function signIn(): Promise<Session> {
  const clientId = await register();
  const verifier = randomBytes(32).toString("base64url");

  // 同意畫面
  const consent = await fetch(authorizeUrl(clientId, verifier));
  expect(consent.status).toBe(200);
  const page = await consent.text();
  expect(page).toContain("Claude &#60;測試&#62;"); // 用戶端名稱有跳脫
  expect(page).toContain("claude.example");
  expect(consent.headers.get("Content-Security-Policy")).toContain("frame-ancestors 'none'");
  const handle = page.match(/name="handle" value="([^"]+)"/)![1];
  const jar = cookies(consent);

  // 按下「允許」→ 轉到 Microsoft
  const approve = await fetch(`${WORKER}/authorize`, {
    method: "POST",
    redirect: "manual",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookieHeader(jar) },
    body: new URLSearchParams({ handle, decision: "approve" }),
  });
  expect(approve.status).toBe(302);
  const toMicrosoft = new URL(approve.headers.get("Location")!);
  expect(toMicrosoft.pathname).toBe("/auth/authorize");
  expect(toMicrosoft.searchParams.get("scope")).toBe("Files.ReadWrite User.Read offline_access");
  expect(toMicrosoft.searchParams.get("redirect_uri")).toBe(`${WORKER}/callback`);
  cookies(approve, jar);

  // Microsoft 登入完成 → 回到 /callback → 回到 Claude
  const microsoft = await fetch(toMicrosoft, { redirect: "manual" });
  const callback = await fetch(microsoft.headers.get("Location")!, {
    redirect: "manual",
    headers: { Cookie: cookieHeader(jar) },
  });
  expect(callback.status).toBe(302);
  const back = new URL(callback.headers.get("Location")!);
  expect(back.origin + back.pathname).toBe(REDIRECT);
  expect(back.searchParams.get("state")).toBe("claude-state");

  const token = await fetch(`${WORKER}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: back.searchParams.get("code")!,
      client_id: clientId,
      redirect_uri: REDIRECT,
      code_verifier: verifier,
    }),
  });
  expect(token.status).toBe(200);
  const tokens = (await token.json()) as { access_token: string; refresh_token: string };
  return { accessToken: tokens.access_token, refreshToken: tokens.refresh_token, clientId };
}

let rpcId = 0;
async function rpc(session: Session, method: string, params: unknown = {}) {
  const res = await fetch(`${WORKER}/mcp`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      Authorization: `Bearer ${session.accessToken}`,
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });
  expect(res.status).toBe(200);
  const body = (await res.json()) as { result?: any; error?: any };
  expect(body.error).toBeUndefined();
  return body.result;
}

const call = (session: Session, name: string, args: Record<string, unknown> = {}) =>
  rpc(session, "tools/call", { name, arguments: args });

describe("OAuth", () => {
  it("公告探索文件", async () => {
    const resource = (await (await fetch(`${WORKER}/.well-known/oauth-protected-resource/mcp`)).json()) as any;
    expect(resource.resource).toBe(`${WORKER}/mcp`);
    const server = (await (await fetch(`${WORKER}/.well-known/oauth-authorization-server`)).json()) as any;
    expect(server.authorization_endpoint).toBe(`${WORKER}/authorize`);
    expect(server.registration_endpoint).toBe(`${WORKER}/register`);
    expect(server.code_challenge_methods_supported).toContain("S256");
  });

  it("沒有權杖時 /mcp 回 401", async () => {
    const res = await fetch(`${WORKER}/mcp`, { method: "POST", body: "{}" });
    expect(res.status).toBe(401);
    expect(res.headers.get("WWW-Authenticate")).toContain("resource_metadata");
  });

  it("沒有同一個瀏覽器的 cookie 就不能送出同意", async () => {
    const consent = await fetch(authorizeUrl(await register(), "v".repeat(43)));
    const handle = (await consent.text()).match(/name="handle" value="([^"]+)"/)![1];
    const forged = await fetch(`${WORKER}/authorize`, {
      method: "POST",
      redirect: "manual",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ handle, decision: "approve" }),
    });
    expect(forged.status).toBe(400);
  });

  it("按「拒絕」會帶著 access_denied 回到 Claude", async () => {
    const consent = await fetch(authorizeUrl(await register(), "v".repeat(43)));
    const handle = (await consent.text()).match(/name="handle" value="([^"]+)"/)![1];
    const denied = await fetch(`${WORKER}/authorize`, {
      method: "POST",
      redirect: "manual",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookieHeader(cookies(consent)) },
      body: new URLSearchParams({ handle, decision: "deny" }),
    });
    expect(denied.status).toBe(302);
    expect(new URL(denied.headers.get("Location")!).searchParams.get("error")).toBe("access_denied");
  });
});

describe("工具", () => {
  let session: Session;
  beforeAll(async () => {
    session = await signIn();
    const init = await rpc(session, "initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "test", version: "1" },
    });
    expect(init.serverInfo.name).toBe("onedrive");
  });

  it("列出六個工具，沒有刪除功能", async () => {
    const { tools } = await rpc(session, "tools/list");
    expect(tools.map((tool: any) => tool.name).sort()).toEqual([
      "onedrive_create_folder",
      "onedrive_get_item",
      "onedrive_list",
      "onedrive_read_file",
      "onedrive_search",
      "onedrive_upload_file",
    ]);
  });

  it("列出根目錄與子資料夾", async () => {
    const root = JSON.parse((await call(session, "onedrive_list")).content[0].text);
    expect(root.items).toEqual([expect.objectContaining({ name: "文件", type: "folder", path: "/文件", children: 5 })]);
    const docs = JSON.parse((await call(session, "onedrive_list", { path: "/文件" })).content[0].text);
    expect(docs.items).toHaveLength(5);
    expect(docs.items[0]).toMatchObject({ name: "筆記.txt", type: "file", path: "/文件/筆記.txt", id: "f-note" });
  });

  it("搜尋時跳脫單引號", async () => {
    const result = JSON.parse((await call(session, "onedrive_search", { query: "it's" })).content[0].text);
    expect(result.items[0].name).toBe("筆記.txt");
    expect(mock.state.lastSearch).toContain("search(q='it''s')");
  });

  it("取得檔案資訊與下載連結", async () => {
    const info = JSON.parse((await call(session, "onedrive_get_item", { item_id: "f-pdf" })).content[0].text);
    expect(info).toMatchObject({ name: "合約.pdf", download_url: `${mock.base}/download/f-pdf` });
  });

  it("讀取文字檔，支援分段", async () => {
    const full = await call(session, "onedrive_read_file", { path: "/文件/筆記.txt" });
    expect(full.content[0].text).toContain("哈囉 OneDrive\n第二行");
    const part = await call(session, "onedrive_read_file", { item_id: "f-note", max_chars: 2 });
    expect(part.content[0].text).toContain("哈囉");
    expect(part.content[0].text).toContain("offset=2");
    expect(part.content[0].text).not.toContain("OneDrive\n");
  });

  it("抽出 Word 與 Excel 的文字", async () => {
    const word = await call(session, "onedrive_read_file", { item_id: "f-doc" });
    expect(word.content[0].text).toContain("第一段 A&B\n第二段");
    const excel = await call(session, "onedrive_read_file", { item_id: "f-xls" });
    expect(excel.content[0].text).toContain("工作表：預算");
    expect(excel.content[0].text).toContain("項目\t金額\n房租\t\t12000");
  });

  it("圖片回傳圖片內容", async () => {
    const image = await call(session, "onedrive_read_file", { item_id: "f-img" });
    expect(image.content[1]).toMatchObject({ type: "image", mimeType: "image/png" });
    expect(image.content[1].data.startsWith("iVBOR")).toBe(true);
  });

  it("PDF 回傳下載連結；base64 回傳原始位元組", async () => {
    const pdf = await call(session, "onedrive_read_file", { item_id: "f-pdf" });
    expect(pdf.content[0].text).toContain(`${mock.base}/download/f-pdf`);
    const raw = await call(session, "onedrive_read_file", { item_id: "f-pdf", format: "base64" });
    expect(raw.content[0].text).toContain(Buffer.from("%PDF-1.4").toString("base64"));
  });

  it("找不到檔案時回報錯誤而不是當掉", async () => {
    const missing = await call(session, "onedrive_read_file", { path: "/文件/沒有.txt" });
    expect(missing.isError).toBe(true);
    expect(missing.content[0].text).toContain("找不到");
  });

  it("上傳檔案：預設不覆蓋", async () => {
    const ok = await call(session, "onedrive_upload_file", { path: "/文件/新 檔.md", content: "內容" });
    expect(JSON.parse(ok.content[0].text).uploaded.name).toBe("新 檔.md");
    expect(mock.state.uploads.at(-1)).toEqual({ path: "文件/新 檔.md", behavior: "fail", body: "內容" });

    const conflict = await call(session, "onedrive_upload_file", { path: "/文件/已存在.txt", content: "x" });
    expect(conflict.isError).toBe(true);

    await call(session, "onedrive_upload_file", {
      path: "/文件/已存在.txt",
      content: Buffer.from("位元組").toString("base64"),
      encoding: "base64",
      if_exists: "replace",
    });
    expect(mock.state.uploads.at(-1)).toEqual({ path: "文件/已存在.txt", behavior: "replace", body: "位元組" });
  });

  it("拒絕含 .. 的路徑與非 Graph 的 cursor", async () => {
    const traversal = await call(session, "onedrive_list", { path: "/文件/../秘密" });
    expect(traversal.isError).toBe(true);
    const before = mock.state.calls.length;
    const ssrf = await call(session, "onedrive_list", { cursor: `${mock.base}/download/f-note` });
    expect(ssrf.isError).toBe(true);
    expect(mock.state.calls.length).toBe(before); // 沒有把權杖送到別的網址
  });

  it("建立資料夾", async () => {
    const made = await call(session, "onedrive_create_folder", { parent_path: "/文件", name: "新資料夾" });
    expect(JSON.parse(made.content[0].text).created).toMatchObject({ name: "新資料夾", type: "folder" });
    expect(mock.state.folders.at(-1)).toMatchObject({ name: "新資料夾", "@microsoft.graph.conflictBehavior": "fail" });
  });

  it("Microsoft 權杖過期時自動換新", async () => {
    mock.state.expireFirstToken = true;
    const root = await call(session, "onedrive_list");
    expect(root.isError).toBeUndefined();

    // Claude 換新權杖時，Microsoft 的權杖也一起換新並存起來。
    const refreshed = await fetch(`${WORKER}/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: session.refreshToken,
        client_id: session.clientId,
      }),
    });
    expect(refreshed.status).toBe(200);
    const next = { ...session, accessToken: ((await refreshed.json()) as any).access_token };
    const tokenCalls = mock.state.calls.filter((entry: string) => entry === "POST /auth/token").length;
    expect((await call(next, "onedrive_list")).isError).toBeUndefined();
    expect(mock.state.calls.filter((entry: string) => entry === "POST /auth/token").length).toBe(tokenCalls);
    mock.state.expireFirstToken = false;
  });
});

describe("允許名單", () => {
  it("不在 ALLOWED_EMAILS 的帳號被拒絕", async () => {
    mock.state.email = "stranger@outlook.com";
    await expect(signIn()).rejects.toThrow(); // /callback 回 403 而不是 302
    mock.state.email = "owner@outlook.com";
    await expect(signIn()).resolves.toBeDefined();
  });
});
