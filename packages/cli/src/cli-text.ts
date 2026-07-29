import { ziVersion } from "./version.js"

export const helpText = `Usage: zi [options] [prompt ...]

Output:
  -p, --print                 Alias for --mode text
      --mode mode             auto, interactive, text, json, or rpc

Runtime:
      --cwd path              Set the effective working directory
      --agent-dir path        Set the global Zi agent directory
      --session-dir path      Set session storage for this invocation
      --model provider/model  Select a model
      --thinking level        off, minimal, low, medium, high, xhigh, or max
      --api-key key           Use a memory-only key for the selected provider
      --system-prompt text    Replace the built-in system prompt
      --append-system-prompt text
                              Append system prompt text; repeatable
      --extension path        Load an explicit extension source; repeatable

Session:
  -r, --resume file           Resume a session file
  -c, --continue              Continue the most recent session
      --new-session           Start a persistent new session
      --no-session            Start an ephemeral new session

Other:
  -h, --help                  Show this help
  -V, --version               Show the Zi version

Environment defaults:
  ZI_MODE                     auto, interactive, text, json, or rpc
  ZI_AGENT_DIR                Global agent directory
  ZI_SESSION_DIR              Session storage directory
  ZI_DEFAULT_MODEL            provider/model selection
  ZI_DEFAULT_THINKING         Default thinking level for this invocation

CLI values override environment defaults. Within argv, the last scalar or
session selector wins; repeatable append-system-prompt values keep their order.
Piped stdin is the first prompt; positional prompts follow in argument order.
Provider credential variables such as ANTHROPIC_API_KEY remain supported.
RPC reads versioned JSONL requests from stdin and writes only protocol frames to stdout.
`

export const versionText = `zi ${ziVersion}\n`
