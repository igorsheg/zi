import { expect, test } from "bun:test"

import { extensionWorkerArgument } from "@with-zi/coding-agent/internal/extension-worker-mode"

import { standaloneRoute } from "../src/bootstrap.js"

test("standalone bootstrap keeps exact metadata and worker invocations on their narrow routes", () => {
  expect(standaloneRoute(["-V"])).toBe("version")
  expect(standaloneRoute(["--version"])).toBe("version")
  expect(standaloneRoute(["-h"])).toBe("help")
  expect(standaloneRoute(["--help"])).toBe("help")
  expect(standaloneRoute([extensionWorkerArgument])).toBe("extension_worker")
})

test("standalone bootstrap leaves mixed and ordinary invocations to full CLI parsing", () => {
  expect(standaloneRoute([])).toBe("main")
  expect(standaloneRoute(["--version", "--unknown"])).toBe("main")
  expect(standaloneRoute(["prompt", "--help"])).toBe("main")
  expect(standaloneRoute([extensionWorkerArgument, "extra"])).toBe("main")
})
