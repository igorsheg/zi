# OpenTUI React owns the terminal

OpenZi uses `@opentui/react` over `@opentui/core` for composition, while OpenTUI owns terminal lifecycle, input, focus, layout, width handling, and rendering. Zi remains a visual and interaction reference only: its Zig/Vaxis frame architecture and internal region vocabulary will not be ported. React route providers may own frontend-wide state, and deep components such as the prompt may own cohesive local interaction state; coding-agent policy remains behind `AgentSession`.
