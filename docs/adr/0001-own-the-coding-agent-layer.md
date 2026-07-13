# Own the coding-agent layer

OpenZi depends on `@earendil-works/pi-ai` and `@earendil-works/pi-agent-core`, while treating `pi-coding-agent` as both the behavioral and coding-agent architecture reference rather than a runtime dependency. We recreate its session, services, managers, resources, tools, extension, and mode boundaries so parity remains traceable while those layers stay ours to extend.
