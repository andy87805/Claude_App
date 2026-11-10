// Microsoft 身分平台（個人帳號）與 Graph API 的底層呼叫。

export interface Env {
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: import("@cloudflare/workers-oauth-provider").OAuthHelpers;
  MS_CLIENT_ID: string;
  MS_CLIENT_SECRET: string;
  /** 允許登入的 Microsoft 帳號 email，逗號分隔。沒設定時一律拒絕。 */
  ALLOWED_EMAILS?: string;
  /** 只供本機測試覆寫，正式環境不要設定。 */
  MS_AUTHORITY?: string;
  GRAPH_BASE?: string;
}

/** 存在 OAuth 授權裡（加密）的資料，工具呼叫時從 ctx.props 取得。 */
export interface Props {
  userId: string;
  name: string;
  email: string;
  msAccessToken: string;
  msRefreshToken: string;
}

export const MS_SCOPES = "Files.ReadWrite User.Read offline_access";

export const authority = (env: Env) =>
  env.MS_AUTHORITY ?? "https://login.microsoftonline.com/consumers/oauth2/v2.0";
export const graphBase = (env: Env) => env.GRAPH_BASE ?? "https://graph.microsoft.com/v1.0";

export function microsoftAuthorizeUrl(
  env: Env,
  opts: { redirectUri: string; state: string; codeChallenge: string },
): string {
  const url = new URL(`${authority(env)}/authorize`);
  url.search = new URLSearchParams({
    client_id: env.MS_CLIENT_ID,
    response_type: "code",
    redirect_uri: opts.redirectUri,
    response_mode: "query",
    scope: MS_SCOPES,
    state: opts.state,
    code_challenge: opts.codeChallenge,
    code_challenge_method: "S256",
    prompt: "select_account",
  }).toString();
  return url.toString();
}

export interface MsTokens {
  accessToken: string;
  refreshToken: string;
}

export class MsTokenError extends Error {
  constructor(
    public code: string,
    message: string,
    public status: number,
  ) {
    super(message);
  }
}

async function tokenRequest(env: Env, params: Record<string, string>, fallbackRefresh?: string): Promise<MsTokens> {
  const res = await fetch(`${authority(env)}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.MS_CLIENT_ID,
      client_secret: env.MS_CLIENT_SECRET,
      scope: MS_SCOPES,
      ...params,
    }),
  });
  const body = (await res.json().catch(() => ({}))) as Record<string, string>;
  if (!res.ok || !body.access_token) {
    throw new MsTokenError(
      body.error ?? "server_error",
      body.error_description ?? `Microsoft token endpoint returned ${res.status}`,
      res.status,
    );
  }
  const refreshToken = body.refresh_token ?? fallbackRefresh;
  if (!refreshToken) throw new MsTokenError("server_error", "Microsoft 沒有回傳 refresh token", 500);
  return { accessToken: body.access_token, refreshToken };
}

export const exchangeCode = (env: Env, code: string, verifier: string, redirectUri: string) =>
  tokenRequest(env, {
    grant_type: "authorization_code",
    code,
    code_verifier: verifier,
    redirect_uri: redirectUri,
  });

export const refreshTokens = (env: Env, refreshToken: string) =>
  tokenRequest(env, { grant_type: "refresh_token", refresh_token: refreshToken }, refreshToken);

export class GraphError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
  ) {
    super(message);
  }
}

/**
 * 帶著使用者權杖呼叫 Graph。權杖過期（401）時用 refresh token 換新的再試一次。
 */
export class Graph {
  constructor(
    private env: Env,
    private props: Props,
  ) {}

  get base() {
    return graphBase(this.env);
  }

  async fetch(pathOrUrl: string, init: RequestInit = {}): Promise<Response> {
    const url = pathOrUrl.startsWith("https://") || pathOrUrl.startsWith("http://") ? pathOrUrl : this.base + pathOrUrl;
    if (!url.startsWith(this.base + "/")) throw new GraphError(400, "invalidRequest", "不是 Graph 的網址");
    const send = () =>
      fetch(url, {
        ...init,
        headers: { ...(init.headers as Record<string, string>), Authorization: `Bearer ${this.props.msAccessToken}` },
      });
    let res = await send();
    if (res.status === 401) {
      const fresh = await refreshTokens(this.env, this.props.msRefreshToken);
      this.props.msAccessToken = fresh.accessToken;
      this.props.msRefreshToken = fresh.refreshToken;
      res = await send();
    }
    if (!res.ok) {
      const body = (await res.json().catch(() => ({}))) as { error?: { code?: string; message?: string } };
      throw new GraphError(res.status, body.error?.code ?? "error", body.error?.message ?? `Graph 回傳 ${res.status}`);
    }
    return res;
  }

  async json<T = any>(pathOrUrl: string, init: RequestInit = {}): Promise<T> {
    return (await this.fetch(pathOrUrl, init)).json() as Promise<T>;
  }
}
