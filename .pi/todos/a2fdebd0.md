{
"id": "a2fdebd0",
"title": "Add non-persistent CLI API-key override",
"tags": [
"cli",
"coding-agent",
"auth",
"tdd"
],
"status": "closed",
"created_at": "2026-07-15T12:06:54.051Z"
}

Implemented `--api-key` parsing/help and runtime plumbing. The override requires an explicit or settings-inferred model, marks only that provider configured, and is applied via Pi AI's explicit stream option so it wins over stored/ambient auth. It never mutates settings or credentials; provider listing avoids credential reads for the overridden provider, so key-only startup creates no auth file. Tests prove request precedence, unchanged stored credentials, no disk persistence, fresh-runtime disappearance, missing-model errors without key disclosure, and CLI parsing.
