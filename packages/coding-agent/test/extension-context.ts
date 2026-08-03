import { resolve } from "node:path"

import type { ExtensionContext } from "@with-zi/extension-api"

export const testExtensionContext: ExtensionContext = Object.freeze({
  mode: "embedded",
  cwd: resolve("extension-test"),
  session: Object.freeze({ type: "memory", id: "extension-test" })
})
