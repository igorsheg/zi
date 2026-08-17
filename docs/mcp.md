---
slug: mcp
title: Use MCP tools without loading every schema
order: 75
---

# Use MCP tools without loading every schema

An MCP server may publish hundreds of tools, but the model usually needs one of them. Sending every discovered schema to the provider on every turn wastes context and makes the useful tool harder to select.

Zi keeps admitted MCP catalogs outside model context and exposes four stable operations through [Code Mode](code-mode.md): `mcp_search`, `mcp_describe`, `mcp_call`, and `mcp_status`. Discovered tools never become direct provider tools, so adding a server does not enlarge the provider-visible tool schema.

## Configure one stdio server

Add a server to global `$HOME/.zi/agent/settings.json` or trusted project `<cwd>/.zi/settings.json`:

```json
{
  "mcpServers": {
    "github": {
      "transport": "stdio",
      "command": ["npx", "-y", "@modelcontextprotocol/server-github"],
      "environmentFrom": ["GITHUB_TOKEN"]
    }
  }
}
```

Global MCP settings are user-admitted. Project MCP settings are executable configuration and stay excluded until Zi admits the project `.zi` directory through [project trust](resources.md#project-trust). Text, JSON, and RPC modes do not open a trust prompt, so unresolved project servers remain excluded.

Enabling an admitted server authorizes the model to call its tools through Code Mode. Zi does not add a separate approval prompt after configuration has already been admitted.

Use `environmentFrom` instead of copying credentials into settings. Zi resolves those names from its captured startup environment, passes only the bounded server environment, and redacts configured sensitive values from status, results, progress, and traces.

## Find and call a tool

Search first, then inspect the selected contract:

```ts
const matches = await zi.mcp_search({ query: "search GitHub source", limit: 5 })
const selected = matches[0]
if (!selected) return "No matching MCP tool"

return { selected, contract: await zi.mcp_describe({ server: selected.server, tool: selected.tool }) }
```

After the model has the contract, call the raw server tool identity:

```ts
return await zi.mcp_call({ server: "github", tool: "search_code", arguments: { query: "McpHost repo:with-zi/zi" } })
```

Each call crosses Zi's ordinary tool seam, so cancellation, deadlines, progress, bounded results, and nested Code Mode traces still apply. `mcp_status` returns the current bounded server states without exposing connection credentials or transport handles.

## Configure Streamable HTTP

Use `streamable-http` for a remote MCP endpoint:

```json
{
  "mcpServers": {
    "internal-search": {
      "transport": "streamable-http",
      "url": "https://mcp.example.com/mcp",
      "headers": { "X-Client": "zi" },
      "headerEnvironment": { "Authorization": "INTERNAL_MCP_AUTHORIZATION" }
    }
  }
}
```

`headerEnvironment` maps an HTTP header name to an environment variable name. Put the complete header value, such as `Bearer token`, in that variable; Zi does not assemble authentication schemes or configure an OAuth provider.

HTTP URLs must use `http:` or `https:` and cannot contain embedded credentials. Response headers, finite bodies, SSE lines, and SSE events are bounded before the SDK can retain them.

## Control startup and calls

Every enabled server accepts the same lifecycle fields:

`required`
: Reject session startup when this server cannot become ready. Optional servers fail independently and leave the session usable.

`startupTimeoutMs`
: Bound initialization and catalog discovery, from 1 ms through 2 minutes. The default is 30 seconds.

`toolTimeoutMs`
: Bound each tool call, from 1 ms through one hour. The default is 60 seconds.

Zi starts or reconnects at most four servers at once and admits at most four catalog refreshes at once. The bounds prevent one server from occupying the session or multiplying uncommitted catalog memory.

| Area         | Bound                                                                   |
| ------------ | ----------------------------------------------------------------------- |
| Servers      | 16 total, including at most 4 stdio servers                             |
| Catalog      | 32 pages, 256 tools per server, and 512 tools total                     |
| Calls        | 16 active calls, with 256 KiB arguments and a 256 KiB projected result  |
| Schemas      | 32 KiB per tool schema and 2 MiB across the ready catalog               |
| HTTP streams | 64 KiB response headers and SSE lines, with 1 MiB bodies and SSE events |

Tool calls are never replayed. A timeout or lost connection may follow an external effect that already happened, so Zi returns the original failure and recovers the connection with a fresh client instead.

HTTP recovery makes at most five fresh-client attempts. Exhausted servers remain failed until settings reload, while SDK request-stream recovery gets two bounded SSE attempts and may resume only through an event ID without replaying the POST.

## Reload configuration

Run `/reload` after changing settings. Zi retains identical ready servers, replaces changed definitions, disables `{ "enabled": false }` entries, removes absent names, and reports bounded failures without restarting the session.

Global and project `mcpServers` maps merge by server name. A higher scope replaces the complete lower-scope definition for that name rather than deep-merging fields:

```json
{ "mcpServers": { "github": { "enabled": false } } }
```

Servers may notify `tools/list_changed`. Zi fetches the complete bounded candidate before replacing the ready catalog, and a failed nonterminal refresh retains the previous catalog instead of publishing a partial result.

## What this does not do

Zi supports MCP tools and `tools/list_changed`. It does not expose MCP prompts, resources, roots, sampling, elicitation, tasks, or Apps.

Zi supports stdio and Streamable HTTP. It does not provide legacy SSE fallback, WebSocket transport, OAuth, dynamic client registration, browser callbacks, or an MCP credential store.

Zi does not discover Claude, Cursor, `.mcp.json`, or other products' configuration. It does not inject server instructions into the system prompt or turn discovered tools into provider-visible direct tools.

Zi does not provide an MCP management screen, add/remove CLI, picker, or per-call approval UI. Configure servers in admitted settings and use bounded startup, reload, and status diagnostics to inspect them.

Subagents do not inherit root MCP connections or server definitions.
