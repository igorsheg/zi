---
slug: webview
title: WebView
order: 35
aliases:
  - native webview
  - ctx.webview
  - webview extensions
---

# WebView

`ctx.webview` lets an extension open a small native WebView window and expose an explicit Lua bridge. It is currently macOS-only. On other platforms, `ctx.webview.open` returns an unsupported-platform error.

Keep WebViews focused: render HTML, call named bridge commands, return small JSON-compatible results.

## Open a window

```lua
ctx.webview.open({
  id = "demo",
  title = "Demo",
  width = 900,
  height = 700,

  html = html,
  -- or:
  -- asset_root = ctx.extension.root .. "/ui/dist",
  -- entry = "index.html",

  bridge = {
    commands = {
      ping = {
        permissions = { "demo.ping" }, -- metadata today
        handler = function(payload, call_ctx)
          return { ok = true, pong = payload }
        end,
      },
    },
  },
})
```

Options:

`id`
: Required stable window id. Reusing an id replaces the previous window.

`title`
: Optional window title.

`width`, `height`
: Optional size in pixels.

`floating`
: Optional boolean. Requests a floating window.

`html`
: Inline HTML string. Limited to 4 MiB.

`asset_root`, `entry`
: Load a file from an extension-owned directory instead of inline HTML. `entry` must be relative, non-empty, and must not contain `..`.

`bridge.commands`
: Map of JavaScript-callable command names to handlers. Only registered commands are callable.

## JavaScript API

The page receives `window.zi`:

```js
const result = await window.zi.invoke("ping", { hello: "world" });
window.zi.close();
```

`invoke(name, payload)` sends JSON-compatible payload data to the matching Lua handler and resolves with the handler result. If the command is unknown, payload is invalid, the handler errors, or the response is too large, the promise rejects.

`close()` asks the native host to close the window.

## Security model

Treat WebView payloads as untrusted input. Validate all fields in Lua handlers before using editor, session, filesystem, or process APIs.

The bridge allowlist is the authority boundary: JavaScript can only call command names registered in `bridge.commands`. The `permissions` list is descriptive metadata for now; it is not an enforced permission system.

Avoid remote content unless the extension owns the risk. Prefer bundled assets or inline generated HTML.

## Limits

Current core limits:

- inline HTML: 4 MiB
- bridge request JSON: 1 MiB
- bridge response JSON: 1 MiB
- host event line: 2 MiB
- window ids and command names: 128 bytes

Oversized host lines are dropped. Oversized bridge requests or responses fail the bridge call.

## Demo and debugging

The bundled demo extension supports deterministic smoke testing:

```text
/webview-demo
/webview-demo smoke
/webview-demo generate build a tiny pomodoro dashboard
```

`/webview-demo` and `/webview-demo smoke` open static HTML immediately. `generate` asks the current model for HTML before opening the window.

Core WebView logging is off by default. Set `ZI_WEBVIEW_DEBUG=1` to write `/tmp/zi-webview-core.log`. The demo extension also writes `/tmp/zi-webview-demo.log`.
