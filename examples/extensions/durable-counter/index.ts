import { Schema, type ExtensionAPI } from "@with-zi/extension-api"

export default function durableCounter(zi: ExtensionAPI): void {
  let count = 0

  zi.on("session_start", async () => {
    const entries = await zi.getSessionEntries("example.counter")
    const latest = entries.at(-1)?.data
    if (typeof latest === "object" && latest !== null && !Array.isArray(latest) && typeof latest.count === "number") {
      count = latest.count
    }
  })

  zi.registerCommand({
    name: "counter",
    description: "Show, increment, or reset the durable session counter",
    argumentHint: "[show|increment|reset]",
    async execute(arguments_) {
      const action = arguments_.trim() || "show"
      if (action === "show") return `Counter: ${count}`
      if (action === "increment") {
        count++
        await zi.appendEntry("example.counter", { count })
        return `Counter: ${count}`
      }
      if (action === "reset") {
        count = 0
        await zi.appendEntry("example.counter", { count })
        return "Counter: 0"
      }
      throw new Error("Usage: /counter [show|increment|reset]")
    }
  })

  zi.registerTool({
    name: "increment_counter",
    description: "Increment a counter persisted in the current Zi session",
    parameters: Schema.object({}),
    async execute() {
      count++
      await zi.appendEntry("example.counter", { count })
      await zi.sendMessage({ customType: "example.counter", content: `Counter: ${count}`, display: true }, "follow_up")
      return String(count)
    }
  })
}
