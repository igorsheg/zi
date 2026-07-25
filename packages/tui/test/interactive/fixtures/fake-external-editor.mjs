import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

const args = process.argv.slice(2)
const file = args.at(-1)
const capturePath = args[0]
const mode = args[1]
if (!file || !capturePath) process.exit(2)

writeFileSync(
  capturePath,
  JSON.stringify({
    file,
    content: readFileSync(file, "utf8"),
    entries: readdirSync(dirname(file)),
    directoryMode: statSync(dirname(file)).mode
  })
)

if (mode === "fail") process.exit(7)
if (mode === "wait") setInterval(() => {}, 1_000)
else writeFileSync(file, mode === "oversized" ? "x".repeat(1024 * 1024 + 1) : mode === "empty" ? "" : "edited\n")
