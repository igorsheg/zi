{
"id": "6bcafdd8",
"title": "Unify model construction with credential ownership",
"tags": [
"coding-agent",
"auth",
"models",
"runtime",
"tdd"
],
"status": "closed",
"created_at": "2026-07-15T12:06:54.051Z"
}

Implemented runtime modelFactory(credentials) as the production construction contract and removed raw Models injection from CreateAgentRuntimeOptions. Added an explicitly test-only detached-model adapter. FileCredentialStore now provides redacted sorted listing and bounds auth.json to 1 MiB, 256 providers, 128-character provider ids, and bounded serialized writes without overwrite on failure. Tests prove the model factory receives the exact runtime credential owner and writes are immediately visible through Models.getAuth(). Updated architecture, ADR 0011, and parity evidence. `bun run check` passes with 53 coding-agent and 79 TUI tests.
