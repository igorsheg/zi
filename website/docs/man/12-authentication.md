---
slug: authentication
title: Authenticate and choose a model
order: 12
---

# Authenticate and choose a model

Zi can start without configured credentials. It keeps that state explicit: no model is selected until a configured provider is available or you provide a runtime override.

## Login in the TUI

```text
/login
```

The login flow asks for a provider and an authentication method. API-key entry is hidden in the composer and never shown in the transcript. OAuth providers can show device codes, URLs, and progress steps through the same prompt surface.

Stored credentials go in:

```text
$HOME/.zi/agent/auth.json
```

## Logout

```text
/logout
```

Logout removes stored credentials for the selected provider. It does not remove environment variables or external provider configuration.

## Pick a model

```text
/model
/model provider/model-id
/model model-id
```

`/model` lists configured provider models. A fully-qualified `provider/model-id` selects directly when it matches. A bare model id selects directly only when it is unambiguous.

The selected provider and model are persisted together so Zi does not accidentally combine a project model with the wrong global provider.

## One-process credentials

For CI, local scripts, or one-off experiments:

```sh
zi --model provider/model-id --api-key "$KEY" "summarize this repo"
```

The key is applied in memory for the selected provider only. It does not create or change `auth.json`.

## First-run behavior

If Zi can infer exactly one configured default, it selects it. If not, interactive mode opens with an explicit unselected model state and asks you to authenticate or choose a model before provider work starts.

Headless modes require enough configuration to run. Missing model or authentication diagnostics go to stderr, not stdout.
