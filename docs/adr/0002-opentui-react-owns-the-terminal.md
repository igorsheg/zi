# OpenTUI React owns the terminal

OpenZi uses `@opentui/react` over `@opentui/core` for composition, while OpenTUI owns terminal lifecycle, input, focus, layout, width handling, and rendering. The interactive mode inside `pi-coding-agent` defines observable behavior; its TUI implementation does not define OpenZi's screen architecture. Zi supplies visual styling only. Scoped React providers may own frontend state with a real cross-component lifetime, and deep components such as the prompt may own cohesive local interaction state; coding-agent policy remains behind `AgentSession`.
