import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { developmentVersion, workingTreeVersion } from "./build-local.js"

test("local builds identify their source revision and dirty state", () => {
  expect(developmentVersion("abc123", false)).toBe("0.0.0-dev.abc123")
  expect(developmentVersion("abc123", true)).toBe("0.0.0-dev.abc123.dirty")
  expect(developmentVersion(undefined, false)).toBe("0.0.0-dev")
})

test("untracked source marks a local build dirty", async () => {
  const directory = await mkdtemp(join(tmpdir(), "zi-build-version-"))
  try {
    await git(directory, ["init", "--quiet"])
    await Bun.write(join(directory, "tracked.ts"), "export {}\n")
    await git(directory, ["add", "tracked.ts"])
    await git(directory, [
      "-c",
      "user.name=Zi",
      "-c",
      "user.email=zi@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "base"
    ])

    const clean = await workingTreeVersion(directory)
    await Bun.write(join(directory, "untracked.ts"), "export {}\n")

    expect(clean).toMatch(/^0\.0\.0-dev\.[0-9a-f]{12}$/)
    expect(await workingTreeVersion(directory)).toBe(`${clean}.dirty`)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

async function git(cwd: string, args: readonly string[]): Promise<void> {
  const child = Bun.spawn(["git", ...args], { cwd, stdin: "ignore", stdout: "ignore", stderr: "pipe" })
  const [exitCode, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()])
  if (exitCode !== 0) throw new Error(stderr)
}
