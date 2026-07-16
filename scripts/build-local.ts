#!/usr/bin/env bun

import { chmod, rename, rm } from "node:fs/promises"
import { join, relative, resolve } from "node:path"

import { compileOpenZi } from "./compile-openzi.js"

export function developmentVersion(commit: string | undefined, dirty: boolean): string {
  return ["0.0.0-dev", commit, dirty ? "dirty" : undefined].filter(part => part !== undefined).join(".")
}

async function buildLocal(): Promise<void> {
  const root = resolve(import.meta.dirname, "..")
  const outputDirectory = join(root, "dist")
  const extension = process.platform === "win32" ? ".exe" : ""
  const executable = join(outputDirectory, `openzi${extension}`)
  const pending = join(outputDirectory, `.openzi-${process.pid}${extension}`)
  const version = process.env.OPENZI_BUILD_VERSION ?? (await workingTreeVersion(root))

  await rm(pending, { force: true })
  try {
    await compileOpenZi({ outfile: pending, version })
    if (process.platform !== "win32") await chmod(pending, 0o755)
    await rm(executable, { force: true })
    await rename(pending, executable)
  } finally {
    await rm(pending, { force: true })
  }

  console.log(`Built ${relative(root, executable)} (${version})`)
}

export async function workingTreeVersion(root: string): Promise<string> {
  const commit = await git(root, ["rev-parse", "--short=12", "HEAD"])
  const status = await git(root, ["status", "--porcelain"])
  return developmentVersion(commit || undefined, status.length > 0)
}

async function git(root: string, args: readonly string[]): Promise<string> {
  const child = Bun.spawn(["git", ...args], { cwd: root, stdin: "ignore", stdout: "pipe", stderr: "ignore" })
  const [exitCode, stdout] = await Promise.all([child.exited, new Response(child.stdout).text()])
  return exitCode === 0 ? stdout.trim() : ""
}

if (import.meta.main) {
  try {
    await buildLocal()
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    console.error(message)
    process.exitCode = 1
  }
}
