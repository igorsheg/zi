import { homedir } from "node:os"
import { join, resolve } from "node:path"

export function getAgentDir(): string {
  return resolve(process.env.OPENZI_AGENT_DIR ?? join(homedir(), ".openzi", "agent"))
}

export function getSessionDir(cwd: string, agentDir = getAgentDir()): string {
  const safe = `--${resolve(cwd)
    .replace(/^[/\\]/, "")
    .replace(/[/\\:]/g, "-")}--`
  return join(agentDir, "sessions", safe)
}
