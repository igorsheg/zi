---
slug: authentication
title: Authenticate and choose a model
order: 20
---

# Authenticate and choose a model

Zi can start without configured credentials. No model is selected until a configured provider is available or you provide a runtime override.

## Login in the terminal

```text
/login
```

The login flow asks for a provider and authentication method. API-key entry is hidden in the composer and never shown in the transcript. OAuth providers can show device codes, URLs, prompts, and progress through the same input surface.

Stored credentials go in:

```text
$HOME/.zi/agent/auth.json
```

Zi also supports provider-native environment variables such as `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` through Pi AI.

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

`/model` lists models from configured providers. A fully qualified `provider/model-id` selects directly when it matches. A bare model ID selects directly only when it is unambiguous.

The selected provider and model are persisted together so Zi does not combine a project model with the wrong global provider.

## One-process credentials

For CI, local scripts, or one-off experiments:

```sh
zi --model provider/model-id --api-key "$KEY" "summarize this repo"
```

The key is applied in memory to the selected provider only. It is never written to settings, credentials, events, diagnostics, or session journals. Like any command-line secret, it may still be visible in shell history or process listings.

## First-run behavior

If Zi can infer one configured default, it selects it. Otherwise interactive mode opens with an explicit unselected model and asks you to authenticate or choose a model before provider work starts.

Headless modes require enough configuration to run. Missing-model and authentication diagnostics go to stderr, not stdout.

See [CLI](cli.md) for invocation overrides and [Settings](settings.md) for persisted defaults.
