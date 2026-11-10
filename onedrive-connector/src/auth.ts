// 非 /mcp 的頁面：同意畫面（/authorize）與 Microsoft 登入後的回呼（/callback）。

import {
  AuthorizationError,
  CimdFetchError,
  authorizationErrorRedirect,
  type ConsentDescription,
} from "@cloudflare/workers-oauth-provider";
import { type Env, type Props, exchangeCode, graphBase, microsoftAuthorizeUrl, MsTokenError } from "./microsoft";

const escapeHtml = (value: string) => value.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);

function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="zh-Hant">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 17px/1.6 -apple-system, "PingFang TC", "Noto Sans TC", system-ui, sans-serif;
         margin: 0; padding: 24px 16px; background: Canvas; color: CanvasText; }
  main { max-width: 440px; margin: 8vh auto 0; }
  h1 { font-size: 22px; line-height: 1.35; margin: 0 0 12px; }
  p { margin: 0 0 12px; }
  .note { font-size: 15px; opacity: .75; }
  .warn { padding: 10px 12px; border-radius: 10px; background: #f5a62333; }
  ul { padding-left: 1.2em; margin: 0 0 16px; }
  .actions { display: flex; gap: 12px; margin-top: 20px; }
  button { flex: 1; font: inherit; font-weight: 600; padding: 12px; border-radius: 12px;
           border: 1px solid #8886; background: transparent; color: inherit; cursor: pointer; }
  button.primary { background: #0a66d8; border-color: #0a66d8; color: #fff; }
</style>
<main>${body}</main>
</html>`;
}

const html = (title: string, body: string, status = 200, headers = new Headers()) => {
  headers.set("Content-Type", "text/html; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  return new Response(page(title, body), { status, headers });
};

const errorPage = (message: string, status = 400) =>
  html("無法完成授權", `<h1>無法完成授權</h1><p>${escapeHtml(message)}</p><p class="note">請回到 Claude 重新連接一次。</p>`, status);

function consentPage(details: ConsentDescription, handle: string): string {
  const name = escapeHtml(details.clientName || "未命名的應用程式");
  const origin = details.clientDomain
    ? `由 <strong>${escapeHtml(details.clientDomain)}</strong> 發布。`
    : "這個應用程式是自行註冊的，名稱未經驗證。";
  return `<h1>要讓「${name}」存取你的 OneDrive 嗎？</h1>
<p>${origin}存取權會送到 <strong>${escapeHtml(details.redirectHost)}</strong>。</p>
${details.redirectIsLoopback ? '<p class="warn">這會把存取權交給<strong>你電腦上的程式</strong>。只有在你剛剛從那個程式開始登入時才繼續。</p>' : ""}
<p>允許之後，它可以：</p>
<ul>
  <li>列出、搜尋、讀取你 OneDrive 裡的檔案</li>
  <li>上傳檔案、建立資料夾</li>
</ul>
<p class="note">下一步會請你登入 Microsoft 帳號。這個連接器沒有刪除檔案的功能。</p>
<form method="post">
  <input type="hidden" name="handle" value="${escapeHtml(handle)}">
  <div class="actions">
    <button name="decision" value="deny">拒絕</button>
    <button class="primary" name="decision" value="approve">允許</button>
  </div>
</form>`;
}

async function s256(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

const callbackUrl = (req: Request) => new URL("/callback", req.url).toString();

function allowedEmails(env: Env): string[] {
  return (env.ALLOWED_EMAILS ?? "")
    .split(",")
    .map((email) => email.trim().toLowerCase())
    .filter(Boolean);
}

async function showConsent(req: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  const request = await oauth.parseAuthRequest(req);
  const details = await oauth.describeConsent(request);
  const consent = await oauth.beginConsent(request);
  return html("授權存取 OneDrive", consentPage(details, consent.handle), 200, consent.headers);
}

async function submitConsent(req: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  const form = await req.formData();
  const handle = String(form.get("handle") ?? "");
  if (form.get("decision") !== "approve") {
    const denied = await oauth.denyConsent(req, handle);
    return new Response(null, { status: 302, headers: denied.headers });
  }
  const approved = await oauth.approveConsent(req, handle);
  const verifier = crypto.randomUUID() + crypto.randomUUID();
  const { state, headers } = await oauth.beginUpstream(approved.request, {
    data: { verifier },
    headers: approved.headers,
  });
  headers.set(
    "Location",
    microsoftAuthorizeUrl(env, { redirectUri: callbackUrl(req), state, codeChallenge: await s256(verifier) }),
  );
  return new Response(null, { status: 302, headers });
}

async function callback(req: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  const params = new URL(req.url).searchParams;
  const { request: original, data, headers } = await oauth.finishUpstream<{ verifier: string }>(req);

  const code = params.get("code");
  if (params.get("error") || !code) {
    headers.set("Location", authorizationErrorRedirect(original, "access_denied"));
    return new Response(null, { status: 302, headers });
  }

  const tokens = await exchangeCode(env, code, data.verifier, callbackUrl(req));
  const meRes = await fetch(`${graphBase(env)}/me?$select=id,displayName,mail,userPrincipalName`, {
    headers: { Authorization: `Bearer ${tokens.accessToken}` },
  });
  if (!meRes.ok) return errorPage("無法取得 Microsoft 帳號資料。", 502);
  const me = (await meRes.json()) as { id: string; displayName?: string; mail?: string; userPrincipalName?: string };

  const emails = [me.mail, me.userPrincipalName].filter(Boolean).map((email) => email!.toLowerCase());
  if (!emails.some((email) => allowedEmails(env).includes(email))) {
    return errorPage(`這個 Microsoft 帳號（${emails[0] ?? "未知"}）不在允許名單內。`, 403);
  }

  const props: Props = {
    userId: me.id,
    name: me.displayName ?? "",
    email: emails[0],
    msAccessToken: tokens.accessToken,
    msRefreshToken: tokens.refreshToken,
  };
  const { redirectTo } = await oauth.completeAuthorization({
    request: original,
    userId: me.id,
    metadata: { email: props.email },
    scope: original.scope,
    props,
  });
  headers.set("Location", redirectTo);
  return new Response(null, { status: 302, headers });
}

export const defaultHandler: ExportedHandler<Env> = {
  async fetch(req, env) {
    const { pathname } = new URL(req.url);
    try {
      if (pathname === "/authorize" || pathname === "/callback") {
        if (!env.MS_CLIENT_ID || !env.MS_CLIENT_SECRET) {
          return errorPage("連接器尚未設定 MS_CLIENT_ID／MS_CLIENT_SECRET。", 500);
        }
        if (allowedEmails(env).length === 0) {
          return errorPage("連接器尚未設定 ALLOWED_EMAILS（允許登入的 Microsoft 帳號）。", 500);
        }
        if (pathname === "/callback" && req.method === "GET") return await callback(req, env);
        if (pathname === "/authorize" && req.method === "GET") return await showConsent(req, env);
        if (pathname === "/authorize" && req.method === "POST") return await submitConsent(req, env);
        return new Response("Method Not Allowed", { status: 405 });
      }
      if (pathname === "/") {
        return html(
          "OneDrive 連接器",
          `<h1>OneDrive 連接器運作中</h1><p>在 Claude 的連接器設定加入這個網址：</p><p><code>${escapeHtml(new URL("/mcp", req.url).toString())}</code></p>`,
        );
      }
      return new Response("Not Found", { status: 404 });
    } catch (error) {
      if (error instanceof AuthorizationError && error.redirectTo) {
        return Response.redirect(error.redirectTo, 302);
      }
      if (error instanceof AuthorizationError) return errorPage(error.description || "授權請求無效或已過期。");
      if (error instanceof CimdFetchError) return errorPage("無法驗證這個應用程式。");
      if (error instanceof MsTokenError) return errorPage(`Microsoft 登入失敗：${error.message}`, 502);
      throw error;
    }
  },
};
