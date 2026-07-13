# Use owner-based Bun workspaces

OpenZi starts with three workspaces: `coding-agent` owns Pi parity and product policy, `tui` owns the OpenTUI React frontend, and `cli` owns process composition and modes. This prevents frontend dependencies from leaking into the agent and avoids vague `shared`, `common`, or `core` packages; a new package requires a new independently meaningful owner, not merely reusable code.
