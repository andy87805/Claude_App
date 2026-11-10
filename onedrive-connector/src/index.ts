// 個人 OneDrive 連接器：跑在 Cloudflare Workers 上的遠端 MCP 伺服器。
//   /mcp        Claude 呼叫工具的端點（需要這個 Worker 發的權杖）
//   /authorize  同意畫面，之後轉到 Microsoft 登入
//   /callback   Microsoft 登入完成後回來的地方

import { OAuthError, OAuthProvider } from "@cloudflare/workers-oauth-provider";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { defaultHandler } from "./auth";
import { type Env, Graph, MsTokenError, type Props, refreshTokens } from "./microsoft";
import { createServer } from "./tools";

const mcpHandler: ExportedHandler<Env> = {
  async fetch(request, env, ctx) {
    const props = (ctx as ExecutionContext & { props: Props }).props;
    // 無狀態：每個請求建立新的伺服器，不需要 Durable Objects。
    const server = createServer(new Graph(env, { ...props }));
    const transport = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    await server.connect(transport);
    return transport.handleRequest(request);
  },
};

// 這個 Worker 的網址要部署後才知道，所以依請求的網域建立（並快取）OAuth 提供者。
const providers = new Map<string, OAuthProvider<Env>>();

function providerFor(origin: string): OAuthProvider<Env> {
  let provider = providers.get(origin);
  if (!provider) {
    provider = buildProvider(origin);
    providers.set(origin, provider);
  }
  return provider;
}

const buildProvider = (origin: string) => new OAuthProvider<Env>({
  resourceMetadata: { resource: `${origin}/mcp`, authorization_servers: [origin] },
  apiRoute: "/mcp",
  apiHandler: mcpHandler as any,
  defaultHandler: defaultHandler as any,
  authorizeEndpoint: "/authorize",
  tokenEndpoint: "/token",
  clientRegistrationEndpoint: "/register",
  // Microsoft 的存取權杖約一小時到期；我們的權杖早一點到期，
  // Claude 來換新權杖時順便把 Microsoft 的也換新。
  accessTokenTTL: 45 * 60,
  tokenExchangeCallback: async ({ grantType, props, env }) => {
    if (grantType !== "refresh_token") return;
    try {
      const fresh = await refreshTokens(env, (props as Props).msRefreshToken);
      return { newProps: { ...props, msAccessToken: fresh.accessToken, msRefreshToken: fresh.refreshToken } };
    } catch (error) {
      if (error instanceof MsTokenError && error.code === "invalid_grant") {
        // 使用者在 Microsoft 那邊撤銷了授權：讓 Claude 重新走一次登入。
        throw new OAuthError("invalid_grant", { description: "Microsoft 授權已失效，請重新連接。" });
      }
      throw new OAuthError("temporarily_unavailable", { description: "暫時無法連到 Microsoft。", statusCode: 503 });
    }
  },
});

export default {
  fetch(request, env, ctx) {
    return providerFor(new URL(request.url).origin).fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
